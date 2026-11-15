# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../../tools/lib/erx/platform'

# The platform record's header map (Erx::HeaderMap, docs/design-header-io.md, "The
# construction"): the Raspberry Pi 4's map is accepted and gives its derived facts, and
# for each refusal of the reader one map that breaks only that rule is refused with it.
class HeaderMapTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PI = Erx::Platform.load(root: ROOT, name: 'raspi4b')
  I2C = '/soc/i2c@7e804000'
  SPI = '/soc/spi@7e204000'
  BSC0 = '/soc/i2c@7e205000'
  UART2 = '/soc/serial@7e201400'

  def test_the_pi_map_is_accepted_with_its_derived_facts
    header = PI.header
    assert_equal '/soc/gpio@7e200000', header.controller
    # PINS: GPIO 6, 12, 13 and 16 to 21.
    assert_equal [6, 12, 13, *16..21].sum { |gpio| 1 << gpio }, header.gpio_mask
    assert_equal 500_000_000, header.core_clock
    assert header.jtag?
    assert_equal({ 2 => [I2C, 0, :none], 3 => [I2C, 0, :none], 4 => [PI.record.fetch('hostlink'), 4, :none],
                   5 => [PI.record.fetch('hostlink'), 4, :up], 7 => [SPI, 0, :none], 8 => [SPI, 0, :none],
                   9 => [SPI, 0, :none], 10 => [SPI, 0, :none], 11 => [SPI, 0, :none],
                   14 => [PI.record.fetch('console'), 5, :none], 15 => [PI.record.fetch('console'), 5, :none] },
                 header.device_rows.to_h { |row| [row.gpio, [row.use, row.alternate, row.pull]] })
  end

  def test_a_board_without_a_header_has_no_map
    assert_nil Erx::Platform.development(ROOT).header
  end

  # Each case changes the Pi's map in one way and names the diagnostic it must give.
  REFUSALS = {
    'a missing pin' => [->(map) { map['rows'].pop }, /rows must be a list of 28/],
    'rows out of order' => [->(map) { map['rows'][6], map['rows'][12] = map['rows'][12], map['rows'][6] },
                            /row 6 must be an object for GPIO 6/],
    'a row key of no meaning' => [->(map) { map['rows'][6]['level'] = 1 }, /row 6 must be an object/],
    'a pin controller that is no device of the record' => [->(map) { map['controller'] = '/soc/gpio@7e200001' },
                                                           /pin controller "\/soc\/gpio@7e200001" is not a device path/],
    'a function not the pin\'s' => [->(map) { map['rows'][2]['function'] = 'TXD3' }, /GPIO 2 does not carry TXD3/],
    'the console on GPIO 13' => [lambda { |map|
                                   map['rows'][13] = map['rows'][14].merge('gpio' => 13)
                                   map['rows'][14] = { 'gpio' => 14, 'use' => 'gpio' }
                                 }, /GPIO 13 does not carry TXD1/],
    'SDA1 on an SPI0 row' => [->(map) { map['rows'][2]['use'] = SPI }, /GPIO 2: SDA1 is not a signal of #{SPI}, spi0/],
    'SPI0 without SCLK' => [->(map) { map['rows'][11] = { 'gpio' => 11, 'use' => 'gpio' } }, /#{SPI} has no row for SPI0_SCLK/],
    'a gpio row with a function' => [->(map) { map['rows'][6]['function'] = 'GPCLK2' }, /GPIO 6: a gpio row has no function or pull/],
    'a gpio row with a pull' => [->(map) { map['rows'][6]['pull'] = 'up' }, /GPIO 6: a gpio row has no function or pull/],
    'a reserved row with a function' => [->(map) { map['rows'][0]['function'] = 'SDA0' }, /GPIO 0: a reserved row/],
    'a device row without a pull' => [->(map) { map['rows'][2].delete('pull') }, /GPIO 2: a device row's pull/],
    'a use that is no device of the record' => [->(map) { map['rows'][6]['use'] = '/soc/pwm@7e20c000' },
                                                /GPIO 6: use "\/soc\/pwm@7e20c000" is neither/],
    # EMMC2, since it is driven (a block kind) and so reaches the controller rule.
    'a driven device at no controller of the pin table' => [->(map) { map['rows'][2]['use'] = '/emmc2bus/mmc@7e340000' },
                                                            /no controller of the pin table/],
    'a UART no driver drives' => [lambda { |map|
                                    map['rows'][0] = { 'gpio' => 0, 'use' => UART2, 'function' => 'TXD2', 'pull' => 'none' }
                                    map['rows'][1] = { 'gpio' => 1, 'use' => UART2, 'function' => 'RXD2', 'pull' => 'none' }
                                  }, /GPIO 0: "#{UART2}" is a device no driver drives/],
    'a device of no kind' => [lambda { |map|
                                map['rows'][0] = { 'gpio' => 0, 'use' => BSC0, 'function' => 'SDA0', 'pull' => 'none' }
                                map['rows'][1] = { 'gpio' => 1, 'use' => BSC0, 'function' => 'SCL0', 'pull' => 'none' }
                              }, /GPIO 0: "#{BSC0}" is a device no driver drives/],
    'a driven bus that no row names' => [lambda { |map|
                                           map['rows'][2] = { 'gpio' => 2, 'use' => 'gpio' }
                                           map['rows'][3] = { 'gpio' => 3, 'use' => 'gpio' }
                                         }, /the record's driven device "#{I2C}" has no pins/],
    'a jtag row with a pull' => [->(map) { map['rows'][22]['pull'] = 'none' }, /GPIO 22: a jtag row has a function and no pull/],
    'JTAG on part of its pins' => [->(map) { map['rows'][23] = { 'gpio' => 23, 'use' => 'gpio' } }, /jtag has no row for ARM_RTCK/],
    'the host link without its pins' => [lambda { |map|
                                           map['rows'][4] = { 'gpio' => 4, 'use' => 'gpio' }
                                           map['rows'][5] = { 'gpio' => 5, 'use' => 'gpio' }
                                         }, /the record's driven device "\/soc\/serial@7e201600" has no pins/],
    'an unknown pin table' => [->(map) { map['pins'] = 'bcm2712' }, /bcm2712/]
  }.freeze

  def test_each_refusal_breaks_only_its_rule
    REFUSALS.each do |name, (change, message)|
      record = JSON.parse(JSON.generate(PI.record))
      change.call(record.fetch('header'))
      error = assert_raises(Erx::Error, name) { Erx::Platform.new(name: 'raspi4b', record: record) }
      assert_match(/\Aconfig\/platforms\/raspi4b\.json: header: /, error.message, name)
      assert_match message, error.message, name
    end
  end

  # The I2C and SPI controllers divide one core clock; rows that disagree, or a controller
  # without its clock, are refused.
  def test_the_bus_devices_share_one_core_clock
    [->(device) { device['clock'] = 250_000_000 }, ->(device) { device.delete('clock') }].each do |change|
      record = JSON.parse(JSON.generate(PI.record))
      change.call(record.fetch('units').flat_map { |unit| unit.fetch('devices') }.find { |device| device['path'] == SPI })
      error = assert_raises(Erx::Error) { Erx::Platform.new(name: 'raspi4b', record: record) }
      assert_match(/need one core clock/, error.message)
    end
  end

  # SDA3 is the function of GPIO 2 and of GPIO 4, so a map can name it twice for BSC3, and
  # the reader must refuse that. BSC3 is driven in BSC1's place here, so no other rule breaks.
  def test_one_signal_on_two_rows_is_refused
    record = JSON.parse(JSON.generate(PI.record))
    bsc3 = '/soc/i2c@7e205600'
    devices = record.fetch('units').flat_map { |unit| unit.fetch('devices') }
    devices.find { |device| device['path'] == I2C }.merge!('role' => 'ordinary')
    devices.find { |device| device['path'] == bsc3 }.merge!('role' => 'i2c', 'clock' => 500_000_000)
    rows = record.fetch('header').fetch('rows')
    rows[2] = { 'gpio' => 2, 'use' => bsc3, 'function' => 'SDA3', 'pull' => 'none' }
    rows[3] = { 'gpio' => 3, 'use' => bsc3, 'function' => 'SCL3', 'pull' => 'none' }
    rows[4] = { 'gpio' => 4, 'use' => bsc3, 'function' => 'SDA3', 'pull' => 'none' }
    error = assert_raises(Erx::Error) { Erx::Platform.new(name: 'raspi4b', record: record) }
    assert_match(/#{bsc3} names a signal on two rows/, error.message)
  end

  def test_a_header_of_another_shape_is_refused
    [[], { 'pins' => 'bcm2711' }, PI.record.fetch('header').merge('extra' => 1)].each do |header|
      error = assert_raises(Erx::Error) { Erx::Platform.new(name: 'raspi4b', record: PI.record.merge('header' => header)) }
      assert_match(/header must be an object/, error.message)
    end
  end
end
