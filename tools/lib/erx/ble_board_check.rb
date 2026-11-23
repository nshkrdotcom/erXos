# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The verdicts of tools/ble_board_check.rb: pure functions from what a blew run
  # printed and how it exited to passed, failed or unknown. blew's exit codes are its
  # README's "Exit codes" table: 0 success, 2 no matching device, 3 Bluetooth
  # unavailable or not permitted, 4 timeout, 5 an operation failed, 6 invalid
  # arguments. Only 0, 2 and 5 say something about the board, so only those reach a
  # step's own check; every other exit, and a run with no exit status (killed on its
  # deadline), is unknown, never a guess.
  module BleBoardCheck
    NUS_SERVICE = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E'
    NUS_RX = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E'

    # What a blew run printed (its standard output and error together) and its exit
    # status, nil when it was killed.
    Run = Data.define(:output, :status)
    Outcome = Data.define(:status, :detail)

    # A step's blew arguments after the global options (none for a step blew cannot
    # run yet), and its verdict on the output and the exit code.
    Step = Data.define(:name, :argv, :check)

    # A CoreBluetooth device identifier, the only thing of a scan that reaches a script.
    IDENTIFIER = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/.freeze
    DECIDING_EXITS = [0, 2, 5].freeze

    # One line of `blew --out kv scan`: a quoted name when it holds a space or a quote.
    SCAN_LINE = /\Aid=(?<id>#{IDENTIFIER}) name=(?:"(?<quoted>(?:[^"\\]|\\.)*)"|(?<bare>\S+)) /.freeze
    EXIT_LINE = /^Error: exit code (\d+)$/.freeze

    module_function

    def outcome(status, detail) = Outcome.new(status: status, detail: detail)

    # The identifiers of the devices that advertise exactly this name. blew's own
    # --name is a substring match that picks the strongest signal, so another device
    # could stand in for the board.
    def board_ids(output, name)
      output.each_line.filter_map do |line|
        found = SCAN_LINE.match(line)
        next unless found

        advertised = found[:quoted] ? found[:quoted].gsub(/\\(.)/m, '\1') : found[:bare]
        found[:id] if advertised == name
      end
    end

    def scan_outcome(ids)
      case ids.size
      when 1 then outcome(:passed, 'advertises its name')
      when 0 then outcome(:failed, 'no device advertises its name')
      else outcome(:unknown, "#{ids.size} devices advertise its name")
      end
    end

    # The exit code blew reports: the last "Error: exit code N" line of its output, as
    # `exec` prints it for the command that failed, else the process's own status.
    def exit_code(run)
      last = run.output.scan(EXIT_LINE).last
      last ? Integer(last.first) : run.status
    end

    def judge(run, &check)
      code = exit_code(run)
      return outcome(:unknown, (code ? "blew exited #{code}" : 'blew was killed')) unless DECIDING_EXITS.include?(code)

      check.call(run.output, code)
    end

    # The steps after the scan, on the device it found. The identifier is checked
    # because it is spliced into a blew script.
    def steps(id)
      raise Error, 'a device identifier is hexadecimal groups' unless /\A#{IDENTIFIER}\z/.match?(id)

      connect = "connect #{id}"
      [Step.new(name: 'connect and discover', argv: ['exec', "#{connect}; gatt tree"],
                check: method(:discover_outcome)),
       Step.new(name: 'write NUS RX', argv: ['exec', "#{connect}; write -r -f utf8 #{NUS_RX} erxos"],
                check: method(:write_outcome)),
       Step.new(name: 'read NUS RX, refused', argv: ['exec', "#{connect}; read #{NUS_RX}"],
                check: method(:read_outcome)),
       # The echo needs a subscription open while RX is written, which blew's exec
       # cannot do: its sub ends only at a notification. Switch to `blew nus` once
       # blew has it.
       Step.new(name: 'NUS echo', argv: nil, check: ->(_output, _code) { outcome(:unknown, 'needs blew nus') })]
    end

    def discover_outcome(output, code)
      held = code.zero? && output.upcase.include?(NUS_SERVICE)
      outcome(held ? :passed : :failed, 'the table holds NUS')
    end

    # A service with no handler answers writes Unlikely Error by design
    # (docs/design-bluetooth.md, "The `ble` facet"), so that answer says only that no
    # app serves NUS. blew gives the ATT error only as CoreBluetooth's message, and the
    # match on message text assumes an English locale.
    def write_outcome(output, code)
      return outcome(:passed, 'an app takes the write') if code.zero?
      return outcome(:unknown, 'Unlikely Error: no handler answered') if code == 5 && output.include?('Unlikely error')

      outcome(:failed, 'the write failed')
    end

    # CoreBluetooth's message for a characteristic without the read property; the
    # same English-locale assumption.
    def read_outcome(output, code)
      outcome(code == 5 && output.include?('not permitted') ? :passed : :failed, 'refuses a read of RX')
    end

    # 0 when a step passed and none failed, 1 when one failed, 3 when none passed.
    def exit_status(outcomes)
      statuses = outcomes.map(&:status)
      return 1 if statuses.include?(:failed)

      statuses.include?(:passed) ? 0 : 3
    end
  end
end
