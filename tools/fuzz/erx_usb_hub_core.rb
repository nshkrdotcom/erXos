# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_usb_hub_core's decoders, the hub's status-change bitmap and the
# hub and port status words (test/erlang/erx_usb_hub_core_fuzz.erl), compiled from source
# and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's). It runs the
# module as it is, then each seeded copy, which must fail with its marker: one whose
# bitmap reads every bit of its bytes, so a report names ports past the hub's count, and
# one that takes a port's status from the first four bytes of a longer answer.
module ErxUsbHubCoreFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated header named here is in build/gen.
  Erx::Generated.ensure(root: ROOT)
  CORE = File.join(ROOT, 'erlang/apps/erx_usb/src/erx_usb_hub_core.erl')
  TARGET = File.join(ROOT, 'test/erlang/erx_usb_hub_core_fuzz.erl')
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  Seed = Data.define(:fault, :anchor, :replacement, :marker)
  SEEDS = [
    Seed.new(fault: "a bitmap read past the hub's port count",
             anchor: '[Port || Port <- lists:seq(1, Ports), Bits band (1 bsl Port) =/= 0]',
             replacement: '[Port || Port <- lists:seq(1, 8 * Length - 1), Bits band (1 bsl Port) =/= 0]',
             marker: 'out_of_bounds'),
    Seed.new(fault: "a port's status taken from a longer answer",
             anchor: 'port_status(<<Status:16/little, Change:16/little>>, Parent) ->',
             replacement: 'port_status(<<Status:16/little, Change:16/little, _/binary>>, Parent) ->',
             marker: 'out_of_bounds')
  ].freeze
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(CORE)
    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    SEEDS.each do |planted|
      raise "seed anchor for #{planted.fault} is not unique" unless source.scan(planted.anchor).size == 1

      output, status = fuzz(source.sub(planted.anchor) { planted.replacement }, seed: seed)
      abort("#{planted.fault} passed:\n#{output}") if status.success? || !output.include?(planted.marker)
    end
    puts 'erx_usb_hub_core keeps every decoded value in bounds under fuzzing, and each seeded fault fails'
  end

  # In a directory of its own, which also takes the crash dump of a failed round. The
  # seeded copy may leave a variable unused, so nothing here compiles with -Werror.
  def fuzz(core_text, seed:)
    Dir.mktmpdir('erx-usb-hub-core-fuzz') do |work|
      core = File.join(work, File.basename(CORE)).tap { |copy| File.binwrite(copy, core_text) }
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, core, TARGET,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_usb_hub_core_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| options[:seed] = value } }.parse!
  ErxUsbHubCoreFuzz.run(seed: options.fetch(:seed))
end
