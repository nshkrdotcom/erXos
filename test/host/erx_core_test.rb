# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_core_tests.erl, the cases of the edge's one loop,
# erx_core:perform/3 (docs/style.md, "Functional core"), compiled from source on stock's
# emulator (ERX_ERL and ERX_ERLC). Then the seeded fault that removes the refusal of a
# stop that is not last must fail the case named for it.
class ErxCoreTest < Minitest::Test
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_core_tests.erl].freeze
  DEADLINE_SECONDS = '120'
  CORE = 'erlang/apps/erx/src/erx_core.erl'
  REFUSAL = "perform([{stop, _Reason} | _After], _Effect, _State) -> error(stop_not_last);\n"

  def test_core_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_removed_refusal_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, CORE))
    assert_equal 1, source.scan(REFUSAL).size, 'seed anchor is not unique'
    output, status = run_cases({ CORE => source.sub(REFUSAL, '') })
    refute status.success?, 'the cases passed without the refusal'
    assert_match(/a_stop_not_last_is_refused_test[^\n]*\*failed\*/, output)
  end

  private

  def run_cases(replaced)
    Dir.mktmpdir('erx-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
