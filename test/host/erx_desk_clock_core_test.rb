# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_desk_clock_core_tests.erl, the EUnit cases of clock's core
# (docs/design-desktop-programs.md, the clock rows of "Verification and testing", D3, D5
# and D6), against erx_desk compiled from source on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies), and plants each row's seeded fault to see its case
# fail.
class ErxDeskClockCoreTest < Minitest::Test
  TESTS = %w[test/erlang/erx_ui_query.erl test/erlang/erx_desk_clock_core_tests.erl].freeze
  CORE = 'erlang/apps/erx_desk/src/erx_desk_clock_core.erl'
  DEADLINE = '120'

  # Each fault replaces one passage of the core, and the case it names must fail.
  Fault = Data.define(:name, :from, :to, :caught_by)
  FAULTS = [
    Fault.new(name: 'the state ignored (D3)',
              from: 'unset -> unset_face(Machine);', to: 'unset -> dated(Now, utc(), []);',
              caught_by: 'the_unset_clock_shows_no_date_test'),
    Fault.new(name: 'the next tick set 60 s after the last instead of from the reading',
              from: '?MINUTE - Now rem ?MINUTE', to: '?MINUTE',
              caught_by: 'each_tick_shows_the_minute_it_read_test'),
    Fault.new(name: 'a once-a-second tick (D6)',
              from: '?MINUTE - Now rem ?MINUTE', to: '1000',
              caught_by: 'one_tree_a_minute_test'),
    Fault.new(name: 'a value that is no status passed into the tree as one (D5)',
              from: 'token(Reporter, _Value) -> {Reporter, unknown}.', to: 'token(Reporter, Value) -> {Reporter, Value}.',
              caught_by: 'every_tree_is_valid_test'),
    Fault.new(name: "the wall clock read before the state: the tick's reading shown",
              from: '{answered(Tag, Answer, Read, State), []};', to: '{answered(Tag, Answer, none, State), []};',
              caught_by: 'a_clock_set_between_the_reads_shows_the_later_reading_test')
  ].freeze
  # An EUnit run: whether it passed, EUnit's report, and both streams for messages.
  EunitRun = Data.define(:passed, :report, :text)

  def test_clock_core_cases_pass_under_eunit
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
    Dir.mktmpdir('erx-desk-clock-core-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx_desk], tests: TESTS, replaced: replaced)
      report, errors, status = Open3.capture3('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell',
                                              '-pa', work, '-eval',
                                              'halt(case eunit:test(erx_desk_clock_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                              chdir: work, stdin_data: '')
      EunitRun.new(passed: status.success?, report: report, text: "#{report}\n--- standard error ---\n#{errors}")
    end
  end
end
