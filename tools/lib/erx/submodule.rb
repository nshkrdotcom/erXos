# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'runner'

module Erx
  # The one place erXos runs git on a git submodule of its tree (Origin::SUBMODULES):
  # LVGL's, which the build compiles from (Lvgl), and an example's, which only
  # `tools/erx fetch --example` obtains (ExampleFetch). A submodule's checkout is
  # untrusted data: git runs with the fsmonitor off, so no program the checkout's
  # configuration names starts, and with the caller's GIT_* variables unset.
  module Submodule
    DEADLINE = 900
    # git refuses a clone from a local path (a worktree whose shared configuration
    # points the submodule at the main checkout's clone) unless the file transport is
    # allowed; the clone allows it for its one command, never in git's configuration.
    FILE_TRANSPORT = 'protocol.file.allow=always'

    module_function

    # Clones the submodule at path at the commit the superproject records, with no
    # history when its URL is remote (git ignores --depth for a local path). update
    # names the update mode to force ('checkout'), for a submodule whose .gitmodules
    # entry says `update = none` so that no recursive clone obtains it.
    def checkout(root:, runner:, path:, name:, update: nil)
      git(root: root, runner: runner, path: path, name: name, config: [FILE_TRANSPORT],
          arguments: ['submodule', 'update', '--init', '--depth', '1', *("--#{update}" if update), '--', path])
    end

    # Runs git on the checkout at root alone and starts no program its configuration
    # names. config adds `-c` settings for this one command.
    def git(root:, runner:, path:, name:, arguments:, config: [], output_limit: nil)
      unless File.exist?(File.join(root, '.git'))
        raise Error, "#{root} is not a git checkout, so git cannot fetch or check #{path}"
      end
      settings = ['core.fsmonitor=false', *config].flat_map { |setting| ['-c', setting] }
      runner.run(['git', *settings, '-C', root, *arguments], name: name,
                 deadline: DEADLINE, chdir: root, output_limit: output_limit,
                 env: ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] })
    rescue CommandError => error
      raise Error, "git #{arguments.grep_v(/\A-/).first} of #{path} failed; log: #{error.result.fetch('log')}"
    end
  end
end
