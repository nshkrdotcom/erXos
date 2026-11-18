# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'boot_image'
require_relative 'build_kind'
require_relative 'fiasco'
require_relative 'platform'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # A kernel trap on a release kernel ends the machine (docs/design-fiasco.md, "The
  # kernel"). A kernel built from the release configuration with one more define loads
  # from an unmapped address in kernel mode once boot is done; its run under QEMU
  # with -no-reboot must print the trap's panic and then end through PSCI's system
  # reset, which makes QEMU exit. A kernel that only kills the faulting thread and
  # returns to the load traps again and again until the deadline. No other image
  # boots that kernel, and its build is why make check-native-seeds runs this rather
  # than the QEMU gate.
  module NativeKernelTrap
    MEMORY_MIB = 512
    DEFINES = ['-DERX_TEST_KERNEL_TRAP'].freeze

    module_function

    # The panic line starts with the console's bold escape (kernel_panic.cc), so its
    # pattern is not anchored.
    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'kernel-trap-seed', pattern: /\Aerx: kernel trap seed\r?\n/n, seconds: 30 }.freeze,
       { name: 'kernel-trap-panic', pattern: /Panic: kernel trap/n, seconds: 30 }.freeze].freeze
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), platform: Platform.development(root))
        @root = File.expand_path(root)
        @platform = platform
        @runner = runner
        @compiler = compiler
        @linker = linker
        @build = File.join(@root, 'build/native-kernel-trap')
      end

      # Boots the image under accel on one CPU, on the release test kernel built from
      # the tree's sources, and returns the serial log's path. The real kernel's build must
      # have run, or does when build is true. A run that does not end the machine
      # after the panic raises.
      def call(accel:, jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        kernel = fiasco.build_test_kernel(name: 'kernel-trap', defines: DEFINES, kind: BuildKind::RELEASE, jobs: jobs)
        image = BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, kernel: kernel)
                         .build(directory: File.join(@build, 'image'))
        Qemu.new(root: @root, runner: @runner)
            .run(platform: @platform, accel: accel, cpus: 1, image: image.single, memory_mib: MEMORY_MIB,
                 checkpoints: NativeKernelTrap.checkpoints, machine_end: true)
            .fetch('serial_log')
      end
    end
  end
end
