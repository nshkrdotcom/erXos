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
end
