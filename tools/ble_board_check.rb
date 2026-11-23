#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Runs the scripted part of the Bluetooth board checklist
# (docs/design-bluetooth.md, "On the board") from a macOS host against a board
# that advertises under --name, through blew, a macOS Bluetooth LE command-line
# tool on the PATH. Each step is one blew run on a connection of its own, so
# every step after the first also checks a reconnection. CoreBluetooth keeps
# GAP's and GATT's services to itself, so the steps work on Nordic's UART
# service (abi/gatt/nus.txt). Each step prints passed, failed, or unknown:
# unknown when blew ran out of time, or when what the step needs (the echo
# package of decision 7, a blew command) is missing, never a guess. Logs of
# every blew run go in --logs. Exits 0 when no step failed.
#
#   ruby tools/ble_board_check.rb --name erxos --logs DIR

require 'optparse'
require_relative 'lib/erx/runner'

module BleBoardCheck
  NUS_SERVICE = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E'
  NUS_RX = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E'

  # A step's blew arguments after the global options (none for a step blew
  # cannot run yet), and its verdict on blew's output and exit.
  Step = Data.define(:name, :argv, :verdict)
  Outcome = Data.define(:status, :detail)

  module_function

  def steps(name)
    connect = "connect -n #{name}"
    [Step.new(name: 'scan', argv: ['scan', '-n', name],
              verdict: ->(out, ok) { verdict(ok && out.include?("name=#{name}"), 'advertises its name') }),
     Step.new(name: 'connect and discover', argv: ['exec', "#{connect}; gatt tree"],
              verdict: ->(out, ok) { verdict(ok && out.upcase.include?(NUS_SERVICE), 'the table holds NUS') }),
     Step.new(name: 'write NUS RX', argv: ['exec', "#{connect}; write -r -f utf8 #{NUS_RX} erxos"],
              verdict: method(:write_verdict)),
     Step.new(name: 'read NUS RX, refused', argv: ['exec', "#{connect}; read #{NUS_RX}"],
              verdict: ->(out, ok) { verdict(!ok && out.include?('not permitted'), 'refuses a read of RX') }),
     # The echo needs a subscription open while RX is written, which blew's
     # exec cannot do: its sub ends only at a notification. Switch to `blew
     # nus` once blew has it.
     Step.new(name: 'NUS echo', argv: nil,
              verdict: ->(_out, _ok) { Outcome.new(status: :unknown, detail: 'needs blew nus') })]
  end

  def verdict(held, what) = Outcome.new(status: held ? :passed : :failed, detail: what)

  # A service with no handler answers writes Unlikely Error by design
  # (docs/design-bluetooth.md, "The `ble` facet"), so that answer says only that no
  # app serves NUS.
  def write_verdict(out, ok)
    return Outcome.new(status: :unknown, detail: 'Unlikely Error: no app serves NUS') if out.include?('Unlikely error')

    verdict(ok, 'an app takes the write')
  end

  def run(step, runner:, timeout:)
    return step.verdict.call('', false) unless step.argv

    record = runner.run(['blew', '--timeout', timeout.to_s, '--out', 'kv', *step.argv],
                        name: "ble-#{step.name.downcase.tr(' ,', '-')}", deadline: timeout * 3)
    step.verdict.call(File.read(record.fetch('log')), true)
  rescue Erx::CommandError => error
    return Outcome.new(status: :unknown, detail: 'blew ran out of time') if error.result.fetch('state') == 'timed_out'

    step.verdict.call(File.read(error.result.fetch('log')), false)
  end
end

USAGE = 'usage: ruby tools/ble_board_check.rb --name NAME --logs DIR [--timeout SECS]'
options = { timeout: 15 }
begin
  OptionParser.new(USAGE) do |flags|
    flags.on('--name NAME', 'the name the board advertises') { |value| options[:name] = value }
    flags.on('--logs DIR', 'where the logs of the blew runs go') { |value| options[:logs] = File.expand_path(value) }
    flags.on('--timeout SECS', Integer, 'blew\'s timeout for each step') { |value| options[:timeout] = value }
  end.parse!
rescue OptionParser::ParseError => error
  warn("#{error.message}\n#{USAGE}")
  exit 2
end
unless options[:name] && options[:logs] && ARGV.empty?
  warn(USAGE)
  exit 2
end

runner = Erx::Runner.new(owner_root: File.dirname(options[:logs]), log_dir: options[:logs])
outcomes = BleBoardCheck.steps(options[:name]).map do |step|
  BleBoardCheck.run(step, runner: runner, timeout: options[:timeout]).tap do |outcome|
    puts "#{outcome.status}: #{step.name} (#{outcome.detail})"
  end
end
exit(outcomes.any? { |outcome| outcome.status == :failed } ? 1 : 0)
