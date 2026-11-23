# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'bounded_file'

module Erx
  # A SoC's pin table, hw/pins/<soc>.txt: the power-on pull and alternate functions of each
  # bank-0 pin, the header's, and of each on-board pin a platform record names, and the
  # controllers that own those functions (docs/design-header-io.md, "The construction: one
  # map of the header" and "On-board pins"). The file's own header states the format;
  # this reader checks every row against it and refuses the whole table at its first bad
  # row.
  module Pins
    # A pin's row: its GPIO number, its power-on pull, and the function of each alternate,
    # ALT0 to ALT5, nil where the datasheet reserves it.
    Pin = Data.define(:gpio, :pull, :functions)
    # A controller's row: its name, its registers' bus address (nil for none), the signals
    # it cannot work without, and those it may also use.
    Controller = Data.define(:name, :base, :required, :optional) do
      def signals = required + optional
    end

    # The whole table, and the questions a header map asks of it. A map row gives a pin to
    # the device at a base address: that base must name a controller row, and the row's
    # function must be one of that controller's signals, so a function no row owns can
    # never be given to a device.
    Table = Data.define(:pins, :controllers) do
      # The alternate number, 0 to 5, at which the pin carries the function.
      def alternate(gpio:, function:)
        raise Error, "invalid function name: #{function.inspect}" unless function.is_a?(String) && function.match?(FUNCTION)

        pin = pins.find { |candidate| gpio.is_a?(Integer) && candidate.gpio == gpio }
        raise Error, "GPIO #{gpio.inspect} is not in the pin table" if pin.nil?

        index = pin.functions.index(function)
        raise Error, "GPIO #{gpio} does not carry #{function}" if index.nil?

        index
      end

      # Whether the GPIO is one of the header's, bank 0, which a header map row sets; every
      # other pin of the table is an on-board pin.
      def header_pin?(gpio) = gpio.is_a?(Integer) && gpio.between?(0, BANK0_PIN_COUNT - 1)

      # The controller whose registers are at the base address; raises when no row has it.
      def fetch_controller(base:)
        controller = controllers.find { |candidate| base.is_a?(Integer) && candidate.base == base }
        raise Error, "no controller of the pin table is at #{base.inspect}" if controller.nil?

        controller
      end

      # The controller with the name, such as jtag, which has no base; raises when no row has it.
      def fetch_named(name)
        controller = controllers.find { |candidate| candidate.name == name }
        raise Error, "no controller is named #{name.inspect}" if controller.nil?

        controller
      end
    end

    BANK0_PIN_COUNT = 28
    PULLS = %w[up down none].freeze
    ALTERNATES = 6
    MAX_BYTES = 64 * 1024
    FUNCTION = %r{\A[A-Z][A-Z0-9_]*(?:/[A-Z][A-Z0-9_]*)?\z}
    NAME = /\A[a-z][a-z0-9_]*\z/
    BASE = /\A0x[0-9a-f]{8}\z/
    module_function

    def read(root:, soc:)
      raise Error, "invalid SoC name: #{soc.inspect}" unless soc.is_a?(String) && soc.match?(NAME)

      parse(BoundedFile.read(File.join(root, 'hw/pins', "#{soc}.txt"), maximum: MAX_BYTES))
    end

    # Pin rows come first, GPIO 0 to 27 in order, then the on-board pins in increasing order;
    # controller rows follow, sorted by name.
    def parse(bytes)
      raise Error, 'pin table must be bounded ASCII' unless bytes.is_a?(String) && bytes.bytesize <= MAX_BYTES && bytes.ascii_only?

      rows = bytes.lines.map(&:split).reject { |words| words.empty? || words.first.start_with?('#') }
      # The leading run of pin rows; every row after it must be a controller row.
      pin_rows = rows.take_while { |words| words.first == 'pin' }
      controller_rows = rows.drop(pin_rows.size)
      unless controller_rows.all? { |words| words.first == 'controller' }
        raise Error, 'pin table rows must be pin rows, then controller rows'
      end
      pins = pin_rows.map { |words| pin(words) }
      gpios = pins.map(&:gpio)
      unless gpios.take(BANK0_PIN_COUNT) == (0...BANK0_PIN_COUNT).to_a && gpios.each_cons(2).all? { |left, right| left < right }
        raise Error, "pin table must list GPIO 0 to #{BANK0_PIN_COUNT - 1}, then the on-board pins, in order"
      end

      controllers = controller_rows.map { |words| controller(words) }
      check_controllers(controllers, pins: pins)
      Table.new(pins: pins.freeze, controllers: controllers.freeze)
    end

    def pin(words)
      raise Error, "pin row needs a GPIO, a pull and #{ALTERNATES} functions: #{words.join(' ')}" unless words.size == 3 + ALTERNATES

      _, gpio, pull, *functions = words
      raise Error, "invalid GPIO number: #{gpio}" unless gpio.match?(/\A(?:0|[1-9][0-9]?)\z/)
      raise Error, "invalid pull on GPIO #{gpio}: #{pull}" unless PULLS.include?(pull)

      named = functions.map { |function| function == '-' ? nil : function(function) }
      raise Error, "GPIO #{gpio} carries a function twice" unless named.compact.uniq == named.compact

      Pin.new(gpio: Integer(gpio, 10), pull: pull.to_sym, functions: named.freeze)
    end

    def controller(words)
      _, name, base, *signals = words
      raise Error, "invalid controller name: #{name.inspect}" unless name&.match?(NAME)
      raise Error, "invalid base address of #{name}: #{base.inspect}" unless base == 'none' || base&.match?(BASE)

      required, optional = required_and_optional(signals, name: name)
      Controller.new(name: name, base: base == 'none' ? nil : Integer(base, 16),
                     required: required.map { |signal| function(signal) }.freeze,
                     optional: optional.map { |signal| function(signal) }.freeze)
    end

    # A controller's signals split at the word optional: those before it, which must not be
    # empty, and those after it, which must not be empty when the word is there. A second
    # optional is refused later, as a function name.
    def required_and_optional(signals, name:)
      split = signals.index('optional')
      required = split ? signals.take(split) : signals
      optional = split ? signals.drop(split + 1) : []
      if required.empty? || (split && optional.empty?)
        raise Error, "controller #{name} needs required signals, and signals after optional"
      end

      [required, optional]
    end

    def function(word)
      raise Error, "invalid function name: #{word}" unless word.match?(FUNCTION)

      word.freeze
    end

    # Every signal is some pin's function and belongs to one controller; names and
    # addresses are unique, and the rows are sorted by name.
    def check_controllers(controllers, pins:)
      names = controllers.map(&:name)
      raise Error, 'controller rows must be sorted by name, each once' unless names.each_cons(2).all? { |left, right| left < right }

      bases = controllers.filter_map(&:base)
      raise Error, 'two controllers share a base address' unless bases.uniq == bases

      signals = controllers.flat_map(&:signals)
      raise Error, 'a signal belongs to two controllers or appears twice' unless signals.uniq == signals

      carried = pins.flat_map(&:functions).compact
      stray = signals - carried
      raise Error, "controller signal is no pin's function: #{stray.first}" unless stray.empty?
    end
    private_class_method :pin, :controller, :required_and_optional, :function, :check_controllers
  end
end
