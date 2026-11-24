# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_measurement'
require_relative 'bench_record'
require 'etc'
require_relative 'boot_image'
require_relative 'error'
require_relative 'fiasco'
require_relative 'native_root'
require_relative 'qemu'
require_relative 'runner'
require_relative 'source_revision'

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
    # The root's build flags: the test hooks, and the seeded fault when asked for.
    def flags(seed_lost_wake:) = ['-DERX_FIASCO_TEST_HOOKS', *(seed_lost_wake ? ['-DERX_BENCH_SEED_LOST_WAKE'] : [])].freeze

    def guest_lines(serial) = serial.b.split(/\r?\n/n).grep(GUEST_LINE)

    # The profile each operation of benchmark ran at, in its landing form.
    def profiles(benchmark)
      benchmark.operations.transform_values { |operation| LANDING_PROFILES.fetch(operation.profile, nil) }.compact
    end

    # What a boot of the image at cpus CPUs asks of its guest: the benchmark's native
    # landing cells at their profiles, on the counter, and the one pair the root (on CPU
    # 0) times wake-cross-cpu across, with the last CPU; none on one CPU.
    def asked(benchmark, cpus:)
      BenchMeasurement::Asked.new(benchmark: benchmark, cells: benchmark.landing.fetch('native'),
                                  profiles: profiles(benchmark), clock: 'counter',
                                  pairs: cpus > 1 ? [[0, cpus - 1]] : [])
    end

    # Whether a seeded boot's cells show its fault: the build skips one wake of
    # wake-same-cpu, so that cell is failed with a lost wake.
    def seed_caught?(cells)
      cells.any? { |cell| cell.operation == 'wake-same-cpu' && cell.status == 'failed' && cell.counts.fetch('lost').positive? }
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
      # unless asked to rebuild: its serial log, its seconds, the guest's lines, the
      # image's SHA-256, its build flags, QEMU's version, and the stored log a replayed
      # boot came from (nil for a fresh one).
      def call(accel:, cpus:, seed_lost_wake: false, build: false, jobs: 4)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        flags = NativeBench.flags(seed_lost_wake: seed_lost_wake)
        built = image(fiasco, seed_lost_wake: seed_lost_wake, flags: flags)
        directory = File.join(@root, 'build/qemu', "bench-#{accel}-#{cpus}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
        report = boot(built, accel: accel, cpus: cpus, directory: directory)
        serial = File.binread(report.fetch('serial_log'))
        { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds'),
          lines: NativeBench.guest_lines(serial), image_sha256: report.fetch('image_sha256'), flags: flags,
          compiler: @compiler, qemu_version: report['qemu_version'], reused_from: report['reused_from'] }.freeze
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

      def image(fiasco, seed_lost_wake:, flags:)
        build = File.join(@root, 'build', seed_lost_wake ? 'native-bench-seeded' : 'native-bench')
        root_task = NativeRoot.new(root: @root, source: @root, runner: @runner, compiler: @compiler, linker: @linker,
                                   platform: @platform, fiasco: fiasco)
                              .build(name: 'bench-root', sources: SOURCES, directory: File.join(build, 'root'), flags: flags)
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(build, 'image'), stand_in_root: root_task)
      end
    end
    # The native boot of the landing matrix (docs/design-bench.md, "The gates"): one boot
    # of the image and one of its seeded build. The first boot's lines, judged against
    # what it asked, are a record, which BenchRecord.write adds to the history unless the
    # boot was replayed from the gate's store; the second's show whether its fault was caught.
    class Landing
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     run: Run.new(root: root, runner: runner))
        @root = File.expand_path(root)
        @runner = runner
        @run = run
      end

      # benchmark's native cells booted as boot (a BenchSuite::Boot) says: the record, the
      # run directory written (nil for a replayed boot), the refused lines' reasons, and
      # whether the seeded boot was caught.
      def call(benchmark, boot:, history:)
        accel = boot.kind.delete_prefix('qemu-')
        asked = NativeBench.asked(benchmark, cpus: boot.cpus)
        date = Time.now.utc
        before = load_average
        measured = @run.call(accel: accel, cpus: boot.cpus)
        after = load_average
        seeded = @run.call(accel: accel, cpus: boot.cpus, seed_lost_wake: true)
        answer = BenchMeasurement.boot(measured.fetch(:lines), asked)
        record = BenchRecord::Record.new(
          environment: environment(boot, accel: accel, measured: measured), subject: subject(measured),
          run: BenchRecord::Run.new(date: date, started_by: 'landing', load: before && after && [before, after],
                                    host_cpus: Etc.nprocessors, reused_from: measured.fetch(:reused_from)),
          clock: answer.fetch(:clock) || {}, cells: answer.fetch(:cells)
        )
        written = unless record.run.replayed?
                    BenchRecord.write(record, history: history, erxos_root: @root, boots: [{ serial: measured.fetch(:serial) }])
                  end
        { record: record, written: written, refused: answer.fetch(:refused),
          seed_caught: NativeBench.seed_caught?(BenchMeasurement.boot(seeded.fetch(:lines), asked).fetch(:cells)) }
      end

      private

      def environment(boot, accel:, measured:)
        BenchRecord::Environment.new(
          kind: boot.kind, model: sysctl('hw.model'), cpus: boot.cpus, system: nil,
          details: { 'memory_mib' => MEMORY_MIB, 'accelerator' => accel, 'machine' => 'virt',
                     'qemu' => measured.fetch(:qemu_version), 'host_os' => RbConfig::CONFIG['host_os'] }.compact
        )
      end

      def subject(measured)
        revision = SourceRevision.read(root: @root, runner: @runner)
        raise Error, "bench: #{@root} is not a git checkout, so a record has no revision" unless revision

        BenchRecord::Subject.new(revision: revision.commit, dirty: revision.dirty,
                                 details: measured.slice(:image_sha256, :flags, :compiler).transform_keys(&:to_s))
      end

      # The host's one-minute load average, nil where it cannot be read.
      def load_average
        sysctl('vm.loadavg')[/\d+(?:\.\d+)?/]&.to_f
      rescue Error
        nil
      end

      def sysctl(name)
        result = @runner.run(['sysctl', '-n', name], name: "bench-sysctl-#{name.tr('.', '-')}", deadline: 10)
        File.binread(result.fetch('log'), 4096).strip
      end
    end
  end
end
