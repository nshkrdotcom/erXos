# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'boot_partition_settings'
require_relative 'device_kinds'
require_relative 'error'
require_relative 'generated_abi'
require_relative 'pins'

module Erx
  # A platform record's pin table, its "pins" list (docs/design-pinctrl.md, "The pin table"
  # and "What the build refuses"): one entry for each of the board's pin controllers, each
  # an object of
  # * name, an identifier unique in the record, by which /proc and the log name it;
  # * soc, its kind, the SoC pin table it is checked against (hw/pins/<soc>.txt);
  # * controller, the device paths whose registers set its pins;
  # * rows, one for each header pin, GPIO 0 to 27, in order, and onboard, one for each
  #   on-board pin a chip on the board needs set, in increasing order: one row form in both.
  # A row is a gpio number and a use, its owner: "gpio" (plain GPIO), "reserved" (nothing
  # touches the pin), "jtag" or the record's console (a firmware row: a pin the firmware
  # sets and erXos never writes) or a device path of the record. A device row has a setting,
  # a function (a signal of the pin, "in", or "out" with a level of 0 or 1) and optionally a
  # pull (none, up or down), and may give further settings under state names in "states",
  # each overlaid on the plain setting, which is the device's "default" state. A firmware
  # row has its function alone, the signal the boot description's setting puts there
  # (BootPartition::FIRMWARE_SETTINGS).
  # The reader refuses a table that breaks a rule, whole, at its first broken rule, naming
  # the row; nothing else in the build states a pin.
  module PinTable
    # A pin's setting in one state: function, a signal name of the pin's, "in" or "out";
    # alternate, the signal's alternate number in the SoC table, nil for in and out; pull,
    # nil when the row names none (its pull is never written), else :none, :up or :down;
    # level, 0 or 1 for out and nil otherwise.
    Setting = Data.define(:function, :alternate, :pull, :level)

    # One pin. owner is :device, :firmware, :gpio or :reserved; setting is the default
    # state's, nil on a gpio or reserved row; states gives the setting in each other state
    # the row names, whole. A device row's setting in a state of its device that the row
    # does not name is its default.
    Row = Data.define(:gpio, :use, :owner, :setting, :states) do
      def device? = owner == :device
      def setting_in(state) = states.fetch(state, setting)
    end

    # One controller entry. rows are its header and on-board rows, in pin order.
    Entry = Data.define(:name, :kind, :devices, :rows) do
      # The device rows of the header's pins, bank 0, whose gpio= lines config.txt writes.
      def header_device_rows = rows.select { |row| row.device? && row.gpio < Pins::BANK0_PIN_COUNT }
      # PINS: the gpio rows as a mask, bit n for GPIO n, the pins the driver may serve.
      def gpio_mask = rows.select { |row| row.owner == :gpio }.sum { |row| 1 << row.gpio }
      # A device's states on this entry: default first, then the others in name order.
      def states_of(device) = [DEFAULT, *rows.select { |row| row.use == device }.flat_map { |row| row.states.keys }.uniq.sort]
    end

    # The checked table. settings are the boot description's settings whose pins are rows,
    # which config.txt writes on the kinds of card each lists; core_clock is the clock, in
    # Hz, of the devices other than UARTs that device rows name, which all divide the
    # VideoCore's core clock, nil when they name none.
    Table = Data.define(:controllers, :settings, :core_clock) do
      def rows = controllers.flat_map(&:rows)
    end

    # Which of the record's devices a driver drives: a device of a kind a give drives (given,
    # include/erx/device_kinds.h's erx_device_kinds), or the record's console or host link
    # UART (uarts, their paths), whose driver the system domain starts. A header device row
    # must name a driven device, and a driven device whose registers are a controller of the
    # pin table must have rows.
    Driven = Data.define(:given, :uarts) do
      def driven?(path, device)
        uarts.include?(path) || given.any? { |kind| kind.role == device['role'] && kind.compatible == device['compatible'] }
      end
    end

    DEFAULT = ABI::Generated::CODEC.fixed_bytes('pin_state_default').freeze
    ENTRY_KEYS = %w[controller name onboard rows soc].freeze
    ROW_KEYS = %w[function gpio level pull states use].freeze
    SETTING_KEYS = %w[function level pull].freeze
    PLAIN_USES = %w[gpio reserved].freeze
    JTAG = 'jtag'
    PULLS = { 'none' => :none, 'up' => :up, 'down' => :down }.freeze
    IN_OUT = %w[in out].freeze
    IDENTIFIER = /\A[a-z][a-z0-9_]{0,62}\z/
    # pin_states_max (abi/erx_abi.txt): the most states one device has, default among them.
    STATES_MAX = ABI::Generated::CODEC.constant('pin_states_max')
    # A device path's unit address, its registers' bus address, which is the address of the
    # device's controller row in the pin table.
    UNIT_ADDRESS = %r{\A/[^@]*@([0-9a-f]{1,8})\z}
    # The tree whose pin tables the running tools read, as DeviceKinds reads its header.
    CODE_ROOT = File.expand_path('../../..', __dir__)

    module_function

    # The table of record, a platform record whose units Platform has seen to be a list, or
    # nil when it has no pins. settings is the boot description's table the firmware rows
    # are checked against, by kind (BootPartition::FIRMWARE_SETTINGS).
    def read(record, settings: BootPartition::FIRMWARE_SETTINGS)
      return nil unless record.key?('pins')

      given = record.fetch('pins')
      raise Error, 'must be a list of pin controller entries' unless given.is_a?(Array) && !given.empty?

      devices = devices_by_path(record.fetch('units'))
      context = { devices: devices, console: record['console'], settings: settings,
                  driven: Driven.new(given: DeviceKinds.given(CODE_ROOT), uarts: [record['console'], record['hostlink']].compact) }
      controllers = given.each_with_index.map { |field, index| entry(field, index: index, **context) }
      names = controllers.map(&:name)
      raise Error, 'two pin controller entries have one name' unless names.uniq == names

      check_one_controller_for_states(controllers)
      # A chip has one pin table, so a second entry of its kind could only name its pins again,
      # out of reach of the checks that read one entry at a time.
      twin = controllers.map(&:kind).tally.find { |_kind, count| count > 1 }
      raise Error, "two pin controller entries are of kind #{twin.first}" if twin
      check_driven_have_rows(controllers, devices: devices, driven: context.fetch(:driven))
      Table.new(controllers: controllers.freeze,
                settings: controllers.flat_map { |entry| written_settings(entry, settings: settings) }.freeze,
                core_clock: core_clock(controllers.flat_map(&:rows), devices: devices))
    end

    # The record's devices that have a path, by path; a unit or device that is not an object
    # of the record's shape is refused.
    def devices_by_path(units)
      units.each_with_object({}) do |unit, devices|
        raise Error, 'a unit is not an object with a list of devices' unless unit.is_a?(Hash) && unit['devices'].is_a?(Array)

        unit['devices'].each do |device|
          raise Error, 'a device is not an object' unless device.is_a?(Hash)

          path = device['path']
          next unless path.is_a?(String)
          raise Error, "two devices have the path #{path}" if devices.key?(path)

          devices[path] = device
        end
      end
    end

    def entry(field, index:, devices:, console:, driven:, settings:)
      raise Error, "entry #{index} must be an object of #{ENTRY_KEYS.join(', ')}" unless field.is_a?(Hash) && field.keys.sort == ENTRY_KEYS

      name, kind, paths = field.values_at('name', 'soc', 'controller')
      raise Error, "entry #{index}: name #{name.inspect} is not an identifier" unless name.is_a?(String) && name.match?(IDENTIFIER)
      raise Error, "#{name}: controller must be a list of distinct device paths of the record" unless
        paths.is_a?(Array) && !paths.empty? && paths.uniq == paths && paths.all? { |path| devices.key?(path) }

      table = Pins.read(root: CODE_ROOT, soc: kind)
      row = lambda do |row_field, gpio, header|
        row(row_field, gpio: gpio, header: header, table: table, devices: devices, console: console, driven: driven)
      end
      rows = header_rows(field.fetch('rows'), row) + onboard_rows(field.fetch('onboard'), table: table, row: row)
      check_firmware(rows, settings: settings.fetch(kind, []), kind: kind, table: table, console: console)
      check_signals(rows, table: table)
      check_states(rows)
      Entry.new(name: name, kind: kind, devices: paths.freeze, rows: rows.freeze)
    end

    def header_rows(fields, row)
      raise Error, "rows must be a list of #{Pins::BANK0_PIN_COUNT}" unless fields.is_a?(Array) && fields.size == Pins::BANK0_PIN_COUNT

      fields.each_with_index.map do |field, gpio|
        raise Error, "row #{gpio} must be an object for GPIO #{gpio}" unless field.is_a?(Hash) && field['gpio'].eql?(gpio)

        row.call(field, gpio, true)
      end
    end

    # The on-board rows: each names a pin of the table that is not a header pin, and the pins
    # increase. A device need not be driven, unlike a header row's: the pin is wired to its
    # chip, and setting it touches nothing else.
    def onboard_rows(fields, table:, row:)
      raise Error, 'onboard must be a list of on-board rows' unless fields.is_a?(Array)

      onboard = fields.each_with_index.map do |field, index|
        raise Error, "on-board row #{index} must be an object with a gpio" unless field.is_a?(Hash)

        gpio = field['gpio']
        raise Error, "on-board GPIO #{gpio.inspect} is not an on-board pin of the pin table" unless
          !table.header_pin?(gpio) && table.pins.any? { |pin| pin.gpio.eql?(gpio) }

        row.call(field, gpio, false)
      end
      raise Error, 'on-board rows must be in increasing GPIO order, each GPIO once' unless
        onboard.each_cons(2).all? { |left, right| left.gpio < right.gpio }

      onboard
    end

    # One row: its owner, and the setting and states it must or must not have. A header
    # device row names a device of a kind: the pin driver would set the pins of a device of
    # no kind for a driver that never runs.
    def row(field, gpio:, header:, table:, devices:, console:, driven:)
      raise Error, "GPIO #{gpio}: a row is an object of #{ROW_KEYS.join(', ')}" unless (field.keys - ROW_KEYS).empty?

      use = field['use']
      keys = field.keys - %w[gpio use]
      case use
      in String if PLAIN_USES.include?(use)
        raise Error, "GPIO #{gpio}: a #{use} row has no setting or states" unless keys.empty?

        Row.new(gpio: gpio, use: use, owner: use.to_sym, setting: nil, states: {}.freeze)
      in String if use == JTAG || use == console
        raise Error, "GPIO #{gpio}: a firmware row (#{use}) has a function alone" unless keys == ['function']

        Row.new(gpio: gpio, use: use, owner: :firmware, setting: signal(field['function'], gpio: gpio, table: table), states: {}.freeze)
      in String if devices.key?(use)
        raise Error, "GPIO #{gpio}: #{use.inspect} is a device no driver drives" if header && !driven.driven?(use, devices.fetch(use))

        plain = field.slice(*SETTING_KEYS)
        Row.new(gpio: gpio, use: use, owner: :device, setting: setting(plain, gpio: gpio, table: table),
                states: states(field.fetch('states', {}), plain: plain, gpio: gpio, table: table))
      else
        raise Error, "GPIO #{gpio}: use #{use.inspect} is neither gpio, reserved, jtag, the console nor a device path of the record"
      end
    end

    # A signal of the pin, as a firmware row carries it.
    def signal(function, gpio:, table:)
      Setting.new(function: function, alternate: table.alternate(gpio: gpio, function: function), pull: nil, level: nil)
    end

    def setting(fields, gpio:, table:)
      function, pull, level = fields.values_at('function', 'pull', 'level')
      raise Error, "GPIO #{gpio}: pull #{pull.inspect} is not none, up or down" unless pull.nil? || PULLS.key?(pull)
      raise Error, "GPIO #{gpio}: out takes a level of 0 or 1, and nothing else takes a level" unless
        function == 'out' ? [0, 1].any? { |value| value.eql?(level) } : level.nil?

      alternate = IN_OUT.include?(function) ? nil : table.alternate(gpio: gpio, function: function)
      Setting.new(function: function, alternate: alternate, pull: PULLS[pull], level: level)
    end

    # A row's states, each overlaid on the plain setting's fields. A state names a pull only
    # where the plain setting names one, so every state of a device writes the same fields.
    def states(given, plain:, gpio:, table:)
      raise Error, "GPIO #{gpio}: states must be an object of state names" unless given.is_a?(Hash)

      given.to_h do |name, fields|
        raise Error, "GPIO #{gpio}: state #{name.inspect} is not an identifier other than default" unless
          name.match?(IDENTIFIER) && name != DEFAULT
        raise Error, "GPIO #{gpio}: state #{name} must be an object of #{SETTING_KEYS.join(', ')}" unless
          fields.is_a?(Hash) && !fields.empty? && (fields.keys - SETTING_KEYS).empty?
        raise Error, "GPIO #{gpio}: state #{name} names a pull, and the row's plain setting names none" if
          fields.key?('pull') && !plain.key?('pull')

        [name, setting(plain.merge(fields), gpio: gpio, table: table)]
      end.freeze
    end

    # In each state, each device's rows and the jtag rows carry only signals of the device's
    # controller, each once; in default, every signal the controller cannot work without,
    # and the jtag rows every JTAG signal. Every row with a signal is checked, whatever its
    # use is named: a device path "gpio" cannot pass as a plain row.
    def check_signals(rows, table:)
      rows.select(&:setting).group_by(&:use).each do |use, named|
        controller = use == JTAG ? table.fetch_named(JTAG) : table.fetch_controller(base: unit_address(use))
        [DEFAULT, *named.flat_map { |row| row.states.keys }.uniq].each do |state|
          signals = named.map { |row| [row.gpio, row.setting_in(state)] }.reject { |_gpio, setting| setting.alternate.nil? }
          stray = signals.find { |_gpio, setting| !controller.signals.include?(setting.function) }
          raise Error, "GPIO #{stray[0]}: #{stray[1].function} is not a signal of #{use}, #{controller.name}" if stray

          functions = signals.map { |_gpio, setting| setting.function }
          raise Error, "#{use} names a signal on two rows in state #{state}" unless functions.uniq == functions
          next unless state == DEFAULT

          missing = (use == JTAG ? controller.signals : controller.required) - functions
          raise Error, "#{use} has no row for #{missing.join(', ')}" unless missing.empty?
        end
      end
    end

    # Each device has at most STATES_MAX states, and no two of them, default among them,
    # have the same settings, so a reading of its pins is at most one of its states.
    def check_states(rows)
      rows.select(&:device?).group_by(&:use).each do |device, named|
        states = [DEFAULT, *named.flat_map { |row| row.states.keys }.uniq]
        raise Error, "#{device} has #{states.size} states, more than #{STATES_MAX}" if states.size > STATES_MAX

        twins = states.group_by { |state| named.map { |row| row.setting_in(state) } }.values.find { |same| same.size > 1 }
        raise Error, "#{device}: states #{twins.join(' and ')} have the same settings" if twins
      end
    end

    # A firmware row is a pin of one of the boot description's settings for the kind, with
    # that setting's signal, and a setting's pins are all rows or none. The console's rows
    # come from one setting, written on every kind of card, whose signals are the console
    # device's; so the pins the pin driver leaves alone are pins the firmware is told to set.
    def check_firmware(rows, settings:, kind:, table:, console:)
      firmware = rows.select { |row| row.owner == :firmware }
      firmware.each do |row|
        setting = settings.find { |candidate| candidate.pins.include?(row.gpio) }
        raise Error, "GPIO #{row.gpio}: a #{row.use} row is no pin of a firmware setting of #{kind}" if setting.nil?
        raise Error, "GPIO #{row.gpio}: #{setting.name} puts #{setting.signals.fetch(row.gpio)} there, not #{row.setting.function}" unless
          setting.signals.fetch(row.gpio) == row.setting.function
      end
      settings.each do |setting|
        named = firmware.count { |row| setting.pins.include?(row.gpio) }
        raise Error, "#{setting.name} sets GPIO #{setting.pins.join(', ')}, and only some of them are rows" unless
          [0, setting.pins.size].include?(named)
      end
      console_settings = settings.select { |setting| firmware.any? { |row| row.use == console && setting.pins.include?(row.gpio) } }
      check_console_setting(console_settings, table: table, console: console) unless console_settings.empty?
    end

    def check_console_setting(settings, table:, console:)
      raise Error, "the console's rows come from #{settings.size} firmware settings, not one" unless settings.size == 1

      setting = settings.first
      signals = table.fetch_controller(base: unit_address(console)).signals
      raise Error, "#{setting.name}'s signals are not the console's" unless (setting.signals.values - signals).empty?
      raise Error, "#{setting.name} is not written on every kind of card" unless (BuildKind::ALL - setting.kinds).empty?
    end

    # A device whose states are not default alone has its rows on one entry, since a select
    # is one process's one plan.
    def check_one_controller_for_states(controllers)
      places = controllers.flat_map { |entry| entry.rows.select(&:device?).map { |row| [row.use, entry.name] } }.uniq
      stated = controllers.flat_map(&:rows).select { |row| row.states.any? }.map(&:use).uniq
      split = stated.find { |device| places.count { |use, _name| use == device } > 1 }
      raise Error, "#{split} has states other than default on two pin controllers" if split
    end

    # A driven device whose registers are a controller of an entry's SoC table has rows in
    # the table: its driver would otherwise run with its pins as the firmware left them.
    def check_driven_have_rows(controllers, devices:, driven:)
      tables = controllers.map(&:kind).uniq.map { |kind| Pins.read(root: CODE_ROOT, soc: kind) }
      named = controllers.flat_map(&:rows).map(&:use)
      unnamed = devices.find { |path, device| driven.driven?(path, device) && tables.any? { |table| controller?(path, table) } && !named.include?(path) }
      raise Error, "the record's driven device #{unnamed[0].inspect} has no pins in the table" if unnamed
    end

    # The settings of the entry's kind whose pins are rows.
    def written_settings(entry, settings:)
      firmware = entry.rows.select { |row| row.owner == :firmware }.map(&:gpio)
      settings.fetch(entry.kind, []).select { |setting| (setting.pins - firmware).empty? }
    end

    # Whether the device at path is a controller of the pin table, a device the table may
    # give pins to; a path with no unit address, such as /chosen, is none.
    def controller?(path, table)
      address = path[UNIT_ADDRESS, 1]
      !address.nil? && table.controllers.any? { |controller| controller.base == Integer(address, 16) }
    end

    def unit_address(path)
      address = path[UNIT_ADDRESS, 1]
      raise Error, "device path #{path} has no unit address" if address.nil?

      Integer(address, 16)
    end

    # The one clock of the devices other than UARTs that device rows name, a whole number of
    # MHz, the grain config.txt's core_freq takes; devices that disagree, or one without a
    # clock, are refused.
    def core_clock(rows, devices:)
      bused = rows.filter_map { |row| devices.fetch(row.use) if row.device? }.uniq.reject { |device| device['role'] == 'uart' }
      clocks = bused.map { |device| device['clock'] }.uniq
      return nil if bused.empty?
      raise Error, "the table's I2C and SPI devices need one core clock in whole MHz, not #{clocks.inspect}" unless
        clocks.size == 1 && clocks[0].is_a?(Integer) && clocks[0].positive? && (clocks[0] % 1_000_000).zero?

      clocks[0]
    end
    private_class_method :devices_by_path, :entry, :header_rows, :onboard_rows, :row, :signal, :setting, :states,
                         :check_signals, :check_states, :check_firmware, :check_console_setting,
                         :check_one_controller_for_states, :check_driven_have_rows, :written_settings, :controller?, :unit_address, :core_clock
  end
end
