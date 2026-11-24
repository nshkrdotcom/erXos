#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz timed

require 'json'
require 'optparse'
require_relative '../lib/erx/json_input'
require_relative '../lib/erx/platform'

# The platform record's reader (Erx::Platform, with its pin table, Erx::PinTable) over
# mutations of the Raspberry Pi 4's record: values of every row and field replaced by
# others of each JSON type, rows dropped, repeated and swapped, a second controller entry
# whose console and JTAG rows are plain GPIO added beside the first, and the record's text
# changed byte by byte. Each input is either refused with Erx::Error and nothing else, or
# read into pin controller entries each with one row for each of GPIO 0 to 27 first, whose
# firmware rows carry no pull and no states, whose device rows each carry a signal with an
# alternate of 0 to 5, in or out, and in which no row but a firmware row sits on a pin of a
# setting config.txt writes (the table's settings: the console's and JTAG's), so no row of
# the build could reach them. Whether the reader's answers are right
# is test/host/pin_table_test.rb's.
module Erx
  module PlatformRecordFuzz
    ROOT = File.expand_path('../..', __dir__)
    NAME = 'raspi4b'
    SEED = Platform.load(root: ROOT, name: NAME).record
    # Values a mutation puts in a field: the record's own words, near misses and every JSON type.
    VALUES = ['gpio', 'reserved', 'jtag', '/soc/i2c@7e804000', '/soc/spi@7e204000', '/soc/serial@7e201600',
              '/soc/serial@7e215040', '/soc/serial@7e201000', '/soc/gpio@7e200000', '/soc/spi@7e215080', '/soc/i2c@', '/', 'SDA1', 'TXD1',
              'ARM_TMS', 'SPI0_SCLK', 'CTS0', 'RXD0', 'MII_A_CRS', 'none', 'up', 'down', 'bcm2711', '../bcm2711', 'uart', 'ordinary', '', -1, 0, 2,
              27, 28, 30, 33, 34, 2.0, 500_000_000, 1 << 64, nil, true, [], {}, [1], { 'gpio' => 0 }].freeze

    module_function

    # A mutable copy of a plain JSON value, nested containers included.
    def deep_copy(value) = Marshal.load(Marshal.dump(value))

    # A path into the record's pins and devices: [key, ...] down to a leaf or a container.
    def paths(value, prefix = [])
      children = case value
                 when Hash then value.map { |key, child| [key, child] }
                 when Array then value.each_with_index.map { |child, index| [index, child] }
                 else []
                 end
      [prefix] + children.flat_map { |key, child| paths(child, prefix + [key]) }
    end

    # The child of node at key, nil when an earlier mutation of the same input moved it.
    def child(node, key)
      case node
      when Hash then node[key]
      when Array then key.is_a?(Integer) ? node[key] : nil
      end
    end

    # A second entry of the first's kind under another name, its console and JTAG rows plain
    # GPIO: one table's pins named twice, out of reach of the checks that read one entry.
    def twin(record)
      entry = deep_copy(record.fetch('pins').first)
      entry['rows'].each { |row| row.replace('gpio' => row['gpio'], 'use' => 'gpio') if row['use'] == 'jtag' || row['use'] == record['console'] }
      entry.merge('name' => "#{entry['name']}_twin")
    end

    def mutate(record, random)
      result = deep_copy(record)
      result['pins'] = [*result['pins'], twin(record)] if random.rand(8).zero?
      targets = paths(result.slice('pins', 'units', 'console', 'hostlink')).reject(&:empty?)
      random.rand(1..3).times do
        path = targets.sample(random: random)
        parent = path[0...-1].reduce(result) { |node, key| child(node, key) }
        key = path.last
        next if child(parent, key).nil? && !(parent.is_a?(Hash) && parent.key?(key))
        case random.rand(4)
        when 0 then parent[key] = deep_copy(VALUES.sample(random: random))
        when 1 then parent.is_a?(Hash) ? parent.delete(key) : parent.delete_at(key)
        when 2 then parent.is_a?(Array) ? parent.insert(key, deep_copy(parent[key])) : parent["#{key}x"] = parent[key]
        else
          other = random.rand([parent.size, 1].max)
          parent[key], parent[other] = parent[other], parent[key] if parent.is_a?(Array)
        end
      end
      result
    end

    def mutate_text(record, random)
      text = JSON.generate(record).b
      random.rand(1..4).times { text.setbyte(random.rand(text.bytesize), [random.rand(256), 0x22, 0x2c, 0x7b, 0x5d].sample(random: random)) }
      JsonInput.parse(text, max_bytes: 65_536, label: 'fuzzed platform record')
    end

    def exercise(record)
      table = Platform.new(name: NAME, record: record).pins
      return if table.nil?

      firmware_pins = table.settings.flat_map(&:pins)
      table.controllers.each do |entry|
        raise 'a row of the build on a pin the firmware sets' unless
          entry.rows.select { |row| firmware_pins.include?(row.gpio) }.all? { |row| row.owner == :firmware }
        raise 'a table without its header rows' unless entry.rows.map(&:gpio).take(28) == (0..27).to_a
        raise 'a firmware row with a pull or states' unless
          entry.rows.select { |row| row.owner == :firmware }.all? { |row| row.setting.pull.nil? && row.states.empty? }
        raise 'a signal without its alternate' unless
          entry.rows.select(&:device?).all? { |row| %w[in out].include?(row.setting.function) || (0..5).cover?(row.setting.alternate) }
      end
    rescue Erx::Error
      nil
    end

    def run(seconds:, seed:)
      random = Random.new(seed)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      count = 0
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        begin
          exercise(random.rand(8).zero? ? mutate_text(SEED, random) : mutate(SEED, random))
        rescue Erx::Error
          nil
        end
        count += 1
      end
      count
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seconds: 3, seed: 1 }
  OptionParser.new do |arguments|
    arguments.on('--seconds N', Integer) { |value| options[:seconds] = value }
    arguments.on('--seed N', Integer) { |value| options[:seed] = value }
  end.parse!(ARGV)
  raise OptionParser::InvalidArgument, 'budget of 1..60 seconds' unless options[:seconds].between?(1, 60)

  puts "platform record reader: #{Erx::PlatformRecordFuzz.run(**options)} inputs"
end
