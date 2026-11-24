# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_measurement'
require_relative 'bench_record'
require_relative 'boot_image'
require_relative 'error'
require_relative 'fiasco'
require_relative 'native_root'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # The native bench image (docs/design-bench.md, "1. `wake`: how late a waiting thread runs"): test/guest/native_bench's
  # root times the wake benchmark's native landing cells and prints a BENCH line for each
  # and one CLOCK line, which BenchMeasurement.boot judges. Built with seed_lost_wake, the
  # root skips one wake, and wake-same-cpu must come back failed with one lost wake.
  module NativeBench
    MEMORY_MIB = 512
    BENCH_LIBRARY = %w[bench_clock bench_hist bench_line bench_periodic].map { |name| "test/guest/bench/#{name}.c" }.freeze
    SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, *NativeRoot::LAUNCH, *BENCH_LIBRARY,
               'test/guest/native_bench/guest.c'].freeze
    # The landing forms of the profiles the guest's cells take (docs/design-bench.md,
    # "Profiles"), which test/guest/native_bench/guest.c's FAST_ and PERIODIC_ constants state.
    LANDING_PROFILES = {
      'fast' => BenchRecord::Profile.new(name: 'fast', warmup: 1000, samples: 10_000, runs: 1),
      'periodic' => BenchRecord::Profile.new(name: 'periodic', warmup: 0, samples: 2000, runs: 1)
    }.freeze
    FAILED_LINE = /^erx: bench: .* FAILED/n
    GUEST_LINE = /\A(?:BENCH|CLOCK) /n

    module_function

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'bench-timing', pattern: /\Aerx: bench: timing/n, seconds: 60 },
       { name: 'bench-done', pattern: /\Aerx: bench: done/n, seconds: 600 }].freeze
    end

    # The BENCH and CLOCK lines of a serial log, each without its line end. They are the
    # guest's, untrusted: BenchMeasurement.boot is their one judge.
    def guest_lines(serial) = serial.b.split(/\r?\n/n).grep(GUEST_LINE)

    # The profile each operation of benchmark ran at, in its landing form.
    def profiles(benchmark)
      benchmark.operations.transform_values { |operation| LANDING_PROFILES.fetch(operation.profile, nil) }.compact
    end

    # Raises on a setup failure the guest named, which a transcript's timeout would only imply.
    def judge(serial)
      failed = FAILED_LINE.match(serial)
      raise Error, "the guest says #{failed[0].inspect}" if failed
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''),
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @platform = platform
      end

      # One boot of the image under accel at cpus CPUs, with the kernel as last built
      # unless asked to rebuild: its serial log, its seconds and the guest's lines.
      def call(accel:, cpus:, seed_lost_wake: false, build: false, jobs: 4)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco, seed_lost_wake: seed_lost_wake)
        directory = File.join(@root, 'build/qemu', "bench-#{accel}-#{cpus}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
        report = boot(built, accel: accel, cpus: cpus, directory: directory)
        serial = File.binread(report.fetch('serial_log'))
        { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds'),
          lines: NativeBench.guest_lines(serial) }.freeze
      end

      private

      def boot(built, accel:, cpus:, directory:)
        Qemu.new(root: @root, runner: @runner).run(platform: @platform, accel: accel, cpus: cpus, image: built.single,
                                                   memory_mib: MEMORY_MIB, checkpoints: NativeBench.checkpoints,
                                                   machine_end: true, directory: directory)
      rescue Error => e
        serial = File.join(directory, 'serial.log')
        NativeBench.judge(File.binread(serial)) if File.file?(serial)
        raise e
      end

      def image(fiasco, seed_lost_wake:)
        build = File.join(@root, 'build', seed_lost_wake ? 'native-bench-seeded' : 'native-bench')
        flags = ['-DERX_FIASCO_TEST_HOOKS', *(seed_lost_wake ? ['-DERX_BENCH_SEED_LOST_WAKE'] : [])]
        root_task = NativeRoot.new(root: @root, source: @root, runner: @runner, compiler: @compiler, linker: @linker,
                                   platform: @platform, fiasco: fiasco)
                              .build(name: 'bench-root', sources: SOURCES, directory: File.join(build, 'root'), flags: flags)
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(build, 'image'), stand_in_root: root_task)
      end
    end
  end
end
