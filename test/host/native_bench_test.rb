# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/native_bench'
require_relative '../../tools/lib/erx/bench_suite'
require_relative '../../tools/fuzz/bench_line'

# What the native bench runner takes from a boot's serial log (docs/design-bench.md,
# "1. `wake`: how late a waiting thread runs"): only the guest's BENCH and CLOCK lines reach BenchMeasurement.boot, whole
# and without their line ends, and each operation is judged at its profile's landing form.
class NativeBenchTest < Minitest::Test
  def test_only_the_guests_lines_reach_the_judge_without_their_line_ends
    bench = Erx::BenchLineFuzz.line('wake-same-cpu')
    clock = Erx::BenchLineFuzz.clock_line
    serial = "Fiasco says BENCH {}\r\nerx: bench: timing\r\n#{bench}\r\n #{clock}\n#{clock}\nBENCHMARK x\n"
    assert_equal [bench, clock], Erx::NativeBench.guest_lines(serial)
  end

  def test_each_native_operation_is_judged_at_its_landing_profile
    profiles = Erx::NativeBench.profiles(Erx::BenchSuite.benchmark('wake'))
    assert_equal [10_000, 10_000, 10_000, 2000],
                 %w[wake-same-cpu wake-cross-cpu trigger-take park-deadline].map { |name| profiles.fetch(name).samples }
  end
  # The native image's root runs on CPU 0 and times wake-cross-cpu against the last CPU,
  # so a boot of n CPUs calibrates that one pair, and a boot of one CPU none.
  def test_the_boot_asks_for_the_native_cells_on_the_counter_and_the_last_cpus_pair
    wake = Erx::BenchSuite.benchmark('wake')
    asked = Erx::NativeBench.asked(wake, cpus: 4)
    assert_equal wake.landing.fetch('native'), asked.cells
    assert_equal ['counter', [[0, 3]]], [asked.clock, asked.pairs]
    assert_equal [], Erx::NativeBench.asked(wake, cpus: 1).pairs
  end

  # The seeded build skips one wake of wake-same-cpu: only that cell failed with a lost
  # wake shows the run caught it.
  def test_the_seeded_boot_is_caught_only_by_a_lost_wake_of_wake_same_cpu
    cell = lambda do |operation, status, lost|
      Erx::BenchRecord::Cell.new(
        benchmark: 'wake', operation: operation, profile: Erx::NativeBench::LANDING_PROFILES.fetch('fast'),
        conditions: Erx::BenchRecord::Conditions.new(load: 'idle', placement: 'same-cpu', parameters: {}, clock: 'counter', batch: 1),
        status: status, reason: status == 'failed' ? 'lost wake' : 'the guest printed no line for it',
        counts: { 'lost' => lost, 'early' => 0, 'missed' => 0 }, detail: {}
      )
    end
    assert Erx::NativeBench.seed_caught?([cell.call('wake-same-cpu', 'failed', 1), cell.call('trigger-take', 'not_run', 0)])
    refute Erx::NativeBench.seed_caught?([cell.call('wake-same-cpu', 'not_run', 0)])
    refute Erx::NativeBench.seed_caught?([cell.call('wake-cross-cpu', 'failed', 1)])
    refute Erx::NativeBench.seed_caught?([])
  end
end
