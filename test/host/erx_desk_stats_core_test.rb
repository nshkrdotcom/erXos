# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_desk_stats_core_tests.erl, the EUnit cases of stats' core
# (docs/design-desktop-programs.md, the stats rows of "Verification and testing"),
# against erx_desk compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies), and plants each row's seeded fault to see its case fail.
class ErxDeskStatsCoreTest < Minitest::Test
  TESTS = %w[test/erlang/erx_desk_stats_core_tests.erl].freeze
  CORE = 'erlang/apps/erx_desk/src/erx_desk_stats_core.erl'
  DEADLINE = '120'

  # Each fault replaces one passage of the core, and the case it names must fail.
  Fault = Data.define(:name, :from, :to, :caught_by)
  FAULTS = [
    Fault.new(name: 'partial kept as ok',
              from: "true -> partial;\n", to: "true -> ok;\n",
              caught_by: 'derivation_follows_the_status_table_test'),
    Fault.new(name: 'a share divided by the period without the grant',
              from: 'Used div (Ms * Capacity)', to: 'Used div (Ms * 1000)',
              caught_by: 'shares_and_rates_match_hand_computed_values_test'),
    Fault.new(name: 'the reset check removed',
              from: "grown(Old, New, _Ms) when New < Old -> {gap, reset};\n", to: '',
              caught_by: 'counter_that_goes_down_is_a_gap_test'),
    Fault.new(name: 'a tick that samples while the last sample waits',
              from: 'step({tick, Now}, #stats{sampling = true, sample = none} = State)',
              to: 'step({tick, Now}, #stats{sampling = true} = State)',
              caught_by: 'at_most_one_sample_is_in_flight_test'),
    Fault.new(name: 'the tag check removed',
              from: 'when is_map_key(Tag, Waiting) ->', to: 'when is_map(Waiting) ->',
              caught_by: 'an_answer_of_an_earlier_sample_changes_nothing_test'),
    Fault.new(name: 'a ring that stores partial values',
              from: 'share_point({ok, Share}) ->', to: 'share_point({_Status, Share}) when is_integer(Share) ->',
              caught_by: 'partial_sample_leaves_a_gap_test'),
    Fault.new(name: 'a division by zero answered as 0',
              from: 'share(_Part, 0, Fact) -> {gap, Fact};', to: 'share(_Part, 0, _Fact) -> 0;',
              caught_by: 'zero_denominators_give_their_facts_test'),
    Fault.new(name: 'an unsupported path answered as zero',
              from: 'failure({error, unsupported}) -> {gap, unsupported};', to: 'failure({error, unsupported}) -> {ok, 0};',
              caught_by: 'unsupported_connections_show_the_token_test'),
    Fault.new(name: "a sub-path's scope answer ending its domain's row",
              from: "{[domains, Id], {error, scope}}", to: "{[domains, Id | _], {error, scope}}",
              caught_by: "undeclared_connections_keep_their_rows_test"),
    Fault.new(name: "an interval that is not positive divided by",
              from: "grown(_Old, _New, Ms) when Ms =< 0 -> {gap, no_previous};\n", to: "",
              caught_by: "an_interval_that_is_not_positive_gives_no_value_test"),
    Fault.new(name: 'a CPU panel that reads running_thread',
              from: 'increase([cpus, N], idle_time,', to: 'increase([cpus, N], running_thread,',
              caught_by: 'scoped_facet_shows_the_same_machine_test')
  ].freeze
  # An EUnit run: whether it passed, EUnit's report, and both streams for messages.
  EunitRun = Data.define(:passed, :report, :text)

  def test_stats_core_cases_pass_under_eunit
    run = eunit_run
    assert run.passed, run.text
    assert_match(/All \d+ tests passed/, run.report)
  end

  def test_the_cases_catch_each_seeded_fault
    source = File.read(File.join(ErlangBuild::ROOT, CORE))
    FAULTS.each do |fault|
      assert_equal 1, source.scan(fault.from).size, fault.name
      run = eunit_run(replaced: { CORE => source.sub(fault.from, fault.to) })
      refute run.passed, "#{fault.name} passed:\n#{run.text}"
      assert_match(/#{fault.caught_by}[^\n]*\*(failed|timed out)\*/, run.report, "#{fault.name}:\n#{run.text}")
    end
  end

  private

  def eunit_run(replaced: {})
    Dir.mktmpdir('erx-desk-stats-core-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx_desk], tests: TESTS, replaced: replaced)
      report, errors, status = Open3.capture3('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell',
                                              '-pa', work, '-eval',
                                              'halt(case eunit:test(erx_desk_stats_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                              chdir: work, stdin_data: '')
      EunitRun.new(passed: status.success?, report: report, text: "#{report}\n--- standard error ---\n#{errors}")
    end
  end
end
