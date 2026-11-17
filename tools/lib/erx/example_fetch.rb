# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'dependencies'
require_relative 'output_directory'
require_relative 'submodule'
require_relative 'submodules'

module Erx
  # `tools/erx fetch --example NAME` (docs/design-packaging.md, "Examples"): an example
  # whose license keeps it out of erXos's tree is a git submodule pinned by its
  # gitlink, and the downloads it needs (Freedoom's WAD for Doom) are pinned in a
  # deps.lock in the submodule's own repository, in the form of erXos's deps.lock.
  # Only this step obtains either; no gate or build step names an example (ExampleLists),
  # and the submodule's `update = none` keeps a recursive clone from obtaining it.
  #
  # The submodule is untrusted data: nothing of it runs. Its deps.lock is parsed by
  # DependencySchema, admits only downloads of a pinned archive or file, verified against
  # their SHA-256 before anything is published, and publishes them under
  # build/examples/NAME, a root of its own, so no id it names can replace a source of
  # erXos's deps.lock.
  module ExampleFetch
    # The examples: the submodules whose .gitmodules entry says `update = none`.
    EXAMPLES = Submodules::TREE.examples
    LOCK = 'deps.lock'
    # An example's lock may pin an archive or a file; a git or image source would run
    # git or Docker on what the lock names.
    KINDS = %w[file tar zip].freeze
    WORKSPACE = 'build/examples'

    module_function

    # Clones the example if it is not checked out, then fetches its downloads. cache is
    # another checkout's build/downloads, from which the downloads come with no network.
    # Returns the lines that say what was done.
    def fetch(name:, root:, runner:, cache: nil)
      path = EXAMPLES.find(name)&.path ||
             raise(Error, "unknown example #{name}; the examples are #{EXAMPLES.names.join(', ')}")
      cloned = checkout(name: name, root: root, runner: runner, path: path)
      workspace = File.join(WORKSPACE, name)
      dependencies = Dependencies.new(root: OutputDirectory.prepare(root: root, path: File.join(root, workspace)),
                                      runner: runner, lock_path: lock_path(root: root, path: path))
      dependencies.sources.each do |source|
        next if KINDS.include?(source.fetch('kind'))

        raise Error, "#{path}/#{LOCK} pins #{source.fetch('id')}, a #{source.fetch('kind')} source; " \
                     "an example's lock pins only #{KINDS.join(', ')} downloads"
      end
      dependencies.fetch(cache: cache)
      [cloned, *dependencies.sources.map do |source|
        "#{name}: #{source.fetch('id')} #{source.fetch('version')} fetched to " \
          "#{File.join(workspace, 'build/third_party', source.fetch('id'))}"
      end]
    end

    # A checkout that is there is left as it is, so work in progress is never moved.
    def checkout(name:, root:, runner:, path:)
      return "#{name}: #{path} is already checked out; left as it is" if File.exist?(File.join(root, path, '.git'))

      Submodule.checkout(root: root, runner: runner, path: path, name: "#{name}-submodule-init", update: 'checkout')
      "#{name}: cloned #{path} at the commit its gitlink records"
    end
    private_class_method :checkout

    # The lock the checkout holds, which must be a regular file of the checkout.
    def lock_path(root:, path:)
      lock = File.join(root, path, LOCK)
      unless File.file?(lock) && !File.symlink?(lock) && !File.symlink?(File.join(root, path))
        raise Error, "#{path} holds no #{LOCK} of its own (a regular file)"
      end
      lock
    end
    private_class_method :lock_path
  end
end
