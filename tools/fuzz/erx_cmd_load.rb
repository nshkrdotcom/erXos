# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of the session load's reader of its arguments and standard input,
# erx_cmd_load:parse/1 and split/2 (test/erlang/erx_cmd_load_fuzz.erl), compiled from source
# with the generated ABI header and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the
# oracle's). It runs the module as it is, then a copy that drops the load bound on the sizes
# in all, which must fail: that shows the reference holds a load to code_load_bytes_max.
module ErxCmdLoadFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated header named here is in build/gen.
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_shell/src/erx_cmd_load.erl')
  SOURCES = [File.join(ROOT, 'erlang/apps/erx_shell/src/erx_cmd.erl'),
             File.join(ROOT, 'test/erlang/erx_cmd_load_fuzz.erl')].freeze
  BOUND = 'lists:sum([Size || {_, Size} <- All, is_integer(Size)]) =< ?ERX_CODE_LOAD_BYTES_MAX'
  UNBOUNDED = 'true'
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no load bound in #{MODULE_SOURCE}" unless source.scan(BOUND).size == 1

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(source.sub(BOUND, UNBOUNDED), seed: seed)
    abort("reading sizes past the load bound passed:\n#{output}") if status.success? ||
                                                                 !output.include?('disagrees_with_reference')
    puts 'erx_cmd_load:parse/1 and split/2 agree with their reference, and dropping the load bound does not'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-cmd-load-fuzz') do |work|
      module_path = File.join(work, 'erx_cmd_load.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, SOURCES.first, module_path,
                                       *SOURCES.drop(1), stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_cmd_load_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| options[:seed] = value } }.parse!
  ErxCmdLoadFuzz.run(seed: options.fetch(:seed))
end
