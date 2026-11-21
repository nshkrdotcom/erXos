# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The `user` of a session with no terminal on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies): test/erlang/erx_log_user_tests.erl, the EUnit cases of
# erx_log_user's lines and of the session supervisor's choice of it, compiled with the
# applications they exercise.
class ErxLogUserTest < Minitest::Test
  APPLICATIONS = %w[erx erx_session].freeze
  TESTS = %w[test/erlang/erx_log_user_tests.erl].freeze

  def test_user_cases_pass_under_eunit
    Dir.mktmpdir('erx-log-user-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_log_user_tests, [verbose]) of ' \
                                                'ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
