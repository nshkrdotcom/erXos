# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'error'
require_relative 'bounded_file'
require_relative 'json_input'
require_relative 'dependencies'
require_relative 'file_lock'
require_relative 'output_directory'
require_relative 'runner'

module Erx
  # The Bluetooth test peer: Google's Bumble 0.0.237 (deps.lock, id `bumble`),
  # unmodified, in a Python virtual environment at build/bumble
  # (docs/design-bluetooth.md, "Verification"). Python runs only on the
  # development host, only Bumble and erXos's scripts under test/bt/, and always
  # isolated (-I), so neither the script's directory, the current directory,
  # PYTHON* variables nor user site-packages reach its module path, and with its
  # byte-code cache under build/bumble, so nothing is written into the fetched
  # tree.
  #
  # The packages Bumble's modules import are installed by pip from the fetched
  # wheels alone: --no-index, --require-hashes against deps.lock's SHA-256.
  # The environment is made with a cleared environment whose HOME is
  # build/bumble and whose PIP_CONFIG_FILE is the null device, so no pip
  # configuration file or PIP_* variable reaches pip or the ensurepip step that
  # installs pip into the environment from the interpreter's own copy.
  # Bumble itself is not built: a .pth file puts its fetched tree on the
  # environment's module path, so no build backend runs and none is pinned.
  #
  # Of Bumble's declared dependencies only those its codecs, controller, local
  # link and TCP transports import are pinned: pyee and typing_extensions, which
  # Bumble and pyee import. That serves the decoder comparison and the stage 1
  # peer of the design's hosted suite; apps/pair.py, apps/gatt_dump.py and
  # apps/scan.py import click as well, which the stage that runs them pins here.
  # The USB, serial and WebSocket dependencies are imported only by transports
  # the harness never opens; cryptography is optional to Bumble (bumble/crypto
  # falls back to its built-in primitives).
  module Bumble
    SOURCE_ID = 'bumble'
    WHEEL_IDS = %w[bumble-pyee bumble-typing-extensions].freeze
    OUTPUT = 'build/bumble'
    STAMP = 'build.json'
    PTH = 'erx-bumble.pth'
    # pyee 16 needs Python 3.12; Bumble 0.0.237 needs 3.11.
    MINIMUM_PYTHON = [3, 12].freeze
    PYTHON_VARIABLE = 'ERX_PYTHON'
    DEADLINE = 300

    # The interpreter of the environment, the tree of Bumble's sources, whose
    # apps/ and examples/ scripts a caller runs by path, and the byte-code cache.
    Environment = Data.define(:python, :tree, :pycache) do
      # The argument vector that runs script, a path, with arguments, isolated.
      def argv(script, *arguments) = [python, '-I', '-X', "pycache_prefix=#{pycache}", script, *arguments]
    end

    module_function

    # Runs the block with the environment, made first when locate refuses what
    # is there. The environment is made under an exclusive hold of its lock and
    # used under a shared one, so no other process remakes it while the block
    # runs, and two never make it at once.
    def use(root:, runner:, python: host_python)
      lock = File.join(root, "#{OUTPUT}.lock")
      what = "the Bumble environment #{File.join(root, OUTPUT)}"
      OutputDirectory.prepare(root: root, path: File.join(root, 'build'))
      FileLock.hold(lock, what: what, busy: :wait) do
        locate(root: root, python: python) || build(root: root, runner: runner, python: python)
      end
      FileLock.hold(lock, what: what, busy: :wait, mode: :shared) do
        yield locate(root: root, python: python) || raise(Error, "#{what} was remade from other pins while waiting")
      end
    end

    # The environment, or nil when it is missing or was made from another pin,
    # recipe, interpreter or tree, so a caller remakes it.
    def locate(root:, python: host_python)
      stamp = File.join(root, OUTPUT, STAMP)
      return nil unless File.file?(stamp) && File.executable?(interpreter(root))

      recorded = begin
        JsonInput.parse(BoundedFile.read(stamp, maximum: 65_536), max_bytes: 65_536, label: 'Bumble environment record')
      rescue JsonInput::Unsupported
        raise
      rescue Error
        nil
      end
      dependencies = Dependencies.new(root: root, runner: nil)
      recorded == record(dependencies, python: python) ? environment(root: root, dependencies: dependencies) : nil
    end

    # ERX_PYTHON, or the first python3 on PATH, by its real path: the record
    # names the installed interpreter, so upgrading it remakes the environment.
    def host_python
      program = ENV.fetch(PYTHON_VARIABLE, 'python3')
      candidates = if program.include?('/')
                     [File.expand_path(program)]
                   else
                     ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |directory| File.join(directory, program) }
                   end
      found = candidates.find { |candidate| File.file?(candidate) && File.executable?(candidate) }
      unless found
        raise Error, "no Python interpreter for the Bluetooth test peer; install Python " \
                     "#{MINIMUM_PYTHON.join('.')} or later (Homebrew's python3) or set #{PYTHON_VARIABLE}"
      end

      File.realpath(found)
    end

    def record(dependencies, python:)
      { 'sources' => [SOURCE_ID, *WHEEL_IDS].map { |id| dependencies.pinned(id) },
        'tree' => dependencies.fetched_tree(SOURCE_ID),
        'recipe' => Digest::SHA256.file(__FILE__).hexdigest,
        'python' => python }
    end

    def interpreter(root) = File.join(root, OUTPUT, 'venv', 'bin', 'python')
    private_class_method :interpreter

    def environment(root:, dependencies:)
      Environment.new(python: interpreter(root), pycache: File.join(root, OUTPUT, 'pycache'),
                      tree: dependencies.fetched_tree(SOURCE_ID))
    end
    private_class_method :environment

    # Makes the environment in place, under use's exclusive hold: a virtual
    # environment's paths are its own, so it is not built elsewhere and moved.
    # Everything that can refuse runs before the old environment is removed, and
    # the record is written last, so an interrupted build is never located.
    def build(root:, runner:, python:)
      dependencies = Dependencies.new(root: root, runner: runner)
      tree = dependencies.fetched_tree(SOURCE_ID)
      requirements_text = WHEEL_IDS.map do |id|
        "#{dependencies.fetched_file(id)} --hash=sha256:#{dependencies.pinned(id).fetch('sha256')}\n"
      end.join
      # check refuses a path any of whose components is not a directory, a symbolic link included.
      output = OutputDirectory.check(root: root, path: File.join(root, OUTPUT))
      check_version(python, root: root, runner: runner)
      FileUtils.rm_rf(output)
      OutputDirectory.prepare(root: root, path: output)
      quiet = { 'PATH' => ENV.fetch('PATH', ''), 'HOME' => output, 'PIP_CONFIG_FILE' => File::NULL }
      runner.run([python, '-I', '-m', 'venv', File.join(output, 'venv')], name: 'bumble-venv', deadline: DEADLINE,
                                                                            env: quiet, clear_env: true)
      requirements = File.join(output, 'requirements.txt')
      File.write(requirements, requirements_text)
      runner.run([interpreter(root), '-I', '-m', 'pip', 'install', '--isolated', '--no-index', '--require-hashes',
                  '--only-binary', ':all:', '--no-cache-dir', '--disable-pip-version-check', '-r', requirements],
                 name: 'bumble-pip', deadline: DEADLINE, env: quiet, clear_env: true)
      File.write(File.join(query(interpreter(root), 'import sysconfig; print(sysconfig.get_path("purelib"))',
                                 root: root, runner: runner), PTH), "#{tree}\n")
      File.write(File.join(output, STAMP), JSON.pretty_generate(record(dependencies, python: python)) + "\n")
      locate(root: root, python: python) || raise(Error, "Bumble environment build left no record in #{OUTPUT}")
    end

    def check_version(python, root:, runner:)
      reported = query(python, 'import sys; print("%d.%d" % sys.version_info[:2])', root: root, runner: runner)
      version = reported.match(/\A(\d+)\.(\d+)\z/)&.captures&.map(&:to_i)
      return if version && (version <=> MINIMUM_PYTHON) >= 0

      raise Error, "#{python} is Python #{reported.inspect}; the Bluetooth test peer needs " \
                   "#{MINIMUM_PYTHON.join('.')} or later (set #{PYTHON_VARIABLE})"
    end
    private_class_method :check_version

    # The one line python prints for code, isolated.
    def query(python, code, root:, runner:)
      Dir.mktmpdir('.bumble-query-', OutputDirectory.prepare(root: root, path: File.join(root, 'build'))) do |work|
        answer = File.join(work, 'answer')
        runner.run([python, '-I', '-c', code], name: 'bumble-query', deadline: 60, stdout: answer)
        BoundedFile.read(answer, maximum: 4096).strip
      end
    end
    private_class_method :query
  end
end
