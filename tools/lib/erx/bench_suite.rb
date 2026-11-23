# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_record'
require_relative 'declaration_files'
require_relative 'error'

module Erx
  # The benchmarks' declarations and the landing `bench` QEMU suite built from them
  # (docs/design-bench.md, "A benchmark", "The gates"). Each benchmark is one file in
  # benches/, named after it and found by globbing, as a QEMU suite is; the file calls
  # declare_benchmark once with its operations and its landing cells per boot. The
  # suite's cells are each boot's benchmarks, and each takes the worst of its benchmark
  # cells' statuses through SUITE_STATUS.
  module BenchSuite
    # An operation: an exact act with a start and an end on one clock, the profile it is
    # sampled by, and what a correct result of the act is.
    Operation = Data.define(:name, :profile, :result) do
      def initialize(name:, profile:, result:)
        BenchRecord.check(name.is_a?(String) && BenchRecord::NAME.match?(name), 'operation is not a plain name')
        BenchRecord.check(BenchRecord::PROFILES.include?(profile), 'profile is not one of the profiles')
        BenchRecord.check(result.is_a?(String) && !result.empty?, "#{name} does not say what a correct result is")
        super
      end
    end

    # A placement names where a cell's work runs; its value is the CPUs an environment
    # needs for it. A cell on two CPUs is expected unsupported where there is one.
    PLACEMENTS = {
      'same-cpu' => 1, 'cross-cpu' => 2, 'service-cpu' => 1, 'other-cpu' => 2, 'runtime' => 1
    }.freeze

    # One cell of the landing matrix: an operation under a load cell, a placement and
    # the workload parameters that differ from the operation's defaults.
    LandingCell = Data.define(:operation, :load, :placement, :parameters) do
      def initialize(operation:, load:, placement:, parameters:)
        BenchRecord.check(PLACEMENTS.key?(placement), 'placement is not one of the placements')
        BenchRecord.check(load.is_a?(String) && BenchRecord::NAME.match?(load), 'load cell is not a plain name')
        BenchRecord.check(BenchRecord.plain_hash?(parameters), 'workload parameters are not a map')
        super(operation: operation, load: load, placement: placement, parameters: parameters.freeze)
      end
    end

    # A landing boot: the environment kind and CPU count it boots at.
    Boot = Data.define(:kind, :cpus)
    BOOTS = {
      'native' => Boot.new(kind: 'qemu-hvf', cpus: 4),
      'xdomain' => Boot.new(kind: 'qemu-hvf', cpus: 4)
    }.freeze

    # A benchmark: its operations by name and its landing cells per boot, each naming a
    # declared operation.
    Benchmark = Data.define(:name, :operations, :landing) do
      def initialize(name:, operations:, landing:)
        BenchRecord.check(BenchRecord::NAME.match?(name), "benchmark #{name.dump} is not a plain name")
        BenchRecord.check(landing.keys.all? { |boot| BOOTS.key?(boot) }, "#{name} names a boot the suite lacks")
        unknown = landing.values.flatten.map(&:operation).uniq - operations.keys
        BenchRecord.check(unknown.empty?, "#{name}'s landing matrix names an operation it does not declare")
        super(name: name, operations: operations.freeze, landing: landing.transform_values(&:freeze).freeze)
      end
    end

    # A benchmark cell's status to its suite cell (docs/design-bench.md, "Cells and suite
    # cells"); an unsupported cell the environment is expected to lack passes instead.
    SUITE_STATUS = {
      'measured' => 'passed', 'unsupported' => 'partial', 'partial' => 'partial', 'rejected' => 'partial',
      'timed_out' => 'timed_out', 'not_run' => 'not_run', 'failed' => 'failed'
    }.freeze
    # Suite cell statuses from worst to best.
    WORST_FIRST = %w[failed timed_out not_run partial passed].freeze

    BENCHMARK_FILES = DeclarationFiles.new('benchmarks')

    module_function

    # Each file under benches/ calls this exactly once.
    def declare_benchmark(operations:, landing:)
      BENCHMARK_FILES.declare([operations, landing])
    end

    def benchmarks
      @benchmarks ||= BENCHMARK_FILES.load_all(File.join(__dir__, 'benches')).to_h do |name, (operations, landing)|
        [name, Benchmark.new(name: name, operations: operations.to_h { |operation| [operation.name, operation] },
                             landing: landing)]
      end.freeze
    end

    def benchmark(name) = benchmarks.fetch(name) { raise Error, "unknown benchmark #{name}" }

    # The suite's cells: each boot's benchmarks, named as a QEMU cell that carries its
    # case (Erx::QemuCells::CELL_CASE_NAME): "hvf-4cpu-native-wake".
    def suite_cells
      BOOTS.flat_map do |boot, entry|
        configuration = "#{entry.kind.delete_prefix('qemu-')}-#{entry.cpus}cpu"
        benchmarks.values.select { |declared| declared.landing.key?(boot) }
                  .map { |declared| "#{configuration}-#{boot}-#{declared.name}" }
      end
    end

    # The suite cell of one benchmark in one boot, from its cells' [status,
    # expected_unsupported] pairs: the worst of their suite statuses, not_run for none.
    def suite_cell(cells)
      return 'not_run' if cells.empty?

      cells.map { |status, expected| status == 'unsupported' && expected ? 'passed' : SUITE_STATUS.fetch(status) }
           .min_by { |status| WORST_FIRST.index(status) }
    end

    # Whether environment lacks the CPUs cell's placement needs, so unsupported is the
    # answer the declaration expects there. Deterministic mode runs one CPU.
    def expected_unsupported?(cell, environment)
      cpus = environment.kind == 'qemu-det' ? 1 : environment.cpus
      !cpus.nil? && cpus < PLACEMENTS.fetch(cell.placement)
    end

    # The suite's run. No boot of the landing matrix has its bench image, so every cell
    # is pending, the gate's status for a cell whose call does not exist; a suite whose
    # every cell is pending does not fail the gate.
    def run(_context)
      { cells: suite_cells.to_h { |cell| [cell, 'pending'] },
        notes: ['bench: the landing matrix has no bench image to boot'] }
    end
  end
end
