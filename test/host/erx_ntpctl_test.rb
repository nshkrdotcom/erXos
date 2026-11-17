# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_ntp_tests.erl and test/erlang/erx_cmd_ntpctl_tests.erl, the
# EUnit cases of the NTP codec, the checks of one reply, an exchange's datagrams
# and the command shell's
# `ntpctl` (docs/design-time.md, "Setting the clock from a server once"), against
# the erx and erx_shell applications compiled from source with warnings as errors on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). Then the
# seeded fault, `ntpctl step` applying ntpd's sample that the clock service refused
# as before the floor, is compiled in place of the command, and the cases must fail.
class ErxNtpctlTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx erx_shell].freeze
  TESTS = %w[test/erlang/erx_ntp_tests.erl test/erlang/erx_cmd_ntpctl_tests.erl].freeze
  COMMAND = 'erlang/apps/erx_shell/src/erx_cmd_ntpctl.erl'
  FLOOR_CLAUSE = <<~ERLANG
    applicable(_W, Address, floor, _AgeNs) ->
        {error, iolist_to_binary([<<"ntpd's sample of ">>, erx_text:escape_field(Address),
                                  <<" is before the build date (refused as floor); nothing set">>])};
  ERLANG

  def test_ntp_and_ntpctl_cases_pass_under_eunit
    Dir.mktmpdir('erx-ntpctl-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = eunit(work)
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_applying_a_sample_refused_as_floor_is_caught
    text = File.read(File.join(ROOT, COMMAND))
    assert_equal 1, text.scan(FLOOR_CLAUSE).size, "the floor clause must occur once in #{COMMAND}"
    Dir.mktmpdir('erx-ntpctl-fault') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS,
                                replaced: { COMMAND => text.sub(FLOOR_CLAUSE, '') })
      output, status = eunit(work)
      refute status.success?, "the cases passed with a floor sample applied:\n#{output}"
      assert_match(/Failed: [1-9]/, output)
    end
  end

  private

  def eunit(work)
    Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                    '-eval', 'halt(case eunit:test([erx_ntp_tests, erx_cmd_ntpctl_tests]) of ok -> 0; _ -> 1 end).',
                    chdir: work, stdin_data: '')
  end
end
