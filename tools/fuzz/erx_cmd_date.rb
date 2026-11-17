# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The fuzz target of the command shell's `date` argument parser,
# erx_cmd_date:parse/1 (test/erlang/erx_cmd_date_fuzz.erl), compiled from
# source with erx_cmd on stock's emulator (ERX_ERL and ERX_ERLC). It runs
# the target, then a copy of erx_cmd_date whose month bound is 13, which the
# target must catch as an accepted operand out of FreeBSD's bounds
# (docs/design-time.md, "Verification and testing").

require 'open3'
require 'optparse'
require 'tmpdir'

module ErxCmdDateFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_shell/src/erx_cmd_date.erl'
  CMD = 'erlang/apps/erx_shell/src/erx_cmd.erl'
  FUZZ = 'test/erlang/erx_cmd_date_fuzz.erl'
  BOUND = 'month => 12'
  NO_BOUND = 'month => 13'
  DEADLINE_SECONDS = '120'
  VERDICT = 'out_of_bounds'

  module_function

  def run(seed:)
    core = File.binread(File.join(ROOT, CORE))
    raise "no month bound in #{CORE}" unless core.scan(BOUND).length == 1

    output, status = fuzz(core, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(core.sub(BOUND, NO_BOUND), seed: seed)
    abort("a month of 13 passed:\n#{output}") if status.success? || !output.include?(VERDICT)
    puts 'erx_cmd_date parses FreeBSD date operands within their bounds, and a month of 13 does not pass'
  end

  def fuzz(core_text, seed:)
    Dir.mktmpdir('erx-cmd-date-fuzz') do |work|
      core_path = File.join(work, File.basename(CORE))
      File.binwrite(core_path, core_text)
      sources = [File.join(ROOT, CMD), core_path, File.join(ROOT, FUZZ)]
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, *sources, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_cmd_date_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxCmdDateFuzz.run(seed: seed)
end
