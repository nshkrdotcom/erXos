# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_console_reads_tests.erl, the console of a session domain's line
# reading its terminal relay on demand (docs/design-shell.md, "The console reads on
# demand"), on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies) with
# the tree's group.erl loaded in place of stock's. `user` is erx_test_user, so no group
# runs stock's code when the tree's is loaded. The seeded fault is stock's group, which
# never asks its driver for input in a shell's group (edit 72 of design-runtime.md).
class ErxConsoleReadsTest < Minitest::Test
  CASES = %w[test/erlang/erx_test_user.erl test/erlang/erx_console_reads_tests.erl].freeze
  GROUP = 'otp/lib/kernel/src/group.erl'
  DEADLINE = '120'
  LOAD_GROUP = 'code:unstick_mod(group), {module, group} = code:load_abs("group"), '

  def test_the_cases_pass
    output, status = eunit(LOAD_GROUP)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_a_group_without_edit_72_fails
    output, status = eunit('')
    refute status.success?, output
    assert_match(/a_typed_line_reaches_the_shell_test\S*\.\.\.\*failed\*/, output)
  end

  private

  def eunit(load)
    Dir.mktmpdir('erx-console-reads-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_session], tests: CASES + [GROUP])
      # Stock group, in the seeded run, wherever it would load from.
      File.delete(File.join(work, 'group.beam')) if load.empty?
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-user', 'erx_test_user',
                      '-pa', work, '-eval',
                      "logger:set_primary_config(level, none), #{load}" \
                      'halt(case eunit:test(erx_console_reads_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                      chdir: work, stdin_data: '')
    end
  end
end
