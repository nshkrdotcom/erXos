# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../../tools/lib/erx/platform'

# The platform record's pin table (Erx::PinTable, docs/design-pinctrl.md, "The pin table"
# and "What the build refuses"): the Raspberry Pi 4's table is accepted and gives its
# derived facts, and for each refusal of the reader one table that breaks only that rule
# is refused with it.
class PinTableTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PI = Erx::Platform.load(root: ROOT, name: 'raspi4b')
  I2C = '/soc/i2c@7e804000'
  SPI = '/soc/spi@7e204000'
  BSC0 = '/soc/i2c@7e205000'
  UART2 = '/soc/serial@7e201400'
  UART0 = '/soc/serial@7e201000'
  CONSOLE = PI.record.fetch('console')
  HOSTLINK = PI.record.fetch('hostlink')

  def test_the_pi_table_is_accepted_with_its_derived_facts
    table = PI.pins
    entry = table.controllers.first
    assert_equal ['gpio', 'bcm2711', ['/soc/gpio@7e200000']], [entry.name, entry.kind, entry.devices]
    # PINS: GPIO 6, 12, 13 and 16 to 21.
    assert_equal [6, 12, 13, *16..21].sum { |gpio| 1 << gpio }, entry.gpio_mask
    assert_equal 500_000_000, table.core_clock
    assert_equal %w[enable_uart enable_jtag_gpio], table.settings.map(&:name)
    assert_equal({ 2 => [I2C, 0, :none], 3 => [I2C, 0, :none], 4 => [HOSTLINK, 4, :none], 5 => [HOSTLINK, 4, :up],
                   7 => [SPI, 0, :none], 8 => [SPI, 0, :none], 9 => [SPI, 0, :none], 10 => [SPI, 0, :none],
                   11 => [SPI, 0, :none] },
                 entry.header_device_rows.to_h { |row| [row.gpio, [row.use, row.setting.alternate, row.setting.pull]] })
    # The console's rows and JTAG's are the firmware's.
    assert_equal [14, 15, *22..27], entry.rows.select { |row| row.owner == :firmware }.map(&:gpio)
    # UART0's pins to the Bluetooth controller, CTS0, RTS0, TXD0 and RXD0 in ALT3, with no pull.
    assert_equal({ 30 => [UART0, 'CTS0', 3, nil], 31 => [UART0, 'RTS0', 3, nil], 32 => [UART0, 'TXD0', 3, nil],
                   33 => [UART0, 'RXD0', 3, nil] },
                 entry.rows.select { |row| row.gpio >= 28 }
                      .to_h { |row| [row.gpio, [row.use, row.setting.function, row.setting.alternate, row.setting.pull]] })
    assert_equal ['default'], entry.states_of(UART0)
  end

  def test_a_board_without_a_header_has_no_table
    assert_nil Erx::Platform.development(ROOT).pins
  end

  # A state overlays the plain setting: SPI0's chip select driven low in one state, and its
  # clock pulled down in another.
  def test_states_are_the_plain_setting_overlaid
    entry = with_entry do |given|
      given['rows'][8] = { 'gpio' => 8, 'use' => SPI, 'function' => 'out', 'level' => 1,
                           'states' => { 'select' => { 'level' => 0 } } }
      given['rows'][11] = given['rows'][11].merge('states' => { 'idle' => { 'pull' => 'down' } })
    end.controllers.first
    assert_equal %w[default idle select], entry.states_of(SPI)
    chip, clock = entry.rows.values_at(8, 11)
    assert_equal [1, 0, 1], [chip.setting.level, chip.setting_in('select').level, chip.setting_in('idle').level]
    assert_equal %i[none down none], [clock.setting.pull, clock.setting_in('idle').pull, clock.setting_in('select').pull]
  end

  # Each case changes the Pi's one controller entry in one way and names the diagnostic it
  # must give.
  REFUSALS = {
    'a missing pin' => [->(entry) { entry['rows'].pop }, /rows must be a list of 28/],
    'rows out of order' => [->(entry) { entry['rows'][6], entry['rows'][12] = entry['rows'][12], entry['rows'][6] },
                            /row 6 must be an object for GPIO 6/],
    'a row key of no meaning' => [->(entry) { entry['rows'][2]['drive'] = 2 }, /GPIO 2: a row is an object of/],
    'an entry key of no meaning' => [->(entry) { entry['extra'] = 1 }, /entry 0 must be an object of controller, name/],
    'a controller name that is no identifier' => [->(entry) { entry['name'] = 'GPIO' }, /entry 0: name "GPIO" is not an identifier/],
    'a pin controller that is no device of the record' => [->(entry) { entry['controller'] = ['/soc/gpio@7e200001'] },
                                                           /gpio: controller must be a list of distinct device paths/],
    'a function not the pin\'s' => [->(entry) { entry['rows'][2]['function'] = 'TXD3' }, /GPIO 2 does not carry TXD3/],
    # The console's rows on GPIO 32 and 33, with GPIO 14 and 15 left to plain GPIO.
    'the console on UART0\'s pins' => [lambda { |entry|
                                         entry['rows'][14] = { 'gpio' => 14, 'use' => 'gpio' }
                                         entry['rows'][15] = { 'gpio' => 15, 'use' => 'gpio' }
                                         entry['onboard'][2] = { 'gpio' => 32, 'use' => CONSOLE, 'function' => 'TXD0' }
                                       }, /GPIO 32: a #{CONSOLE} row is no pin of a firmware setting of bcm2711/],
    'a gpio row on the console\'s pin' => [->(entry) { entry['rows'][14] = { 'gpio' => 14, 'use' => 'gpio' } },
                                           /enable_uart sets GPIO 14, 15, and only some of them are rows/],
    'enable_jtag_gpio\'s pins with five rows' => [->(entry) { entry['rows'][27] = { 'gpio' => 27, 'use' => 'reserved' } },
                                                  /enable_jtag_gpio sets GPIO 22, 23, 24, 25, 26, 27, and only some/],
    'a firmware row of another signal' => [->(entry) { entry['rows'][14]['function'] = 'TXD0' },
                                           /GPIO 14: enable_uart puts TXD1 there, not TXD0/],
    'a firmware row with a pull' => [->(entry) { entry['rows'][14]['pull'] = 'none' },
                                     /GPIO 14: a firmware row \(#{CONSOLE}\) has a function alone/],
    'a gpio row with a function' => [->(entry) { entry['rows'][6]['function'] = 'GPCLK2' }, /GPIO 6: a gpio row has no setting or states/],
    'a gpio row with a pull' => [->(entry) { entry['rows'][6]['pull'] = 'up' }, /GPIO 6: a gpio row has no setting or states/],
    'a gpio row with a state' => [->(entry) { entry['rows'][6]['states'] = { 'on' => { 'level' => 1 } } },
                                  /GPIO 6: a gpio row has no setting/],
    'a reserved row with a function' => [->(entry) { entry['rows'][0]['function'] = 'SDA0' }, /GPIO 0: a reserved row/],
    'a pull of no meaning' => [->(entry) { entry['rows'][2]['pull'] = 'weak' }, /GPIO 2: pull "weak" is not none, up or down/],
    'a level without out' => [->(entry) { entry['rows'][2]['level'] = 1 }, /GPIO 2: out takes a level of 0 or 1, and nothing else/],
    'out without a level' => [->(entry) { entry['rows'][8] = { 'gpio' => 8, 'use' => SPI, 'function' => 'out' } },
                              /GPIO 8: out takes a level/],
    'a state that names a pull its plain setting lacks' => [->(entry) { entry['onboard'][0]['states'] = { 'quiet' => { 'pull' => 'up' } } },
                                                            /GPIO 30: state quiet names a pull, and the row's plain setting names none/],
    'a state name that is no identifier' => [->(entry) { entry['rows'][2]['states'] = { 'Off' => { 'pull' => 'up' } } },
                                             /GPIO 2: state "Off" is not an identifier other than default/],
    'a state named default' => [->(entry) { entry['rows'][2]['states'] = { 'default' => { 'pull' => 'up' } } },
                                /state "default" is not an identifier other than default/],
    'a state of no setting' => [->(entry) { entry['rows'][2]['states'] = { 'off' => {} } }, /GPIO 2: state off must be an object of/],
    'two states with the same settings' => [->(entry) { entry['rows'][2]['states'] = { 'held' => { 'pull' => 'up' }, 'kept' => { 'pull' => 'up' } } },
                                            /#{I2C}: states held and kept have the same settings/],
    'a state with the default\'s settings' => [->(entry) { entry['rows'][2]['states'] = { 'same' => { 'pull' => 'none' } } },
                                               /#{I2C}: states default and same have the same settings/],
    # A state that moves an output to a signal keeps the output's level, so its fields differ.
    'a state that leaves out with its level' => [lambda { |entry|
                                                   entry['rows'][8] = { 'gpio' => 8, 'use' => SPI, 'function' => 'out', 'level' => 1,
                                                                        'states' => { 'bus' => { 'function' => 'SPI0_CE0_N' } } }
                                                 }, /GPIO 8: out takes a level/],
    'SDA1 on an SPI0 row' => [->(entry) { entry['rows'][2]['use'] = SPI }, /GPIO 2: SDA1 is not a signal of #{SPI}, spi0/],
    'SPI0 without SCLK' => [->(entry) { entry['rows'][11] = { 'gpio' => 11, 'use' => 'gpio' } }, /#{SPI} has no row for SPI0_SCLK/],
    'a use that is no device of the record' => [->(entry) { entry['rows'][6]['use'] = '/soc/pwm@7e20c000' },
                                                /GPIO 6: use "\/soc\/pwm@7e20c000" is neither/],
    # EMMC2, since it is driven (a block kind) and so reaches the controller rule.
    'a driven device at no controller of the pin table' => [->(entry) { entry['rows'][2]['use'] = '/emmc2bus/mmc@7e340000' },
                                                            /no controller of the pin table/],
    'a UART no driver drives' => [lambda { |entry|
                                    entry['rows'][0] = { 'gpio' => 0, 'use' => UART2, 'function' => 'TXD2', 'pull' => 'none' }
                                    entry['rows'][1] = { 'gpio' => 1, 'use' => UART2, 'function' => 'RXD2', 'pull' => 'none' }
                                  }, /GPIO 0: "#{UART2}" is a device no driver drives/],
    'a device of no kind' => [lambda { |entry|
                                entry['rows'][0] = { 'gpio' => 0, 'use' => BSC0, 'function' => 'SDA0', 'pull' => 'none' }
                                entry['rows'][1] = { 'gpio' => 1, 'use' => BSC0, 'function' => 'SCL0', 'pull' => 'none' }
                              }, /GPIO 0: "#{BSC0}" is a device no driver drives/],
    'a driven bus that no row names' => [lambda { |entry|
                                           entry['rows'][2] = { 'gpio' => 2, 'use' => 'gpio' }
                                           entry['rows'][3] = { 'gpio' => 3, 'use' => 'gpio' }
                                         }, /the record's driven device "#{I2C}" has no pins/],
    'the host link without rows' => [lambda { |entry|
                                       entry['rows'][4] = { 'gpio' => 4, 'use' => 'gpio' }
                                       entry['rows'][5] = { 'gpio' => 5, 'use' => 'gpio' }
                                     }, /the record's driven device "#{HOSTLINK}" has no pins/],
    'an unknown pin table' => [->(entry) { entry['soc'] = 'bcm2712' }, /bcm2712/],
    'on-board rows that are no list' => [->(entry) { entry['onboard'] = {} }, /onboard must be a list/],
    # GPIO 16 carries CTS0 in ALT3 too, so only the header-pin rule breaks.
    'an on-board row on a header pin' => [->(entry) { entry['onboard'][0]['gpio'] = 16 },
                                          /on-board GPIO 16 is not an on-board pin of the pin table/],
    'an on-board pin the table lacks' => [->(entry) { entry['onboard'] << { 'gpio' => 34, 'use' => UART0, 'function' => 'TXD0' } },
                                          /on-board GPIO 34 is not an on-board pin/],
    'on-board rows out of order' => [->(entry) { entry['onboard'][0], entry['onboard'][1] = entry['onboard'][1], entry['onboard'][0] },
                                     /on-board rows must be in increasing GPIO order, each GPIO once/],
    'an on-board function not the pin\'s' => [->(entry) { entry['onboard'][2]['function'] = 'RXD0' }, /GPIO 32 does not carry RXD0/],
    'an on-board device that is no device of the record' => [->(entry) { entry['onboard'][0]['use'] = '/soc/serial@7e201001' },
                                                             %r{GPIO 30: use "/soc/serial@7e201001" is neither}],
    # GPIO 30 carries UART1's CTS1 in ALT5.
    'an on-board signal of another controller' => [->(entry) { entry['onboard'][0]['function'] = 'CTS1' },
                                                   /GPIO 30: CTS1 is not a signal of #{UART0}, uart0/],
    'UART0 without TXD0' => [->(entry) { entry['onboard'].delete_at(2) }, /#{UART0} has no row for TXD0/]
  }.freeze

  def test_each_refusal_breaks_only_its_rule
    REFUSALS.each do |name, (change, message)|
      error = assert_raises(Erx::Error, name) { with_entry(&change) }
      assert_match(/\Aconfig\/platforms\/raspi4b\.json: pins: /, error.message, name)
      assert_match message, error.message, name
    end
  end

  # Nine states of SPI0, default among them, each a different level of its chip select and
  # pulls of two other pins.
  def test_more_states_than_pin_states_max_are_refused
    combinations = [0, 1].product(%w[none up down], %w[none up down]) - [[1, 'none', 'none']]
    error = assert_raises(Erx::Error) do
      with_entry do |entry|
        entry['rows'][8] = { 'gpio' => 8, 'use' => SPI, 'function' => 'out', 'level' => 1, 'states' => {} }
        combinations.take(8).each_with_index do |(level, seven, nine), index|
          entry['rows'][8]['states']["s#{index}"] = { 'level' => level }
          (entry['rows'][7]['states'] ||= {})["s#{index}"] = { 'pull' => seven }
          (entry['rows'][9]['states'] ||= {})["s#{index}"] = { 'pull' => nine }
        end
      end
    end
    assert_match(/#{SPI} has 9 states, more than 8/, error.message)
  end

  # A device whose states are not default alone has its rows on one controller entry; the
  # second entry is the first's twin under another name, reserved but for UART0's rows.
  def test_a_device_with_states_on_two_controllers_is_refused
    record = JSON.parse(JSON.generate(PI.record))
    first = record.fetch('pins').first
    first['onboard'][0]['states'] = { 'quiet' => { 'function' => 'in' } }
    second = JSON.parse(JSON.generate(first)).merge('name' => 'gpio_twin')
    second['rows'] = second['rows'].map { |row| { 'gpio' => row.fetch('gpio'), 'use' => 'reserved' } }
    record['pins'] << second
    error = assert_raises(Erx::Error) { Erx::Platform.new(name: 'raspi4b', record: record) }
    assert_match(/#{UART0} has states other than default on two pin controllers/, error.message)
  end

  # The console's rows come from one setting of the boot description's table, written on
  # every kind of card: a table whose settings split the console's pins between two, or
  # write the console's setting on a development card alone, is refused. The Pi's own
  # table has neither, so each is read against a settings table of its own.
  def test_console_rows_from_two_settings_are_refused
    split = settings_with(Erx::BootPartition::Setting.new(name: 'uart_tx', signals: { 14 => 'TXD1' }, kinds: Erx::BuildKind::ALL),
                          Erx::BootPartition::Setting.new(name: 'uart_rx', signals: { 15 => 'RXD1' }, kinds: Erx::BuildKind::ALL))
    error = assert_raises(Erx::Error) { Erx::PinTable.read(PI.record, settings: split) }
    assert_match(/the console's rows come from 2 firmware settings, not one/, error.message)
  end

  def test_a_console_setting_not_written_on_every_card_is_refused
    development = settings_with(Erx::BootPartition::Setting.new(name: 'enable_uart', signals: { 14 => 'TXD1', 15 => 'RXD1' },
                                                                kinds: [Erx::BuildKind::DEVELOPMENT]))
    error = assert_raises(Erx::Error) { Erx::PinTable.read(PI.record, settings: development) }
    assert_match(/enable_uart is not written on every kind of card/, error.message)
  end

  # A chip has one pin table, so a second entry of its kind could only name its pins
  # again: a twin under another name whose rows are all gpio would serve the console's and
  # JTAG's pins, since every other check reads one entry at a time.
  def test_two_entries_of_one_kind_are_refused
    record = JSON.parse(JSON.generate(PI.record))
    first = record.fetch('pins').first
    record['pins'] << first.merge('name' => 'gpio_twin', 'onboard' => [],
                                  'rows' => first['rows'].map { |row| { 'gpio' => row.fetch('gpio'), 'use' => 'gpio' } })
    error = assert_raises(Erx::Error) { Erx::Platform.new(name: 'raspi4b', record: record) }
    assert_match(/two pin controller entries are of kind bcm2711/, error.message)
  end

  def test_two_entries_with_one_name_are_refused
    record = JSON.parse(JSON.generate(PI.record))
    record['pins'] << record['pins'].first.merge('rows' => record['pins'].first['rows'].map { |row| { 'gpio' => row.fetch('gpio'), 'use' => 'reserved' } },
                                                 'onboard' => [])
    error = assert_raises(Erx::Error) { Erx::Platform.new(name: 'raspi4b', record: record) }
    assert_match(/two pin controller entries have one name/, error.message)
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

  # SDA3 is the function of GPIO 2 and of GPIO 4, so a table can name it twice for BSC3, and
  # the reader must refuse that, in default and in a state that moves GPIO 4 to it. BSC3 is
  # driven in BSC1's place here, so no other rule breaks.
  def test_one_signal_on_two_rows_is_refused
    record = JSON.parse(JSON.generate(PI.record))
    bsc3 = '/soc/i2c@7e205600'
    devices = record.fetch('units').flat_map { |unit| unit.fetch('devices') }
    devices.find { |device| device['path'] == I2C }.merge!('role' => 'ordinary')
    devices.find { |device| device['path'] == bsc3 }.merge!('role' => 'i2c', 'clock' => 500_000_000)
    rows = record.fetch('pins').first.fetch('rows')
    rows[2] = { 'gpio' => 2, 'use' => bsc3, 'function' => 'SDA3', 'pull' => 'none' }
    rows[3] = { 'gpio' => 3, 'use' => bsc3, 'function' => 'SCL3', 'pull' => 'none' }
    [[{ 'function' => 'SDA3' }, /#{bsc3} names a signal on two rows in state default/],
     [{ 'function' => 'in', 'states' => { 'moved' => { 'function' => 'SDA3' } } }, /#{bsc3} names a signal on two rows in state moved/]]
      .each do |setting, message|
        rows[4] = { 'gpio' => 4, 'use' => bsc3, 'pull' => 'none' }.merge(setting)
        error = assert_raises(Erx::Error) { Erx::Platform.new(name: 'raspi4b', record: record) }
        assert_match message, error.message
      end
  end

  # A row whose use is gpio is plain GPIO, even where a record device has that path, so a
  # function cannot pass on it: MII_A_CRS is GPIO 30's ALT4, a function no controller owns.
  def test_an_onboard_row_named_like_a_plain_use_is_plain
    error = assert_raises(Erx::Error) do
      with_entry { |entry| entry['onboard'] = [{ 'gpio' => 30, 'use' => 'gpio', 'function' => 'MII_A_CRS' }] }
    end
    assert_match(/GPIO 30: a gpio row has no setting or states/, error.message)
  end

  def test_pins_of_another_shape_are_refused
    [[], { 'soc' => 'bcm2711' }].each do |pins|
      error = assert_raises(Erx::Error) { Erx::Platform.new(name: 'raspi4b', record: PI.record.merge('pins' => pins)) }
      assert_match(/pins: must be a list of pin controller entries/, error.message)
    end
  end

  private

  # The boot description's settings with the BCM2711's enable_uart replaced by replacements.
  def settings_with(*replacements)
    given = Erx::BootPartition::FIRMWARE_SETTINGS
    given.merge('bcm2711' => given.fetch('bcm2711').reject { |setting| setting.name == 'enable_uart' } + replacements)
  end

  # The Pi's table with its one entry changed by the block, read as a record.
  def with_entry
    record = JSON.parse(JSON.generate(PI.record))
    yield record.fetch('pins').first
    Erx::Platform.new(name: 'raspi4b', record: record).pins
  end
end
