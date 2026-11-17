# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_ntp_tests.erl and test/erlang/erx_cmd_ntpdate_tests.erl, the
# EUnit cases of the NTP codec, the checks of one reply and the command shell's
# `ntpdate` (docs/design-time.md, "Setting the clock from a server once"), against
# the erx and erx_shell applications compiled from source with warnings as errors on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxNtpdateTest < Minitest::Test
  APPLICATIONS = %w[erx erx_shell].freeze
  TESTS = %w[test/erlang/erx_ntp_tests.erl test/erlang/erx_cmd_ntpdate_tests.erl].freeze

  def test_ntp_and_ntpdate_cases_pass_under_eunit
    Dir.mktmpdir('erx-ntpdate-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test([erx_ntp_tests, erx_cmd_ntpdate_tests]) of ' \
                                                'ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
