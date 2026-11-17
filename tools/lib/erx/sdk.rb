# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'app_package'
require_relative 'bounded_file'
require_relative 'erlang_apps'
require_relative 'error'
require_relative 'oracle'
require_relative 'sdk_sysroot'
require_relative 'source_revision'

module Erx
  # `tools/erx sdk export DIR` (docs/design-packaging.md, "The SDK"): the SDK a third party
  # builds and tests an app with, written from the tree. DIR/SDK.txt names what the SDK was
  # made from; DIR/erlang/lib/APP/{ebin,include} holds each public Erlang application, an
  # application holding a module sdk/public.txt names, and every erXos application it
  # depends on, compiled by Erx::ErlangApps with the build's own flags and compiler, so its
  # beams are the image's; DIR/erlang/public.txt lists the public functions one
  # MODULE:FUNCTION/ARITY a line, a module line of sdk/public.txt expanded to the module's
  # exports. DIR/host/erlang/ebin holds what the packer's file check calls outside the SDK's
  # applications: erx_bytes for stock OTP (test/erlang/host_bytes) and the preloaded
  # erx_verity_tree, the hash tree's layout. No private key enters an SDK: its packer makes
  # its own development key on the host that uses it (Erx::PackageKey). DIR/sysroot and
  # DIR/share/erxos/sdk.mk are the native half a C program builds with (Erx::SdkSysroot).
  class Sdk
    PUBLIC = 'sdk/public.txt'
    HOST_MODULES = %w[test/erlang/host_bytes/erx_bytes.erl otp/erts/preloaded/src/erx_verity_tree.erl].freeze
    # Where erx_verity_tree's generated ABI header lies.
    HOST_INCLUDE = 'build/gen/erlang/apps/erx/include'
    DEADLINE = 300
    IDENTIFIER = /\A[a-z][a-z0-9_]*\z/

    # A line of sdk/public.txt: one function, or every function a module exports.
    Function = Data.define(:module_name, :function, :arity) do
      def to_s = "#{module_name}:#{function}/#{arity}"
    end
    WholeModule = Data.define(:module_name) do
      def to_s = module_name
    end

    # sdk/public.txt's entries: comments and blank lines aside, each line is
    # MODULE:FUNCTION/ARITY or MODULE, in sorted order and each once.
    def self.entries(text)
      lines = text.lines.map(&:chomp).each_with_index.reject { |line, _| line.empty? || line.start_with?('#') }
      entries = lines.map { |line, index| entry(line, number: index + 1) }
      keys = entries.map(&:to_s)
      raise Error, "#{PUBLIC}: entries must be sorted and listed once" unless keys == keys.uniq.sort

      entries
    end

    def self.entry(line, number:)
      case line.split(%r{[:/]}, -1)
      in [module_name] if IDENTIFIER.match?(module_name)
        WholeModule.new(module_name: module_name)
      in [module_name, function, arity] if [module_name, function].all? { IDENTIFIER.match?(it) } && /\A(0|[1-9]\d*)\z/.match?(arity)
        Function.new(module_name: module_name, function: function, arity: Integer(arity))
      else
        raise Error, "#{PUBLIC}:#{number}: not MODULE:FUNCTION/ARITY or MODULE"
      end
    end
    private_class_method :entry

    # The public functions as public.txt's sorted lines, each whole module's from exports, a
    # map from module name to its exported [function, arity] pairs.
    def self.expand(entries, exports:)
      entries.flat_map do |entry|
        case entry
        in Function(module_name:, function:, arity:)
          raise Error, "#{PUBLIC}: #{entry} is not exported" unless exports.fetch(module_name).include?([function, arity])

          [entry.to_s]
        in WholeModule(module_name:)
          exports.fetch(module_name).reject { |function, _| function == 'module_info' }
                 .map { |function, arity| Function.new(module_name: module_name, function: function, arity: arity).to_s }
        end
      end.uniq.sort
    end

    # The erXos applications the SDK carries: each holding a public module, and each erXos
    # application those depend on, in ErlangApps::APPLICATIONS' order. owners maps a module
    # to its application, depends an application to the applications its resource file names.
    # A resource file's runtime_dependencies are not followed: they are needs on the target
    # (erx's console runs erx_shell:console/0) that the SDK's use on the host never meets,
    # and stock OTP's application loading ignores them.
    def self.applications(entries, owners:, depends:)
      roots = entries.map(&:module_name).uniq.map do |module_name|
        owners.fetch(module_name) { raise Error, "#{PUBLIC}: #{module_name} is in no erXos application" }
      end
      closure = roots.each_with_object(Set.new) { |application, seen| reach(application, depends, seen) }
      ErlangApps::APPLICATIONS.select { |application| closure.include?(application) }
    end

    def self.reach(application, depends, seen)
      return unless ErlangApps.own?(application) && seen.add?(application)

      depends.fetch(application).each { |other| reach(other, depends, seen) }
    end
    private_class_method :reach

    # compiler and linker are the LLVM clang and ld.lld the native half builds with (Erx::SdkSysroot).
    def initialize(root:, runner:, erlc:, compiler:, linker:)
      @root = root
      @runner = runner
      @erlc = erlc
      @sysroot = SdkSysroot.new(root: root, runner: runner, compiler: compiler, linker: linker)
    end

    # Writes the SDK into directory, which must not exist yet; returns directory.
    def export(directory)
      raise Error, "#{directory} exists; the SDK is written into a new directory" if File.exist?(directory)

      entries = self.class.entries(File.read(File.join(@root, PUBLIC)))
      applications = self.class.applications(entries, owners: owners, depends: depends)
      work = Dir.mktmpdir('.erx-sdk-', File.dirname(File.expand_path(directory)))
      begin
        write(work, entries: entries, applications: applications)
        File.rename(work, directory)
      ensure
        FileUtils.rm_rf(work)
      end
      directory
    end

    private

    def write(work, entries:, applications:)
      lib = File.join(work, 'erlang', 'lib')
      ErlangApps.new(root: @root, runner: @runner, erlc: @erlc).build_applications(applications, otp: File.join(work, 'erlang'))
      applications.each { |application| copy_includes(application, File.join(lib, application, 'include')) }
      File.write(File.join(work, 'erlang', 'public.txt'),
                 self.class.expand(entries, exports: exports(entries, lib: lib)).map { "#{it}\n" }.join)
      File.write(File.join(work, 'SDK.txt'), description)
      @sysroot.write(work)
      host = File.join(work, 'host', 'erlang', 'ebin')
      FileUtils.mkdir_p(host)
      @runner.run([@erlc, '+deterministic', '-I', File.join(@root, HOST_INCLUDE), '-o', host,
                   *HOST_MODULES.map { File.join(@root, it) }],
                  name: 'sdk-host-bytes', deadline: DEADLINE, env: Oracle::CLEAN_ERLANG_ENV)
    end

    def owners
      ErlangApps::APPLICATIONS.each_with_object({}) do |application, owners|
        ErlangApps.modules(root: @root, application: application)
                  .each { |path| owners[File.basename(path, '.erl')] = application }
      end
    end

    # Each application's dependencies, as its resource file's applications list names them.
    def depends
      ErlangApps::APPLICATIONS.to_h do |application|
        resource = ErlangApps.read_sources(root: @root, application: application).resource
        listed = resource[/\{applications,\s*\[([^\]]*)\]\}/, 1] or raise Error, "#{application}.app.src names no applications"
        [application, listed.split(',').map(&:strip)]
      end
    end

    # An application's headers, from its include/ in the tree and in the generated tree.
    def copy_includes(application, target)
      [ErlangApps.source(application), ErlangApps.generated(application)].each do |directory|
        source = File.join(@root, directory, 'include')
        next unless File.directory?(source)

        FileUtils.mkdir_p(target)
        Dir.children(source).sort.each { |name| FileUtils.cp_r(File.join(source, name), target) }
      end
    end

    # The exports of each module entries name, read from its beam's export chunk.
    def exports(entries, lib:)
      names = entries.map(&:module_name).uniq
      beams = names.map { |name| Dir.glob(File.join(lib, '*', 'ebin', "#{name}.beam")).fetch(0) }
      expression = "[begin {ok, {M, [{exports, E}]}} = beam_lib:chunks(B, [exports]), " \
                   "[io:format(\"~s ~s ~b~n\", [M, F, A]) || {F, A} <- E] end || B <- [#{beams.map(&:inspect).join(', ')}]], halt()."
      capture([erl, '-noshell', '-noinput', '-boot', 'no_dot_erlang', '-eval', expression], name: 'sdk-exports')
        .lines.map(&:split).group_by(&:first)
        .transform_values { |rows| rows.map { |_, function, arity| [function, Integer(arity)] } }
    end

    # A command's standard output, run under the runner's deadline.
    def capture(argv, name:)
      Dir.mktmpdir('erx-sdk-') do |directory|
        output = File.join(directory, 'stdout')
        @runner.run(argv, name: name, deadline: DEADLINE, env: Oracle::CLEAN_ERLANG_ENV, stdout: output)
        BoundedFile.read(output, maximum: 1 << 20)
      end
    end

    def erl = File.join(File.dirname(@erlc), 'erl')

    # SDK.txt: what the SDK was made from, one KEY VALUE a line.
    def description
      otp = File.read(Dir.glob(File.join(File.dirname(@erlc), '..', 'lib', 'erlang', 'releases', '*', 'OTP_VERSION')).fetch(0)).strip
      commit = SourceRevision.read(root: @root, runner: @runner)&.then { [it.commit, ('dirty' if it.dirty)].compact.join('-') } || 'unknown'
      { 'commit' => commit, 'abi_version' => AppPackage.codec.abi_version, 'arch' => AppPackage.architecture, 'otp' => otp }
        .map { |key, value| "#{key} #{value}\n" }.join
    end
  end
end
