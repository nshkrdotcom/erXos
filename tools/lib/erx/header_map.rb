# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'pins'

module Erx
  # A platform record's header map, its "header" object (docs/design-header-io.md, "The
  # construction: one map of the header"): pins, the SoC's pin table (hw/pins/<pins>.txt);
  # controller, the path of the pin controller, the device whose registers set every bank-0
  # pin's function; and rows, one for each of GPIO 0 to 27 in order, each a gpio number and a
  # use, and for a pin another block drives, its function and pull. The record reader
  # (Platform) checks the map against the pin table and the record's own devices, and
  # config.txt's gpio= lines, enable_jtag_gpio and core_freq are derived from it
  # (BootPartition), so nothing else states a pin. A map that breaks a rule is refused
  # whole, at its first broken rule, naming the row.
  module HeaderMap
    # One pin. use is "gpio" (plain GPIO, whose pull is its holder's to set), "reserved"
    # (nothing touches the pin), "jtag" (the ARM's JTAG, which enable_jtag_gpio sets on a
    # development card) or a device path of the record (the firmware sets the pin for that
    # device). function and alternate, the function's pin-table name and its alternate
    # number, are a jtag or device row's; pull, :none, :up or :down, a device row's alone.
    Row = Data.define(:gpio, :use, :function, :alternate, :pull) do
      def device? = use.start_with?('/')
    end

    # The checked map. core_clock is the clock, in Hz, of the devices other than UARTs that
    # rows name, the I2C and SPI controllers, which all divide the VideoCore's core clock;
    # nil when the rows name none.
    Map = Data.define(:controller, :rows, :core_clock) do
      def device_rows = rows.select(&:device?)
      def jtag? = rows.any? { |row| row.use == 'jtag' }
      # PINS: the gpio rows as a mask, bit n for GPIO n, the pins the pin controller's driver
      # may serve.
      def gpio_mask = rows.select { |row| row.use == 'gpio' }.sum { |row| 1 << row.gpio }
    end

    KEYS = %w[controller pins rows].freeze
    ROW_KEYS = %w[function gpio pull use].freeze
    PLAIN_USES = %w[gpio reserved].freeze
    JTAG = 'jtag'
    PULLS = { 'none' => :none, 'up' => :up, 'down' => :down }.freeze
    # A device path's unit address, its registers' bus address, which is the address of the
    # device's controller row in the pin table.
    UNIT_ADDRESS = %r{\A/[^@]*@([0-9a-f]{1,8})\z}
    # The tree whose pin tables the running tools read, as DeviceKinds reads its header.
    CODE_ROOT = File.expand_path('../../..', __dir__)

    module_function

    # The map of record, a platform record whose units Platform has seen to be a list, or nil
    # when it has no header.
    def read(record)
      return nil unless record.key?('header')

      header = record.fetch('header')
      raise Error, 'header must be an object of controller, pins and rows' unless header.is_a?(Hash) && header.keys.sort == KEYS

      devices = devices_by_path(record.fetch('units'))
      controller = header.fetch('controller')
      raise Error, "pin controller #{controller.inspect} is not a device path of the record" unless devices.key?(controller)

      table = Pins.read(root: CODE_ROOT, soc: header.fetch('pins'))
      rows = rows(header.fetch('rows'), table: table, devices: devices)
      check_signals(rows, table: table)
      unnamed = (devices.keys & [record['console'], record['hostlink']]) - rows.map(&:use)
      raise Error, "the record's UART #{unnamed.first} has no pins in the map" unless unnamed.empty?

      Map.new(controller: controller, rows: rows.freeze, core_clock: core_clock(rows, devices: devices))
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

    def rows(fields, table:, devices:)
      raise Error, "rows must be a list of #{Pins::BANK0_PIN_COUNT}" unless fields.is_a?(Array) && fields.size == Pins::BANK0_PIN_COUNT

      fields.each_with_index.map do |field, gpio|
        unless field.is_a?(Hash) && field['gpio'].eql?(gpio) && (field.keys - ROW_KEYS).empty?
          raise Error, "row #{gpio} must be an object for GPIO #{gpio} of #{ROW_KEYS.join(', ')}"
        end

        row(field, gpio: gpio, table: table, devices: devices)
      end
    end

    # One row's use, and the function and pull it must or must not have.
    def row(field, gpio:, table:, devices:)
      use, function, pull = field.values_at('use', 'function', 'pull')
      case use
      in String if PLAIN_USES.include?(use)
        raise Error, "GPIO #{gpio}: a #{use} row has no function or pull" unless function.nil? && pull.nil?

        Row.new(gpio: gpio, use: use, function: nil, alternate: nil, pull: nil)
      in JTAG
        raise Error, "GPIO #{gpio}: a jtag row has a function and no pull" unless pull.nil?

        Row.new(gpio: gpio, use: use, function: function, alternate: table.alternate(gpio: gpio, function: function), pull: nil)
      in String if devices.key?(use)
        raise Error, "GPIO #{gpio}: a device row's pull is none, up or down" unless PULLS.key?(pull)

        Row.new(gpio: gpio, use: use, function: function, alternate: table.alternate(gpio: gpio, function: function), pull: PULLS.fetch(pull))
      else
        raise Error, "GPIO #{gpio}: use #{use.inspect} is neither gpio, reserved, jtag nor a device path of the record"
      end
    end

    # Each device's rows, and the jtag rows, carry only signals of the device's controller,
    # each once, with every signal it cannot work without; the jtag rows carry every JTAG
    # signal, since enable_jtag_gpio sets all of their pins.
    def check_signals(rows, table:)
      rows.reject { |row| PLAIN_USES.include?(row.use) }.group_by(&:use).each do |use, named|
        controller = use == JTAG ? table.fetch_named(JTAG) : table.fetch_controller(base: unit_address(use))
        functions = named.map(&:function)
        stray = named.find { |row| !controller.signals.include?(row.function) }
        raise Error, "GPIO #{stray.gpio}: #{stray.function} is not a signal of #{use}, #{controller.name}" if stray
        raise Error, "#{use} names a signal on two rows" unless functions.uniq == functions

        needed = use == JTAG ? controller.signals : controller.required
        missing = needed - functions
        raise Error, "#{use} has no row for #{missing.join(', ')}" unless missing.empty?
      end
    end

    def unit_address(path)
      address = path[UNIT_ADDRESS, 1]
      raise Error, "device path #{path} has no unit address" if address.nil?

      Integer(address, 16)
    end

    # The one clock of the devices other than UARTs that rows name, a whole number of MHz,
    # the grain config.txt's core_freq takes; devices that disagree, or one without a clock,
    # are refused.
    def core_clock(rows, devices:)
      bused = rows.filter_map { |row| devices.fetch(row.use) if row.device? }.uniq.reject { |device| device['role'] == 'uart' }
      clocks = bused.map { |device| device['clock'] }.uniq
      return nil if bused.empty?
      raise Error, "the map's I2C and SPI devices need one core clock in whole MHz, not #{clocks.inspect}" unless
        clocks.size == 1 && clocks[0].is_a?(Integer) && clocks[0].positive? && (clocks[0] % 1_000_000).zero?

      clocks[0]
    end
    private_class_method :devices_by_path, :rows, :row, :check_signals, :unit_address, :core_clock
  end
end
