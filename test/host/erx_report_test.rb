# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_report_tests.erl, the cases of the report filter erx_report
# (docs/design-log.md, "Reports carry no term"), compiled from source with erx_bt, whose
# controller process it crashes, on stock's emulator (ERX_ERL and ERX_ERLC). Then each
# seeded fault, applied to a copy of erx_report, must fail the case named for it.
class ErxReportTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_report_tests.erl].freeze
  DEADLINE_SECONDS = '120'
  REPORT = 'erlang/apps/erx/src/erx_report.erl'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: "a crash report's message queue passed through",
             anchor: "fact(_Other, S) -> S.\n",
             replacement: "fact({messages, Messages}, S) -> S\#{messages => Messages};\nfact(_Other, S) -> S.\n",
             catching_case: 'controller_crash_reports_carry_no_term_test'),
    Seed.new(fault: "each frame's arguments kept",
             anchor: '        Arity -> [{M, F, Arity} | frames(Frames)]',
             replacement: '        _Arity -> [{M, F, Arguments} | frames(Frames)]',
             catching_case: 'statem_report_keeps_names_test')
  ].freeze

  def test_report_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, REPORT))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ REPORT => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    Dir.mktmpdir('erx-report-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_report_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
