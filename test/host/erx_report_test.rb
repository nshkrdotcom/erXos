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
# seeded fault, applied to a copy of erx_report, must fail the case named for it. The boot
# cases load the tree's logger over the kernel's and check that another domain's runtime
# takes the filter ahead of its own and the system domain's none; a logger without the install fails.
class ErxReportTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_report_tests.erl].freeze
  DEADLINE_SECONDS = '120'
  REPORT = 'erlang/apps/erx/src/erx_report.erl'
  BOOT_TESTS = %w[test/erlang/erx_report_boot_tests.erl].freeze
  INSPECTOR = 'erlang/apps/erx/src/erx_inspector.erl'
  SYSTEM_RUNTIME = "is_system_runtime() ->\n    boot() =:= {erx_kernel_records:system_domain(), none}.\n"
  LOGGER = 'otp/lib/kernel/src/logger.erl'
  LOGGER_INSTALL = ' ++ erx_report:primary_filters()'
  KERNEL = File.join(ErlangBuild::ROOT, 'otp/lib/kernel')

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: "a crash report's message queue passed through",
             anchor: "fact(_Other, S) -> S.\n",
             replacement: "fact({messages, Messages}, S) -> S\#{messages => Messages};\nfact(_Other, S) -> S.\n",
             catching_case: 'controller_crash_reports_carry_no_term_test'),
    Seed.new(fault: "each frame's arguments kept",
             anchor: '        Arity -> [{M, F, Arity} | frames(Frames)]',
             replacement: '        _Arity -> [{M, F, Arguments} | frames(Frames)]',
             catching_case: 'statem_report_keeps_names_test'),
    Seed.new(fault: 'the sys log shown as a count rather than empty',
             anchor: 'default(log, _Value) -> [];',
             replacement: 'default(log, Log) -> {events, length(Log)};',
             catching_case: 'status_shows_only_what_the_views_name_test')
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

  def test_another_domain_boots_with_the_filter_first
    assert_equal '[erx_report,own]', filters_at_boot(system: false)
  end

  def test_the_system_domain_boots_without_the_filter
    assert_equal '[own]', filters_at_boot(system: true)
  end

  def test_a_logger_without_the_install_leaves_another_domain_unfiltered
    logger = File.read(File.join(ErlangBuild::ROOT, LOGGER))
    assert_equal 1, logger.scan(LOGGER_INSTALL).size, 'seed anchor is not unique'
    assert_equal '[own]', filters_at_boot(system: false, logger: logger.sub(LOGGER_INSTALL, ''))
  end

  private

  # The primary filters the tree's logger (or logger, its seeded text) leaves when the
  # kernel's logger is configured in the system domain's runtime or another domain's, as
  # printed by erx_report_boot_tests. erx_inspector answers for another domain's runtime
  # once its test of the boot page is replaced by false.
  def filters_at_boot(system:, logger: File.read(File.join(ErlangBuild::ROOT, LOGGER)))
    inspector = File.read(File.join(ErlangBuild::ROOT, INSPECTOR))
    assert_equal 1, inspector.scan(SYSTEM_RUNTIME).size, 'erx_inspector anchor is not unique'
    replaced = system ? {} : { INSPECTOR => inspector.sub(SYSTEM_RUNTIME, "is_system_runtime() -> false.\n") }
    Dir.mktmpdir('erx-report-boot') do |work|
      ErlangBuild.compile(work, applications: %w[erx], tests: BOOT_TESTS, replaced: replaced)
      source = File.join(work, 'logger.erl')
      File.write(source, logger)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', File.join(KERNEL, 'src'),
                                       '-I', File.join(KERNEL, 'include'), '-o', work, source, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-nostick', '-pa', work, '-eval',
                                       'erx_report_boot_tests:primary_filters_at_boot(), halt(0).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      output[/^filters: (.*)$/, 1] || flunk(output)
    end
  end

  def run_cases(replaced)
    Dir.mktmpdir('erx-report-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_report_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
