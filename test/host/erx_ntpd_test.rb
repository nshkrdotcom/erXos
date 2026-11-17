# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_ntp_core_tests.erl, the EUnit cases of ntpd's pure core
# (docs/design-time.md, "The client"): the start flags' server list, the schedule
# over generated event sequences and the clock facet request, against the erx and
# erx_ntpd applications compiled from source with warnings as errors on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxNtpdTest < Minitest::Test
  APPLICATIONS = %w[erx erx_ntpd].freeze
  TESTS = %w[test/erlang/erx_ntp_core_tests.erl].freeze

  def test_ntpd_core_cases_pass_under_eunit
    Dir.mktmpdir('erx-ntpd-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_ntp_core_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
