# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of the NTP codec, erx_ntp_wire:decode/1 with erx_ntp_sample:check/4
# over what it decodes (test/erlang/erx_ntp_wire_fuzz.erl), compiled from source with the
# generated ABI header the checks take their distance bound from, on stock's emulator
# (ERX_ERL and ERX_ERLC). It runs the target, then each seeded fault, which the target
# must catch (docs/design-time.md, "Verification and testing").
module ErxNtpWireFuzz
  ROOT = File.expand_path('../..', __dir__)
  WIRE = 'erlang/apps/erx/src/erx_ntp_wire.erl'
  SAMPLE = 'erlang/apps/erx/src/erx_ntp_sample.erl'
  TARGET = 'test/erlang/erx_ntp_wire_fuzz.erl'
  # The generated header named here is in build/gen.
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  Fault = Data.define(:name, :file, :from, :to, :failure)
  FAULTS = [
    Fault.new(name: 'a decode without its length check', file: WIRE,
              from: "decode(_) ->\n    {error, short}.", to: "decode(<<>>) ->\n    {error, short}.",
              failure: 'decode_raised'),
    Fault.new(name: 'checks without the distance bound', file: SAMPLE,
              from: 'require(Distance < ?ERX_CLOCK_DISTANCE_MAX_NS, distance)', to: 'require(true, distance)',
              failure: 'distance_out_of_bounds')
  ].freeze
  DEADLINE_SECONDS = '180'

  module_function

  def run(seed:)
    sources = [WIRE, SAMPLE].to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    FAULTS.each { |fault| raise "#{fault.file} lacks #{fault.from}" unless sources.fetch(fault.file).scan(fault.from).size == 1 }

    output, status = fuzz(sources, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    FAULTS.each do |fault|
      seeded = sources.merge(fault.file => sources.fetch(fault.file).sub(fault.from) { fault.to })
      output, status = fuzz(seeded, seed: seed)
      abort("#{fault.name} passed:\n#{output}") if status.success? || !output.include?(fault.failure)
    end
    puts 'erx_ntp_wire and erx_ntp_sample keep their bounds on any datagram, and each seeded fault fails'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(sources, seed:)
    Dir.mktmpdir('erx-ntp-wire-fuzz') do |work|
      paths = sources.map do |path, text|
        File.join(work, File.basename(path)).tap { |copy| File.binwrite(copy, text) }
      end
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, *paths,
                                       File.join(ROOT, TARGET), stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_ntp_wire_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxNtpWireFuzz.run(seed: seed)
end
