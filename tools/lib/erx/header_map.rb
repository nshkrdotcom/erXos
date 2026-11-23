# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_kinds'
require_relative 'error'
require_relative 'pins'

module Erx
  # A platform record's header map, its "pins" object (docs/design-header-io.md, "The
  # construction: one map of the header" and "On-board pins"), of four keys:
  # * soc, the SoC's pin table (hw/pins/<soc>.txt);
  # * controller, the path of the pin controller, the device whose registers set every
  #   bank-0 pin's function;
  # * rows, one for each of GPIO 0 to 27 in order, each a gpio number and a use, and for a
  #   pin another block drives, its function and pull;
  # * onboard, in increasing GPIO order, one row for each pin wired on the board to a chip
  #   that needs the pin's function set (on the Pi 4, GPIO 30 to 33, UART0's to the
  #   Bluetooth controller), each a gpio number, the device path of the SoC block whose
  #   signal the pin carries, and the function.
  # The record reader (Platform) checks the map against the pin table and the record's own
  # devices; config.txt's gpio= lines, enable_jtag_gpio and core_freq are derived from it
  # (BootPartition), and the manifest's onboard_pins from its on-board rows (Manifest), so
  # nothing else states a pin. A map that breaks a rule is refused
  # whole, at its first broken rule, naming the row.
  module HeaderMap
    # One pin. use is "gpio" (plain GPIO, whose pull is its holder's to set), "reserved"
    # (nothing touches the pin), "jtag" (the ARM's JTAG, which enable_jtag_gpio sets on a
    # development card) or a device path of the record (the firmware sets the pin for that
    # device). function and alternate, the function's pin-table name and its alternate
    # number, are a jtag or device row's, header or on-board; pull is a header device row's
    # alone, :none, :up or :down, and nil on an on-board row, whose pull nothing sets.
    Row = Data.define(:gpio, :use, :function, :alternate, :pull) do
      def device? = use.start_with?('/')
    end

    # The checked map. core_clock is the clock, in Hz, of the devices other than UARTs that
    # header or on-board rows name, the I2C and SPI controllers, which all divide the
    # VideoCore's core clock; nil when the rows name none. device_rows are the header's
    # device rows; onboard holds the on-board rows.
    Map = Data.define(:controller, :rows, :onboard, :core_clock) do
      def device_rows = rows.select(&:device?)
      def jtag? = rows.any? { |row| row.use == 'jtag' }
      # PINS: the gpio rows as a mask, bit n for GPIO n, the pins the pin controller's driver
      # may serve.
      def gpio_mask = rows.select { |row| row.use == 'gpio' }.sum { |row| 1 << row.gpio }
    end

    # Which of the record's devices a driver drives: a device of a kind a give drives (given,
    # include/erx/device_kinds.h's erx_device_kinds), or the record's console or host link
    # UART (uarts, their paths), whose driver the system domain starts. A device row must
    # name a driven device, and a driven device whose registers are a controller of the pin
    # table must have rows.
    Driven = Data.define(:given, :uarts) do
      def driven?(path, device)
        uarts.include?(path) || given.any? { |kind| kind.role == device['role'] && kind.compatible == device['compatible'] }
      end
    end

    KEYS = %w[controller onboard rows soc].freeze
    ROW_KEYS = %w[function gpio pull use].freeze
    ONBOARD_KEYS = %w[device function gpio].freeze
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
    # when it has no pins.
    def read(record)
      return nil unless record.key?('pins')

      given = record.fetch('pins')
      raise Error, 'must be an object of controller, onboard, rows and soc' unless given.is_a?(Hash) && given.keys.sort == KEYS

      devices = devices_by_path(record.fetch('units'))
      controller = given.fetch('controller')
      raise Error, "pin controller #{controller.inspect} is not a device path of the record" unless devices.key?(controller)

      table = Pins.read(root: CODE_ROOT, soc: given.fetch('soc'))
      driven = Driven.new(given: DeviceKinds.given(CODE_ROOT), uarts: [record['console'], record['hostlink']].compact)
      rows = rows(given.fetch('rows'), table: table, devices: devices, driven: driven)
      onboard = onboard_rows(given.fetch('onboard'), table: table, devices: devices)
      every = rows + onboard
      check_signals(every, table: table)
      pinned = devices.select { |path, device| driven.driven?(path, device) && controller?(path, table) }.keys
      unnamed = pinned - every.map(&:use)
      raise Error, "the record's driven device #{unnamed.first.inspect} has no pins in the map" unless unnamed.empty?

      Map.new(controller: controller, rows: rows.freeze, onboard: onboard.freeze, core_clock: core_clock(every, devices: devices))
    end

    # The on-board rows of record's map alone, each checked as read checks it, for a reader
    # that needs no other row (the manifest's onboard_pins); none when it has no pins.
    def read_onboard(record)
      return [] unless record.key?('pins')

      given = record.fetch('pins')
      onboard_rows(given.fetch('onboard'), table: Pins.read(root: CODE_ROOT, soc: given.fetch('soc')),
                                           devices: devices_by_path(record.fetch('units')))
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

    def rows(fields, table:, devices:, driven:)
      raise Error, "rows must be a list of #{Pins::BANK0_PIN_COUNT}" unless fields.is_a?(Array) && fields.size == Pins::BANK0_PIN_COUNT

      fields.each_with_index.map do |field, gpio|
        unless field.is_a?(Hash) && field['gpio'].eql?(gpio) && (field.keys - ROW_KEYS).empty?
          raise Error, "row #{gpio} must be an object for GPIO #{gpio} of #{ROW_KEYS.join(', ')}"
        end

        row(field, gpio: gpio, table: table, devices: devices, driven: driven)
      end
    end

    # One row's use, and the function and pull it must or must not have. A device row names
    # a device of a kind: the firmware would set the pins of a device of no kind for a
    # driver that never runs.
    def row(field, gpio:, table:, devices:, driven:)
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
        raise Error, "GPIO #{gpio}: #{use.inspect} is a device no driver drives" unless driven.driven?(use, devices.fetch(use))

        Row.new(gpio: gpio, use: use, function: function, alternate: table.alternate(gpio: gpio, function: function), pull: PULLS.fetch(pull))
      else
        raise Error, "GPIO #{gpio}: use #{use.inspect} is neither gpio, reserved, jtag nor a device path of the record"
      end
    end

    # The on-board rows: each names a pin of the table that is not a header pin, a device
    # path of the record and a function the pin carries, and the pins increase. A device
    # need not be driven, unlike a header row's: the pin is wired to its chip, and setting
    # its function touches nothing else.
    def onboard_rows(fields, table:, devices:)
      raise Error, 'onboard must be a list of on-board rows' unless fields.is_a?(Array)

      onboard = fields.each_with_index.map do |field, index|
        unless field.is_a?(Hash) && field.keys.sort == ONBOARD_KEYS
          raise Error, "on-board row #{index} must be an object of device, function and gpio"
        end

        gpio, device, function = field.values_at('gpio', 'device', 'function')
        raise Error, "on-board GPIO #{gpio} is a header pin, set by its row in rows" if table.header_pin?(gpio)
        raise Error, "on-board GPIO #{gpio.inspect}: #{device.inspect} is not a device path of the record" unless devices.key?(device)

        Row.new(gpio: gpio, use: device, function: function, alternate: table.alternate(gpio: gpio, function: function), pull: nil)
      end
      unless onboard.each_cons(2).all? { |left, right| left.gpio < right.gpio }
        raise Error, 'on-board rows must be in increasing GPIO order, each GPIO once'
      end

      onboard
    end

    # Each device's rows, and the jtag rows, carry only signals of the device's controller,
    # each once, with every signal it cannot work without; the jtag rows carry every JTAG
    # signal, since enable_jtag_gpio sets all of their pins. Every row with a function is
    # checked, whatever its use is named: a device path "gpio" cannot pass as a plain row.
    def check_signals(rows, table:)
      rows.select(&:function).group_by(&:use).each do |use, named|
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

    # Whether the device at path is a controller of the pin table, a device the map may give
    # pins to; a path with no unit address, such as /chosen, is none.
    def controller?(path, table)
      address = path[UNIT_ADDRESS, 1]
      !address.nil? && table.controllers.any? { |controller| controller.base == Integer(address, 16) }
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
    private_class_method :devices_by_path, :rows, :row, :onboard_rows, :check_signals, :controller?, :unit_address, :core_clock
  end
end
