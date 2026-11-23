# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'boot_partition'
require_relative 'device_kinds'
require_relative 'error'
require_relative 'generated'
require_relative 'hardware'
require_relative 'output_directory'
require_relative 'pins'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'source_revision'

module Erx
  # The header probe card (docs/research-rpi4-header-probe.md), a card of its own for the
  # board checklist of docs/design-header-io.md, "Verification": the Raspberry Pi 4's
  # development card (BootPartition) with test/raspi4b/header_probe.c's program as its
  # kernel8.img, in bootstrap's place, and slot A's image area empty. The firmware,
  # config.txt, the board's tree and BL31 are the development card's own, so the probe
  # reads the registers as that card's firmware leaves them. Nothing of erXos links or
  # packs the program; only this card carries it.
  module HeaderProbe
    PLATFORM = 'raspi4b'
    SOURCE = 'test/raspi4b/header_probe.c'
    SCRIPT = 'test/raspi4b/header_probe.ld'
    DIRECTORY = 'build/probe-card/raspi4b-header'
    PROGRAM = 'header-probe.bin'
    RECEIPT = 'header-probe.receipt.json'
    # The console's peripheral: the probe writes through its generated accessors.
    CONSOLE_PERIPHERAL = 'mini_uart'
    # The SVD devices whose windows the probe reads, by the macro that takes each size.
    WINDOWS = { 'GPIO_WINDOW' => 'BCM2711_GPIO', 'CM_WINDOW' => 'CPRMAN' }.freeze
    # The specifications whose generated accessors the probe uses, and their generators:
    # the three SVD files, and the system registers for the counter and its frequency.
    PERIPHERALS = %w[hw/svd/bcm2711_gpio/bcm2711_gpio.svd hw/svd/cprman/cprman.svd hw/svd/mini_uart/mini_uart.svd].freeze
    SYSTEM_REGISTERS = 'hw/sysreg/aarch64.json'
    GENERATORS = %w[tools/lib/erx/hardware.rb tools/lib/erx/sysreg_headers.rb].freeze
    # The console's receive signal, the mini UART's (the pin table's uart1), whose pin's
    # GPLEV0 bit the probe samples.
    CONSOLE_RX = 'RXD1'
    PIN_TABLE = 'bcm2711'

    # The built program: its path and its build record, which the card's record carries.
    Program = Data.define(:path, :record)

    module_function

    # The macros the program takes (header_probe.c): the console's window from platform's
    # record; the GPIO and clock-manager windows' sizes from their SVD devices (devices,
    # Hardware.devices); the console's receive pin from table (a Pins::Table); and
    # revision, the string that names the build. Pure.
    def defines(platform, devices:, table:, revision:)
      console = console_device(platform)
      windows = WINDOWS.transform_values { |name| devices.find { |device| device.name == name }&.size }
      missing = windows.select { |_macro, size| size.nil? }.keys
      raise Error, "header probe: no SVD device for #{missing.join(', ')}" unless missing.empty?

      { 'CONSOLE_BASE' => console.fetch('base'), 'CONSOLE_SIZE' => console.fetch('size'), **windows }
        .map { |name, value| format('-D%s=0x%xu', name, value) } +
        ["-DCONSOLE_RX_PIN=#{console_rx_pin(table)}", %(-DPROBE_REVISION="#{revision}")]
    end

    # The record's console device, which must be the mini UART, the console the firmware
    # sets up for the card's config.txt.
    def console_device(platform)
      path = platform.record.fetch('console')
      device = platform.record.fetch('units').flat_map { |unit| unit.fetch('devices') }.find { |entry| entry['path'] == path }
      compatible = DeviceKinds.uart_compatible(CONSOLE_PERIPHERAL)
      raise Error, "header probe: #{platform.record_path}'s console #{path} is not a #{compatible}" unless device&.fetch('compatible') == compatible

      device
    end

    # The one header pin, of bank 0, that carries the console's receive signal; an on-board
    # pin may carry it too (GPIO 33's ALT5), but the console is on the header.
    def console_rx_pin(table)
      found = table.pins.select { |pin| table.header_pin?(pin.gpio) && pin.functions.include?(CONSOLE_RX) }
      raise Error, "header probe: #{found.size} header pins of the pin table carry #{CONSOLE_RX}, not one" unless found.size == 1

      found.first.gpio
    end

    # The compile and link argument vectors for the program at output, a flat binary that
    # starts at address, where the firmware loads kernel8.img. Pure.
    def build_argvs(compiler:, linker:, root:, object:, output:, defines:, address:)
      [[compiler, '--target=aarch64-none-elf', '-std=c17', '-ffreestanding', '-fno-pic', '-mgeneral-regs-only',
        '-mstrict-align', '-O2', '-Wall', '-Wextra', '-Werror', '-pedantic', *Generated.include_flags(root: root),
        '-I', File.join(root, 'include'), *defines, '-c', File.join(root, SOURCE), '-o', object],
       [linker, '-static', '-nostdlib', format('--defsym=header_probe_address=0x%x', address), '-T', File.join(root, SCRIPT),
        '--oformat=binary', object, '-o', output]].map(&:freeze).freeze
    end

    # The program's build record: the program by its SHA-256; its source, linker script,
    # the specifications and generators its accessors come from, and the pin table, each by path
    # relative to root and SHA-256; the macros; and the compiler and linker by version
    # line. Like the card's own record, it names no absolute path.
    def record(root:, runner:, program:, defines:, compiler:, linker:)
      reference = ->(path) { BootPartition.source_reference(root, File.join(root, path)) }
      version = ->(tool) { BootPartition.tool_version(tool, runner: runner) }
      { 'program' => 'header probe', 'artifact' => { 'path' => PROGRAM, 'sha256' => Digest::SHA256.file(program).hexdigest },
        'source' => reference.(SOURCE), 'linker_script' => reference.(SCRIPT),
        'peripherals' => PERIPHERALS.map(&reference), 'system_registers' => reference.(SYSTEM_REGISTERS),
        'generators' => GENERATORS.map(&reference),
        'pin_table' => reference.("hw/pins/#{PIN_TABLE}.txt"), 'defines' => defines,
        'compiler' => version.(compiler), 'linker' => version.(linker) }
    end

    # Builds the program into directory and writes its build record beside it.
    def program(root:, runner:, compiler:, linker:, platform:, directory:, revision:)
      raise Error, 'the header probe needs ERX_CLANG and ERX_LLD' if compiler.empty? || linker.empty?

      Generated.ensure(root: root)
      output = File.join(directory, PROGRAM)
      defines = defines(platform, devices: Hardware.devices(root: root), table: Pins.read(root: root, soc: PIN_TABLE),
                                  revision: revision || 'unknown')
      argvs = build_argvs(compiler: compiler, linker: linker, root: root, object: File.join(directory, 'header-probe.o'),
                          output: output, defines: defines, address: QemuPlan::MACHINES.fetch(PLATFORM).loads.image)
      argvs.zip(%w[compile link]).each { |argv, step| runner.run(argv, name: "header-probe-#{step}", deadline: 120) }
      record = record(root: root, runner: runner, program: output, defines: defines, compiler: compiler, linker: linker)
      File.write(File.join(directory, RECEIPT), JSON.pretty_generate(record) + "\n")
      Program.new(path: output, record: record)
    end

    # Writes the card into DIRECTORY, emptied first: the program and its build record,
    # then the boot partition, the card's image with slot A's image area empty, and the
    # card's build record, which carries the program's (BootPartition.lay_out). The
    # revision is read once, so the probe's banner, the tree's notice and the record name
    # one commit. Returns the BootPartition::Written.
    def pack(root:, runner:, compiler:, linker:, platform:)
      raise Error, "the header probe card is for #{PLATFORM}, not #{platform.name}" unless platform.name == PLATFORM

      cleared = ProductionImage.clear_directory(root: root, path: File.join(root, DIRECTORY))
      directory = OutputDirectory.prepare(root: root, path: cleared)
      revision = SourceRevision.read(root: root, runner: runner)
      built = program(root: root, runner: runner, compiler: compiler, linker: linker, platform: platform,
                      directory: directory, revision: revision)
      BootPartition.lay_out(root: root, runner: runner, platform: platform, build_kind: ProductionImage::BUILD_KIND,
                            bootable: built.path, erofs: nil, directory: directory, compiler: compiler, linker: linker,
                            revision: revision, bootable_record: built.record)
    end
  end
end
