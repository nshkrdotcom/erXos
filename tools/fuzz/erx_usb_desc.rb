# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=600

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_usb_desc, the USB descriptor decoder, with the claim's property
# test (test/erlang/erx_usb_desc_fuzz.erl), compiled from source with erx_usb_claim and
# the cases whose encoders and fixtures it draws on, and run alone on stock's emulator
# (ERX_ERL and ERX_ERLC, the oracle's). It runs the modules as they are, then each seeded
# copy, which must fail with its marker: one without the bound on wTotalLength, one
# without the bound on a hub's ports, one that admits an endpoint numbered 0, and one
# whose claim admits a payload past its queue block's buffer. Each shows the generated
# inputs cross that bound and the target sees a value past it.
module ErxUsbDescFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated header named here is in build/gen.
  Erx::Generated.ensure(root: ROOT)
  DESC = 'erlang/apps/erx_usb/src/erx_usb_desc.erl'
  CLAIM = 'erlang/apps/erx_usb/src/erx_usb_claim.erl'
  SOURCES = %w[erx_hid_desc_tests erx_usb_desc_tests erx_usb_desc_fuzz]
            .map { |name| File.join(ROOT, "test/erlang/#{name}.erl") }.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  Seed = Data.define(:fault, :file, :anchor, :replacement, :marker)
  SEEDS = [
    Seed.new(fault: 'wTotalLength left unbounded', file: DESC,
             anchor: 'check(Total =< ?ERX_USB_CONFIG_MAX, descriptor_too_long),',
             replacement: 'check(Total >= 0, descriptor_too_long),',
             marker: 'out_of_bounds'),
    Seed.new(fault: "a hub's ports left unbounded", file: DESC,
             anchor: 'check(Ports =< ?ERX_USB_HUB_PORTS_MAX, too_many_ports),',
             replacement: 'check(Ports >= 0, too_many_ports),',
             marker: 'out_of_bounds'),
    Seed.new(fault: 'an endpoint numbered 0 admitted', file: DESC,
             anchor: 'check(Address band ?ERX_USB_ENDPOINT_NUMBER_MASK =/= 0, endpoint_zero),',
             replacement: 'check(is_integer(Address), endpoint_zero),',
             marker: 'out_of_bounds'),
    Seed.new(fault: "a payload admitted past its queue block's buffer", file: CLAIM,
             anchor: 'check(Payload =< buffer(Type), endpoint_too_large),',
             replacement: 'check(Payload > 0 orelse is_function(fun buffer/1), endpoint_too_large),',
             marker: 'out_of_bounds')
  ].freeze
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    sources = [DESC, CLAIM].to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    output, status = fuzz(sources, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    SEEDS.each do |planted|
      source = sources.fetch(planted.file)
      raise "seed anchor for #{planted.fault} is not unique" unless source.scan(planted.anchor).size == 1

      seeded = sources.merge(planted.file => source.sub(planted.anchor) { planted.replacement })
      output, status = fuzz(seeded, seed: seed)
      abort("#{planted.fault} passed:\n#{output}") if status.success? || !output.include?(planted.marker)
    end
    puts 'erx_usb_desc and erx_usb_claim keep every bound under fuzzing, and each seeded fault fails'
  end

  # In a directory of its own, which also takes the crash dump of a failed round. The
  # seeded copy may leave a variable unused, so nothing here compiles with -Werror.
  def fuzz(sources, seed:)
    Dir.mktmpdir('erx-usb-desc-fuzz') do |work|
      paths = sources.map do |path, text|
        File.join(work, File.basename(path)).tap { |copy| File.binwrite(copy, text) }
      end
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, *paths, *SOURCES,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_usb_desc_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| options[:seed] = value } }.parse!
  ErxUsbDescFuzz.run(seed: options.fetch(:seed))
end
