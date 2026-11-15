# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_tty's set/2, size/3 and input/2, the line discipline's
# readers of a program's termios, a master's window size and its bytes, and of
# erx_abi_termios's decode/1, the program protocol's reader of a struct termios
# (docs/design-live.md, "The tty"). The two modules are compiled from source,
# erx_abi_termios from build/gen, and run alone on stock's emulator (ERX_ERL and
# ERX_ERLC, the oracle's), as they are and then as copies that each break one
# guarantee, each of which must fail with the property that guards it.
module ErxTtyFuzz
  ROOT = File.expand_path('../..', __dir__)
  # erx_abi_termios is generated into build/gen from abi/termios.txt.
  Erx::Generated.ensure(root: ROOT)
  SOURCES = { 'erx_tty.erl' => File.join(ROOT, 'erlang/apps/erx_session/src/erx_tty.erl'),
              'erx_abi_termios.erl' => File.join(ROOT, 'build/gen/erlang/apps/erx/src/generated/erx_abi_termios.erl') }
            .freeze
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_tty_fuzz.erl')
  # A broken guarantee: the module that keeps it, the text that keeps it,
  # what replaces it, and the property that must then fail, as the target
  # names it.
  Seed = Data.define(:module_file, :text, :broken, :property)
  SEEDED = {
    'the 4 KiB input bound' => Seed.new(module_file: 'erx_tty.erl', text: 'Held > ?MAX_INPUT ->',
                                        broken: 'Held > 2 * ?MAX_INPUT ->', property: 'input_over_bound'),
    'the flag tables' => Seed.new(module_file: 'erx_tty.erl', text: 'case lists:member(Flag, Table) of',
                                  broken: 'case is_atom(Flag) of', property: 'invalid_accepted'),
    'the character range' => Seed.new(module_file: 'erx_tty.erl', text: 'Value =< 255 -> ok;',
                                      broken: 'Value =< 1 bsl 16 -> ok;', property: 'invalid_accepted'),
    # An echo that skips emit/3 and the room it keeps.
    'the echo bound' => Seed.new(module_file: 'erx_tty.erl', text: '            emit(Bytes, Actions, Tty1);',
                                 broken: '            {[{echo, Bytes} | Actions], Tty1};',
                                 property: 'echo_over_bound'),
    # Input that goes on past a signal key.
    'the stop at a signal key' => Seed.new(module_file: 'erx_tty.erl',
                                           text: '{[{signal, _} | _] = Actions, Tty} -> {Actions, Rest, Tty};',
                                           broken: '', property: 'went_past_a_signal'),
    # Echoes joined out of order, which a call of one byte does not show.
    'joined echoes' => Seed.new(module_file: 'erx_tty.erl',
                                text: 'merge([{echo, <<A/binary, B/binary>>} | Rest]);',
                                broken: 'merge([{echo, <<B/binary, A/binary>>} | Rest]);',
                                property: 'chunked_differs'),
    "the codec's byte range" => Seed.new(module_file: 'erx_abi_termios.erl', text: 'Value =< 16#ff.',
                                         broken: 'Value =< 16#fff.', property: 'codec_invalid_accepted')
  }.freeze
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    sources = SOURCES.transform_values { |path| File.binread(path) }
    output, status = fuzz(sources, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
    SEEDED.each do |guarantee, planted|
      source = sources.fetch(planted.module_file)
      raise "no #{guarantee} (#{planted.text}) in #{planted.module_file}" unless source.include?(planted.text)

      output, status = fuzz(sources.merge(planted.module_file => source.sub(planted.text, planted.broken)), seed: seed)
      unless !status.success? && output.include?("fuzz_failure,#{planted.property}")
        abort("#{planted.module_file} without #{guarantee} did not fail #{planted.property}:\n#{output[0, 4000]}")
      end
    end
    puts "erx_tty and erx_abi_termios keep their invariants, and copies without #{SEEDED.keys.join(', ')} do not"
  end

  # In a directory of its own, which also takes the crash dump of a failed
  # round; sources maps each module's file name to its text.
  def fuzz(sources, seed:)
    Dir.mktmpdir('erx-tty-fuzz') do |work|
      paths = sources.map do |name, text|
        File.join(work, name).tap { |path| File.binwrite(path, text) }
      end
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-o', work,
                                       *paths, TARGET_SOURCE, stdin_data: '')
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
