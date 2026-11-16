# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The facets a session mounts (docs/design-packaging.md, "An app's session"):
# test/erlang/erx_session_app_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies) against the sources as they are.
class ErxSessionAppTest < Minitest::Test
  APPLICATIONS = %w[erx_session].freeze
  TESTS = %w[test/erlang/erx_session_app_tests.erl].freeze

  def test_the_cases_pass
    output, status = Dir.mktmpdir('erx-session-app-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      run = 'halt(case eunit:test(erx_session_app_tests, [verbose]) of ok -> 0; _ -> 1 end)'
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', run, chdir: work, stdin_data: '')
    end
    assert status.success?, output
    assert_match(/\d+ tests passed/, output)
  end
end
