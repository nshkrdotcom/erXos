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
    {
      { 'samples' => 39 } => /measured cell lacks samples/,
      { 'samples' => 41 } => /samples is not a count/,
      { 'samples' => 40.0 } => /samples is not a count/,
      { 'max' => 5000 } => /outside the histogram buckets/,
      { 'largest' => [[0, 1001], [1, 1199]] } => /descending order from the maximum/,
      { 'largest' => [[0, 1199], [0, 1199]] } => /names one sample twice/,
      { 'status' => 'timed_out', 'reason' => 'x' } => /status is not one a guest reports/,
      { 'status' => 'measured', 'reason' => 'x' } => /reason is absent where it is needed/,
      { 'raw' => [1] } => /field of another profile/,
      { 'counts' => { 'lost' => 0, 'early' => 0 } } => /lost, early and missed/,
      { 'frequency_hz' => 0 } => /frequency/
    }.each do |override, reason|
      assert_match(reason, refusal(Fuzz.line('wake-same-cpu', **override.transform_keys(&:to_sym))), override.inspect)
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
     ["BENCH #{'[' * 4}1#{']' * 4}", /nested at most three/], ["BENCH {\"benchmark\":\"wake\"}\n", /printable/],
     ["BENCH {#{' ' * (64 << 10)}}", /longer than 64 KiB/], ['bench {}', /not a BENCH line/],
     [Fuzz.line('wake-same-cpu', status: 'partial', reason: 'x').sub('"x"', '"\udfff"'), /backslash/],
     ['BENCH {/* */}', /slash/]].each do |text, reason|
      assert_match(reason, refusal(text))
    end
  end

  def test_the_fuzzer_runs_clean_over_its_seeds
    assert_operator Fuzz.run(seconds: 1, seed: 7), :>, 100
  end
end
