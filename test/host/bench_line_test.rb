# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../tools/fuzz/bench_line'

# The BENCH line validator (docs/design-bench.md, "A benchmark", "Verification"): a
# guest's line is accepted whole or refused whole, with a reason that never quotes it.
class BenchLineTest < Minitest::Test
  Fuzz = Erx::BenchLineFuzz

  def cell(text) = Erx::BenchMeasurement.cell(text, benchmark: 'wake', profiles: Fuzz::PROFILES)

  def refusal(text)
    assert_raises(Erx::Error) { cell(text) }.message
  end

  def test_each_profiles_line_is_accepted_with_its_derived_summary
    Fuzz::PROFILES.each do |operation, profile|
      accepted = cell(Fuzz.line(operation))
      assert_equal [operation, 'measured', profile.samples],
                   [accepted.operation, accepted.status, accepted.summary.fetch('samples')]
      assert_equal 'wake/' + operation + '.json', accepted.file
    end
  end

  def test_the_lines_names_never_reach_a_file_name
    assert_match(/operation is not one the benchmark declares/, refusal(Fuzz.line('wake-same-cpu',
                                                                                  operation: 'erlang-timer')))
    assert_match(/benchmark is not the benchmark run/, refusal(Fuzz.line('wake-same-cpu', benchmark: 'sched')))
  end

  def test_a_refusal_never_quotes_the_line
    hostile = "\e]8;;x\a"
    [Fuzz.line('wake-same-cpu', reason: hostile, status: 'partial'),
     Fuzz.line('wake-same-cpu', hostile => 1),
     "BENCH {\"#{hostile}\": 1}"].each do |text|
      message = refusal(text)
      refute_includes message, "\e"
      refute_includes message, ']8;;'
    end
  end

  def test_a_histogram_past_its_samples_is_refused
    assert_match(/histogram is not ascending/, refusal(Fuzz.repeat_bucket(Fuzz.line('wake-same-cpu'), 2)))
    assert_match(/histogram does not hold every sample/,
                 refusal(Fuzz.line('wake-same-cpu', histogram: [[1000, 1000, 41]], min: 1000, max: 1000)))
  end

  def test_fields_that_disagree_are_refused
    largest = JSON.parse(Fuzz.line('wake-same-cpu').delete_prefix('BENCH ')).fetch('largest')
    {
      { 'samples' => 39 } => /histogram does not hold every sample/,
      { 'samples' => 41 } => /samples is not a count/,
      { 'samples' => 40.0 } => /samples is not a count/,
      { 'max' => 5000 } => /lie in the histogram buckets/,
      { 'largest' => largest.reverse } => /descending order from the maximum/,
      { 'largest' => [largest.first] * 16 } => /names one sample twice/,
      { 'status' => 'timed_out', 'reason' => 'x' } => /status is not one a guest reports/,
      { 'status' => 'measured', 'reason' => 'x' } => /needs its reason/,
      { 'raw' => [1] } => /field of another profile/,
      { 'counts' => { 'lost' => 0, 'early' => 0 } } => /lost, early and missed/,
      { 'frequency_hz' => 0 } => /frequency/
    }.each do |override, reason|
      assert_match(reason, refusal(Fuzz.line('wake-same-cpu', **override.transform_keys(&:to_sym))), override.inspect)
    end
  end

  def without(text, field)
    fields = JSON.parse(text.delete_prefix('BENCH '))
    fields.delete(field)
    "BENCH #{JSON.generate(fields)}"
  end

  # A cell reports its sixteen largest samples, or every sample when it has fewer, and
  # an expensive cell every sample.
  def test_the_largest_and_the_raw_samples_are_complete
    largest = JSON.parse(Fuzz.line('wake-same-cpu').delete_prefix('BENCH ')).fetch('largest')
    assert_match(/largest is not the sixteen largest/, refusal(Fuzz.line('wake-same-cpu', largest: largest.first(15))))
    assert_match(/raw/, refusal(without(Fuzz.line('trigger-take'), 'raw')))
  end

  # Every refusal of a BENCH line says so, the cell's own checks included.
  def test_a_refusal_names_the_bench_line
    assert_match(/\ABENCH line .*uncertainty/, refusal(Fuzz.line('wake-same-cpu', uncertainty: 1000)))
    assert_match(/\ABENCH line /, refusal(Fuzz.line('wake-same-cpu', min: 1150)))
  end

  def test_a_boots_cells_need_its_one_valid_clock_line
    lines = [Fuzz.line('wake-same-cpu')]
    measured = Erx::BenchMeasurement.boot(lines + [Fuzz.clock_line], benchmark: 'wake', profiles: Fuzz::PROFILES)
    assert_equal [['measured', nil]], measured.fetch(:cells).map { |cell| [cell.status, cell.reason] }
    assert_equal 24_000_000, measured.fetch(:clock).fetch('frequency_hz')
    # A refused line costs only its own cell, and its reason never quotes it.
    kept = Erx::BenchMeasurement.boot(lines + ['BENCH zz-secret', nil, Fuzz.clock_line], benchmark: 'wake',
                                                                                           profiles: Fuzz::PROFILES)
    assert_equal ['measured'], kept.fetch(:cells).map(&:status)
    assert_equal 2, kept.fetch(:refused).size
    refute kept.fetch(:refused).any? { |reason| reason.include?('zz-secret') }
    [lines, lines + [Fuzz.clock_line(increment: 0)], lines + [Fuzz.clock_line] * 2].each do |boot|
      answer = Erx::BenchMeasurement.boot(boot, benchmark: 'wake', profiles: Fuzz::PROFILES)
      assert_equal [['rejected', 'no valid CLOCK line in the boot', 0]],
                   answer.fetch(:cells).map { |cell| [cell.status, cell.reason, cell.detail.size] }
      assert_nil answer.fetch(:clock)
    end
    other = Erx::BenchMeasurement.boot(lines + [Fuzz.clock_line(frequency_hz: 62_500_000)],
                                       benchmark: 'wake', profiles: Fuzz::PROFILES)
    assert_equal [['rejected', 'frequency differs from the CLOCK line']],
                 other.fetch(:cells).map { |cell| [cell.status, cell.reason] }
  end

  # A wrong result does not depend on the clock: without a calibration the measured and
  # unsupported cells are rejected, but a failed cell stays failed with its samples.
  def test_a_failed_cell_stays_failed_without_a_calibration
    lost = { 'lost' => 1, 'early' => 0, 'missed' => 0 }
    unsupported = Fuzz.line('trigger-take', status: 'unsupported', reason: 'one CPU', samples: 0, histogram: [],
                                             largest: [], raw: [])
    lines = [Fuzz.line('wake-same-cpu'), without(without(unsupported, 'min'), 'max'),
             Fuzz.line('wake-same-cpu', status: 'failed', reason: 'lost wake', counts: lost)]
    [lines, lines + [Fuzz.clock_line(frequency_hz: 62_500_000)]].each do |boot|
      answer = Erx::BenchMeasurement.boot(boot, benchmark: 'wake', profiles: Fuzz::PROFILES)
      assert_equal [], answer.fetch(:refused).grep(/BENCH/)
      cells = answer.fetch(:cells)
      assert_equal %w[rejected rejected failed], cells.map(&:status)
      assert_equal 'lost wake', cells.last.reason
      refute_empty cells.last.detail
    end
  end

  def test_a_wrong_answer_is_failed_and_a_partial_cell_says_so
    assert_raises(Erx::Error) { cell(Fuzz.line('wake-same-cpu', counts: { 'lost' => 1, 'early' => 0, 'missed' => 0 })) }
    failed = cell(Fuzz.line('wake-same-cpu', status: 'failed', reason: 'lost wake',
                                             counts: { 'lost' => 1, 'early' => 0, 'missed' => 0 }))
    assert_equal 'failed', failed.status
    assert failed.summary.fetch('partial')
  end

  def test_a_line_that_is_not_one_bounded_json_object_is_refused
    [['BENCH ', /not one JSON object/], ['BENCH []', /not a JSON object/], ['BENCH {"a":1,"a":1}', /not one JSON/],
     ["BENCH #{'[' * 5}1#{']' * 5}", /nested at most four/], ["BENCH {\"benchmark\":\"wake\"}\n", /printable/],
     ["BENCH {#{' ' * (64 << 10)}}", /longer than 64 KiB/], ['bench {}', /does not begin with BENCH/],
     [Fuzz.line('wake-same-cpu', status: 'partial', reason: 'x').sub('"x"', '"\udfff"'), /backslash/],
     ['BENCH {/* */}', /slash/]].each do |text, reason|
      assert_match(reason, refusal(text))
    end
  end

  def test_the_fuzzer_runs_clean_over_its_seeds
    assert_operator Fuzz.run(seconds: 1, seed: 7), :>, 100
  end
end
