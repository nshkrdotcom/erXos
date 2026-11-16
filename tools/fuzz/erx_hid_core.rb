# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_hid_core, the HID function's fold (test/erlang/erx_hid_core_fuzz.erl),
# compiled from source with the parser whose layouts it folds against, the descriptor's
# cases and fuzz target it draws layouts from, and the generated translations and input
# record modules it calls, and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the
# oracle's). It runs the module as it is, then each seeded copy, which must fail with its
# marker: one that normalizes a position without clamping it to its logical range, and
# one that hands on wheel steps without their record range; each shows a device's value
# outside its declared range reaches a record only through the clamp.
module ErxHidCoreFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated header named here is in build/gen.
  Erx::Generated.ensure(root: ROOT)
MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_usb/src/erx_hid_core.erl')
GENERATED = File.join(ROOT, 'build/gen/erlang/apps/erx/src/generated')
SOURCES = [File.join(ROOT, 'erlang/apps/erx_usb/src/erx_hid_desc.erl'),
           *%w[erx_abi_translations erx_input_codec].map { |name| File.join(GENERATED, "#{name}.erl") },
           *%w[erx_hid_desc_tests erx_hid_desc_fuzz erx_hid_core_fuzz].map { |name| File.join(ROOT, "test/erlang/#{name}.erl") }].freeze
INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
Seed = Data.define(:fault, :anchor, :replacement, :marker)
SEEDS = [
  Seed.new(fault: 'a position normalized without its clamp',
           anchor: 'R#report{x = erx_input_codec:axis(V, Min, Max)}',
           replacement: 'R#report{x = V}',
           marker: 'out_of_bounds'),
  Seed.new(fault: 'wheel steps handed on without their record range',
           anchor: 'wheel(Steps) -> [{wheel, erx_input_codec:wheel(Steps)}].',
           replacement: 'wheel(Steps) -> [{wheel, Steps}].',
           marker: 'out_of_bounds')
].freeze
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    SEEDS.each do |planted|
      raise "seed anchor for #{planted.fault} is not unique" unless source.scan(planted.anchor).size == 1

      output, status = fuzz(source.sub(planted.anchor) { planted.replacement }, seed: seed)
      abort("#{planted.fault} passed:\n#{output}") if status.success? || !output.include?(planted.marker)
    end
    puts 'erx_hid_core keeps every record in bounds under fuzzing, and each seeded fault fails'
  end

  # In a directory of its own, which also takes the crash dump of a failed round. The
  # seeded copy may leave a variable unused, so nothing here compiles with -Werror.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-hid-core-fuzz') do |work|
      module_path = File.join(work, 'erx_hid_core.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, module_path, *SOURCES,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_hid_core_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| options[:seed] = value } }.parse!
  ErxHidCoreFuzz.run(seed: options.fetch(:seed))
end
