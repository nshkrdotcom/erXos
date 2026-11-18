# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/pins'

class PinsTest < Minitest::Test
  REPOSITORY = File.expand_path('../..', __dir__)

  def setup
    @source = File.binread(File.join(REPOSITORY, 'hw/pins/bcm2711.txt'))
    @table = Erx::Pins.read(root: REPOSITORY, soc: 'bcm2711')
  end

  # The Raspberry Pi 4's header map (docs/design-header-io.md, "The construction: one
  # map of the header") asks for these functions; their alternates are Table 94's
  # columns.
  def test_the_header_maps_functions_are_where_table_94_puts_them
    expected = { [2, 'SDA1'] => 0, [3, 'SCL1'] => 0, [4, 'TXD3'] => 4, [5, 'RXD3'] => 4, [7, 'SPI0_CE1_N'] => 0,
                 [11, 'SPI0_SCLK'] => 0, [14, 'TXD1'] => 5, [15, 'RXD1'] => 5, [22, 'ARM_TRST'] => 4,
                 [27, 'ARM_TMS'] => 4 }
    expected.each do |(gpio, function), alternate|
      assert_equal alternate, @table.alternate(gpio: gpio, function: function), "GPIO #{gpio} #{function}"
    end
    assert_equal (0..27).to_a, @table.pins.map(&:gpio)
    assert_equal %i[up] * 9 + %i[down] * 19, @table.pins.map(&:pull)
    assert_nil @table.pins.fetch(16).functions.first
  end

  def test_a_device_base_names_its_controller_and_signals
    bsc1 = @table.fetch_controller(base: 0x7e804000)
    assert_equal ['bsc1', %w[SDA1 SCL1], []], [bsc1.name, bsc1.required, bsc1.optional]
    spi0 = @table.fetch_controller(base: 0x7e204000)
    assert_equal [%w[SPI0_SCLK SPI0_MOSI SPI0_MISO], %w[SPI0_CE0_N SPI0_CE1_N]], [spi0.required, spi0.optional]
    assert_equal 'uart1', @table.fetch_controller(base: 0x7e215040).name
    assert_nil @table.fetch_named('jtag').base
    assert_includes @table.fetch_named('jtag').signals, 'ARM_TMS'
  end

  # PWM0 has no controller row, so no base gives a pin its PWM0_0; reserved slots are no function.
  def test_an_absent_pin_function_or_controller_is_refused
    refusals = [-> { @table.alternate(gpio: 2, function: 'SDA0') }, -> { @table.alternate(gpio: 28, function: 'SDA0') },
                -> { @table.alternate(gpio: -1, function: 'SPI6_CE1_N') }, -> { @table.alternate(gpio: 2.0, function: 'SDA1') },
                -> { @table.alternate(gpio: 16, function: nil) }, -> { @table.alternate(gpio: 26, function: '-') },
                -> { @table.fetch_controller(base: 0x7e20c000) }, -> { @table.fetch_controller(base: nil) },
                -> { @table.fetch_named('pwm0') }, -> { Erx::Pins.read(root: REPOSITORY, soc: '../pins/bcm2711') }]
    refusals.each { |refusal| assert_raises(Erx::Error) { refusal.call } }
  end

  # Seeded faults, one rule each, as [the text replaced, its replacement, the refusal]:
  # every edit leaves a table the reader must refuse, by the rule the edit breaks.
  SEEDED_FAULTS = {
    'a pin out of order' => ['pin 1 up SCL0', 'pin 9 up SCL0', /in order/],
    'a missing pin' => ["pin 27 down SD0_DAT3 - DPI_D23 SD1_DAT3 ARM_TMS SPI6_CE1_N\n", '', /in order/],
    'a GPIO number with a leading zero' => ['pin 1 up SCL0', 'pin 01 up SCL0', /invalid GPIO number/],
    'an uppercase controller name' => ['controller bsc0 ', 'controller BSC0 ', /invalid controller name/],
    'a table past its byte bound' => ["\npin 0 ", "\n#{'#' * (64 * 1024)}\npin 0 ", /bounded ASCII/],
    'an unknown pull' =>['pin 0 up SDA0', 'pin 0 high SDA0', /invalid pull/],
    'a short pin row' => [' TXD2 SDA6', ' TXD2', /pin row needs/],
    'a function twice on one pin' => ['pin 0 up SDA0 SA5', 'pin 0 up SDA0 SDA0', /twice/],
    'a lowercase function' => ['DPI_D23', 'dpi_d23', /invalid function name: dpi_d23/],
    'an unknown row kind' => ['controller bsc0 ', 'device bsc0 ', /pin rows, then controller rows/],
    'a controller before a pin' => ['pin 27 ', "controller bsc0 0x7e205000 SDA0 SCL0\npin 27 ",
                                    /pin rows, then controller rows/],
    'controllers out of order' => ['controller bsc6 ', 'controller bsc2 ', /sorted by name/],
    'a short base address' => ['0x7e804000', '0x7e80400', /invalid base address/],
    'two controllers at one base' => ['bsc1 0x7e804000', 'bsc1 0x7e205000', /share a base/],
    'a signal of two controllers' => ['SDA6 SCL6', 'SDA6 SCL5', /two controllers/],
    'a signal no pin carries' => ['SPI0_CE0_N SPI0_CE1_N', 'SPI0_CE0_N SPI0_CE2_N', /no pin's function: SPI0_CE2_N/],
    'no required signal' => ['jtag none ARM_TCK ARM_TMS ARM_TDI ARM_TDO optional', 'jtag none optional',
                             /needs required signals/],
    'an empty optional list' => ['TXD5 RXD5 optional CTS5 RTS5', 'TXD5 RXD5 optional', /signals after optional/],
    'a second optional' => ['optional CTS5 RTS5', 'optional CTS5 optional RTS5', /invalid function name: optional/],
    'a byte outside ASCII' => ['# Copyright', "# #{[0xa9].pack('U')} Copyright", /bounded ASCII/]
  }.freeze

  def test_each_rule_refuses_its_seeded_fault
    SEEDED_FAULTS.each do |rule, (from, to, refusal)|
      seeded = @source.sub(from, to)
      refute_equal @source, seeded, rule
      error = assert_raises(Erx::Error, rule) { Erx::Pins.parse(seeded) }
      assert_match refusal, error.message, rule
    end
  end
end
