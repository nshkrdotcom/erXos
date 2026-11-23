# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/lib/erx/header_probe'
require_relative '../../tools/lib/erx/platform'
require_relative '../../tools/lib/erx/runner'

# The header probe card's program takes its console from the platform record, its
# register windows from the SVD files and the console's receive pin from the pin table, so
# a record whose console is not the mini UART the probe writes through, or a window or pin
# the defines do not carry, would have it read or write at the wrong addresses.
class HeaderProbeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PI = Erx::Platform.load(root: ROOT, name: 'raspi4b')
  DEVICES = Erx::Hardware.devices(root: ROOT)
  PINS = Erx::Pins.read(root: ROOT, soc: 'bcm2711')
  # What HeaderProbe.console_device reads of a platform.
  RecordOnly = Data.define(:record, :record_path)

  def defines(platform = PI, devices: DEVICES) = Erx::HeaderProbe.defines(platform, devices: devices, table: PINS, revision: 'n1-abc')

  def test_passes_the_record_console_the_svd_windows_and_the_receive_pin
    console = PI.record.fetch('units').flat_map { |unit| unit.fetch('devices') }
                .find { |device| device['path'] == PI.record.fetch('console') }
    window = ->(name) { DEVICES.find { |device| device.name == name }.size }
    assert_equal [format('-DCONSOLE_BASE=0x%xu', console.fetch('base')), format('-DCONSOLE_SIZE=0x%xu', console.fetch('size')),
                  format('-DGPIO_WINDOW=0x%xu', window.('BCM2711_GPIO')), format('-DCM_WINDOW=0x%xu', window.('CPRMAN')),
                  '-DCONSOLE_RX_PIN=15', '-DPROBE_REVISION="n1-abc"'], defines
  end

  def test_refuses_a_console_that_is_not_the_mini_uart
    pl011 = PI.record.fetch('units').flat_map { |unit| unit.fetch('devices') }
              .find { |device| device['compatible'] == 'arm,pl011' }.fetch('path')
    # Platform.new refuses this record before the probe sees it, since the header map then
    # finds the mini UART's pins on a device no driver drives; the probe reads only the
    # record and its path, so it is handed those.
    platform = RecordOnly.new(record: PI.record.merge('console' => pl011), record_path: PI.record_path)
    error = assert_raises(Erx::Error) { defines(platform) }
    assert_match(/not a brcm,bcm2835-aux-uart/, error.message)
  end

  def test_refuses_a_missing_window
    error = assert_raises(Erx::Error) { defines(devices: DEVICES.reject { |device| device.name == 'CPRMAN' }) }
    assert_match(/no SVD device for CM_WINDOW/, error.message)
  end

  # The receive pin is the one header pin carrying RXD1; a table where none or two do is
  # refused, and an on-board pin that carries it too (GPIO 33) is not the console's.
  def test_refuses_a_receive_signal_on_no_pin_or_two
    pin = ->(gpio, functions) { Erx::Pins::Pin.new(gpio: gpio, pull: 'down', functions: functions) }
    [[], [pin.(15, ['RXD1']), pin.(16, ['RXD1'])]].each do |pins|
      assert_raises(Erx::Error) { Erx::HeaderProbe.console_rx_pin(Erx::Pins::Table.new(pins: pins, controllers: [])) }
    end
    onboard = Erx::Pins::Table.new(pins: [pin.(15, ['RXD1']), pin.(33, ['RXD1'])], controllers: [])
    assert_equal 15, Erx::HeaderProbe.console_rx_pin(onboard)
  end

  # The flat binary starts where the firmware loads kernel8.img, and the linker script, whose
  # assertion keeps the entry first, lays it out.
  def test_links_a_flat_binary_at_the_load_address
    compile, link = Erx::HeaderProbe.build_argvs(compiler: 'cc', linker: 'ld', root: ROOT, object: 'p.o', output: 'p.bin',
                                                 defines: ['-DX=1'], address: 0x200000)
    assert_includes compile, '-mstrict-align'
    assert_includes compile, File.join(ROOT, Erx::HeaderProbe::SOURCE)
    assert_includes link, '--defsym=header_probe_address=0x200000'
    assert_includes link, '--oformat=binary'
    assert_equal File.join(ROOT, Erx::HeaderProbe::SCRIPT), link[link.index('-T') + 1]
  end

  # The program's record says how it was built, and is as fit to publish as the card's.
  def test_the_record_names_the_build_without_a_host_path
    Dir.mktmpdir do |work|
      program = File.join(work, Erx::HeaderProbe::PROGRAM).tap { |path| File.binwrite(path, 'probe') }
      runner = Erx::Runner.new(owner_root: work, log_dir: File.join(work, 'logs'))
      record = Erx::HeaderProbe.record(root: ROOT, runner: runner, program: program, defines: defines,
                                       compiler: RbConfig.ruby, linker: RbConfig.ruby)
      Erx::BootPartition.check_record(record)
      assert_equal Digest::SHA256.hexdigest('probe'), record.fetch('artifact').fetch('sha256')
      assert_equal [Erx::HeaderProbe::SOURCE, Erx::HeaderProbe::SCRIPT],
                   [record.fetch('source').fetch('path'), record.fetch('linker_script').fetch('path')]
      assert_includes record.fetch('peripherals').map { |entry| entry.fetch('path') }, 'hw/svd/cprman/cprman.svd'
      assert_equal defines, record.fetch('defines')
      assert_match(/\Aruby #{Regexp.escape(RUBY_VERSION)}/, record.fetch('compiler'))
    end
  end

  def test_packs_only_the_raspberry_pi_4
    virt = Erx::Platform.load(root: ROOT, name: 'qemu-virt')
    assert_raises(Erx::Error) do
      Erx::HeaderProbe.pack(root: ROOT, runner: nil, compiler: 'cc', linker: 'ld', platform: virt)
    end
  end
end
