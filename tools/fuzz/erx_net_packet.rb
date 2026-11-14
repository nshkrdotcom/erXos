#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Runs test/erlang/erx_net_packet_fuzz.erl, the fuzz target of a TCP socket process's
# packet framing (docs/design-network-stack.md, "The socket process"), for one target,
# against the sources as they are and against a copy with the target's seeded fault,
# which must fail it:
#   decode  erx_net_packet:decode/3, with a line's packet_size dropped;
#   core    erx_gen_tcp_core, which drops the bytes held after each packet it delivers.

require 'open3'
require 'optparse'
require 'tmpdir'

module ErxNetPacketFuzz
  ROOT = File.expand_path('../..', __dir__)
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_net_packet_fuzz.erl')
  DEADLINE_SECONDS = '300'
  PASSED = /^fuzz: \d+ inputs ok$/

  PACKET = 'erlang/apps/erx_net_client/src/erx_net_packet.erl'
  CORE = 'erlang/apps/erx_net_client/src/erx_gen_tcp_core.erl'
  SOURCES = [PACKET, CORE].freeze

  Fault = Data.define(:what, :source, :anchor, :replacement, :marker)

  FAULTS = {
    'decode' => Fault.new(what: 'a line framing without packet_size', source: PACKET,
                          anchor: '[{packet_size, Longest}, {line_length, Buffer}]',
                          replacement: '[{line_length, Buffer}]', marker: 'decode_differs'),
    'core' => Fault.new(what: 'a core that drops what follows a packet', source: CORE,
                        anchor: '{ok, Data, C#core{held = [Left || Left =/= []], held_bytes = Bytes - (byte_size(First) - byte_size(Rest)),',
                        replacement: '{ok, Data, C#core{held = [], held_bytes = 0,', marker: 'core_')
  }.freeze

  module_function

  def run(target:, seed:)
    fault = FAULTS.fetch(target)
    texts = SOURCES.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    output, status = fuzz(texts, target: target, seed: seed)
    abort(output) unless status.success? && output.match?(PASSED)
    raise "no #{fault.anchor} in #{fault.source}" unless texts.fetch(fault.source).include?(fault.anchor)

    faulty = texts.merge(fault.source => texts.fetch(fault.source).sub(fault.anchor) { fault.replacement })
    output, = fuzz(faulty, target: target, seed: seed)
    abort("#{fault.what} passed:\n#{output}") if output.match?(PASSED) || !output.include?(fault.marker)
    puts "erx_net_packet #{target}: every input passed, and #{fault.what} failed with #{fault.marker}"
  end

  # In a directory of its own, which also takes the crash dump of a failed run.
  def fuzz(texts, target:, seed:)
    Dir.mktmpdir('erx-net-packet-fuzz') do |work|
      paths = texts.map { |path, text| File.join(work, File.basename(path)).tap { |copy| File.binwrite(copy, text) } }
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, *paths, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_net_packet_fuzz', 'run', target, seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  target = nil
  seed = 1
  OptionParser.new do |flags|
    flags.on('--target NAME', ErxNetPacketFuzz::FAULTS.keys) { |value| target = value }
    flags.on('--seed N', Integer) { |value| seed = value }
  end.parse!
  abort("usage: #{$PROGRAM_NAME} --target #{ErxNetPacketFuzz::FAULTS.keys.join('|')} [--seed N]") unless target
  ErxNetPacketFuzz.run(target: target, seed: seed)
end
