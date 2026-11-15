# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_hid_desc, the HID report descriptor's parser
# (test/erlang/erx_hid_desc_fuzz.erl), compiled from source with the cases whose item
# encoders and fixtures it draws on, and run alone on stock's emulator (ERX_ERL and
# ERX_ERLC, the oracle's). It runs the module as it is, then each seeded copy, which must
# fail with its marker: one without the 32-bit bound on an input field, one without the
# bound on an input report's length, and one without the bound on named report ids. Each
# shows the generated descriptors cross that bound and the target sees a layout past it.
module ErxHidDescFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated header named here is in build/gen.
  Erx::Generated.ensure(root: ROOT)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_usb/src/erx_hid_desc.erl')
  SOURCES = %w[erx_hid_desc_tests erx_hid_desc_fuzz].map { |name| File.join(ROOT, "test/erlang/#{name}.erl") }.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  Seed = Data.define(:fault, :anchor, :replacement, :marker)
  SEEDS = [
    Seed.new(fault: 'an input field taken wider than 32 bits',
             anchor: 'true when Size > ?ERX_HID_FIELD_BITS_MAX ->',
             replacement: 'true when Size < 0 ->',
             marker: 'out_of_bounds'),
    Seed.new(fault: "an input report's length left unbounded",
             anchor: 'check(Largest + IdByte =< ?ERX_HID_INPUT_REPORT_MAX, report_too_large),',
             replacement: 'check(IdByte >= 0, report_too_large),',
             marker: 'out_of_bounds'),
    Seed.new(fault: 'named report ids left unbounded',
             anchor: 'check(Named orelse length(Ids) + 1 < ?ERX_HID_REPORT_IDS_MAX, too_many_report_ids),',
             replacement: 'check(Named orelse is_list(Ids), too_many_report_ids),',
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
    puts 'erx_hid_desc keeps every bound under fuzzing, and each seeded fault fails'
  end

  # In a directory of its own, which also takes the crash dump of a failed round. The
  # seeded copy may leave a variable unused, so nothing here compiles with -Werror.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-hid-desc-fuzz') do |work|
      module_path = File.join(work, 'erx_hid_desc.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, module_path, *SOURCES,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_hid_desc_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| options[:seed] = value } }.parse!
  ErxHidDescFuzz.run(seed: options.fetch(:seed))
end
