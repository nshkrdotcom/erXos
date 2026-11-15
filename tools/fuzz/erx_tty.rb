# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_tty's set/2, size/3 and input/2, the line discipline's
# readers of a program's termios, a master's window size and its bytes
# (docs/design-live.md, "The tty"). It is compiled from source and run alone on
# stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), as the module is and
# then as copies that each break one guarantee, each of which must fail with
# the property that guards it.
module ErxTtyFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_session/src/erx_tty.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_tty_fuzz.erl')
  # A broken guarantee: the text that keeps it, what replaces it, and the
  # property that must then fail, as the target names it.
  Seed = Data.define(:text, :broken, :property)
  SEEDED = {
    'the 4 KiB input bound' => Seed.new(text: 'Held > ?MAX_INPUT ->', broken: 'Held > 2 * ?MAX_INPUT ->',
                                        property: 'input_over_bound'),
    'the flag tables' => Seed.new(text: 'case lists:member(Flag, Table) of', broken: 'case is_atom(Flag) of',
                                  property: 'invalid_accepted'),
    'the character range' => Seed.new(text: 'Value =< 255 -> ok;', broken: 'Value =< 1 bsl 16 -> ok;',
                                      property: 'invalid_accepted')
  }.freeze
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
    SEEDED.each do |guarantee, planted|
      raise "no #{guarantee} (#{planted.text}) in #{MODULE_SOURCE}" unless source.include?(planted.text)

      output, status = fuzz(source.sub(planted.text, planted.broken), seed: seed)
      unless !status.success? && output.include?("fuzz_failure,#{planted.property}")
        abort("erx_tty without #{guarantee} did not fail #{planted.property}:\n#{output[0, 4000]}")
      end
    end
    puts "erx_tty keeps its invariants, and copies without #{SEEDED.keys.join(', ')} do not"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-tty-fuzz') do |work|
      module_path = File.join(work, 'erx_tty.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-o', work,
                                       module_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_tty_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxTtyFuzz.run(seed: seed)
end
