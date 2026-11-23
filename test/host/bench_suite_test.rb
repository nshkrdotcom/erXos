# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/bench_suite'
require_relative '../../tools/lib/erx/qemu_gate'

# The bench suite's cells and the table from a benchmark cell's status to its suite cell
# (docs/design-bench.md, "The gates", "Cells and suite cells").
class BenchSuiteTest < Minitest::Test
  Suite = Erx::BenchSuite

  def test_each_status_maps_to_its_suite_cell
    expected = { 'measured' => 'passed', 'unsupported' => 'partial', 'partial' => 'partial', 'rejected' => 'partial',
                 'timed_out' => 'timed_out', 'not_run' => 'not_run', 'failed' => 'failed' }
    assert_equal Erx::BenchRecord::STATUSES.sort, expected.keys.sort
    expected.each do |status, cell|
      assert_equal cell, Suite.suite_cell([[status, false]]), status
    end
  end

  def test_an_expected_unsupported_cell_passes
    assert_equal 'passed', Suite.suite_cell([['measured', false], ['unsupported', true]])
    assert_equal 'partial', Suite.suite_cell([['measured', false], ['unsupported', false]])
  end

  def test_a_suite_cell_takes_its_worst_status
    assert_equal 'failed', Suite.suite_cell([['measured', false], ['failed', false], ['timed_out', false]])
    assert_equal 'timed_out', Suite.suite_cell([['not_run', false], ['timed_out', false]])
    assert_equal 'not_run', Suite.suite_cell([['partial', false], ['not_run', false]])
    assert_equal 'not_run', Suite.suite_cell([])
  end

  def test_unsupported_is_expected_only_where_the_environment_lacks_the_cpus
    four = Erx::BenchRecord::Environment.new(kind: 'qemu-hvf', model: 'Mac16,10', cpus: 4, system: nil, details: {})
    deterministic = Erx::BenchRecord::Environment.new(kind: 'qemu-det', model: nil, cpus: 1, system: nil, details: {})
    cell = ->(placement) { Suite::LandingCell.new(operation: 'wake-same-cpu', load: 'idle', placement: placement, parameters: {}) }
    refute Suite.expected_unsupported?(cell.call('cross-cpu'), four)
    assert Suite.expected_unsupported?(cell.call('cross-cpu'), deterministic)
    assert Suite.expected_unsupported?(cell.call('other-cpu'), deterministic)
    refute Suite.expected_unsupported?(cell.call('same-cpu'), deterministic)
  end

  def test_the_suite_cells_are_each_boots_benchmarks
    assert_equal %w[hvf-4cpu-native-wake hvf-4cpu-xdomain-wake], Suite.suite_cells
    declared = Erx::QemuGate.suites.find { |suite| suite.name == 'bench' }
    assert_equal Suite.suite_cells, declared.cells
    refute declared.offload
  end

  def test_the_wake_landing_cells_follow_the_matrix
    landing = Suite.benchmarks.fetch('wake').landing
    assert_equal %w[park-deadline trigger-take wake-cross-cpu wake-same-cpu], landing.fetch('native').map(&:operation).sort
    assert_equal %w[erlang-timer], landing.fetch('xdomain').map(&:operation)
  end

  def test_an_undeclared_benchmark_or_operation_is_refused
    assert_raises(Erx::Error) { Suite.benchmark('nonesuch') }
    assert_raises(Erx::Error) do
      Suite::Benchmark.new(name: 'wake', operations: {}, landing: { 'native' => [Suite::LandingCell.new(
        operation: 'park-deadline', load: 'idle', placement: 'service-cpu', parameters: {}
      )] })
    end
  end
end
