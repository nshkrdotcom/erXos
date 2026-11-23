#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz timed

require 'optparse'
require_relative '../../tools/lib/erx/fiasco_provenance'

seconds = 2
seed = 1_234_567
OptionParser.new do |flags|
  flags.on('--seconds N', Integer) { |value| seconds = value }
  flags.on('--seed N', Integer) { |value| seed = value }
end.parse!
raise Erx::Error, 'fuzz duration outside bounds' unless ARGV.empty? && seconds.between?(1, 3600)
random = Random.new(seed)
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
cases = 0
until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  payload = random.bytes(random.rand(16_385))
  if random.rand(2).zero?
    payload = "savedcmd_root.o := gcc -c root.c\nsource_root.o := root.c\ndeps_root.o := ".b + payload + "\n"
  end
  begin
    Erx::FiascoProvenance.recorded_compile(payload, object: 'root.o')
  rescue Erx::Error
    # A bounded rejection is an expected parser result.
  end
  cases += 1
end
Erx::Terminal.puts("Fiasco compiler-record fuzz passed: #{cases} cases, seed #{seed}")
