# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs the EUnit cases of the system console's login (test/erlang/erx_console_login_tests.erl):
# a login session that timed out starts again within a start row's default restart intensity,
# compiled from source with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies).
class ErxConsoleLoginTest < Minitest::Test
  APPLICATIONS = %w[erx erx_files erx_domain erx_session].freeze
  TESTS = %w[test/erlang/erx_console_login_tests.erl].freeze

  def test_login_cases_pass_under_eunit
    Dir.mktmpdir('erx-console-login-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      eval = 'halt(case eunit:test([erx_console_login_tests], [verbose]) of ok -> 0; _ -> 1 end).'
      output, status = Open3.capture2e('gtimeout', '-k', '10', '180', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', eval, chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/passed/, output)
    end
  end
end
