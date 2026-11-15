# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_tty_link, the tty's side of the messages between a session's tty
# and its master, whose messages from another domain are untrusted (docs/design-live.md,
# "Between domains"). It is compiled from source and run alone on stock's emulator (ERX_ERL
# and ERX_ERLC, the oracle's), as the module is and then as copies that each break one
# guarantee, each of which must fail with the property that guards it: that shows the runs
# reach the bounds of the messages from the master and that the checks catch a break.
module ErxTtyLinkFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_session/src/erx_tty_link.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_tty_link_fuzz.erl')
  # erx_tty_link takes its room from erx_tty:master_room/0.
  TTY_SOURCE = File.join(ROOT, 'erlang/apps/erx_session/src/erx_tty.erl')
  # A broken guarantee: the text that keeps it, what replaces it, and the property that must
  # then fail, as the target names it.
  Seed = Data.define(:text, :broken, :property)
  SEEDED = {
    'the 4 KiB input bound' => Seed.new(text: 'when is_binary(Bytes), byte_size(Bytes) =< ?MAX_INPUT ->',
                                        broken: 'when is_binary(Bytes) ->',
                                        property: 'input_over_bound'),
    'the window size bounds' => Seed.new(text: 'when is_integer(Rows), Rows >= 1, Rows =< ?MAX_SIDE,',
                                         broken: 'when is_integer(Rows), Rows >= 0,',
                                         property: 'size_out_of_range'),
    'the 4 KiB held bound' => Seed.new(text: 'Room = ?MAX_HELD - held(L),', broken: 'Room = 2 * ?MAX_HELD - held(L),',
                                       property: 'held_over_bound'),
    'the output numbering' => Seed.new(text: 'held = <<>>, next = N + 1}', broken: 'held = <<>>, next = N + 2}',
                                       property: 'numbering'),
    'the answer to a write held whole' => Seed.new(text: '<<>> -> fill(Next#link{waiting = Rest}, [done(Writer) | Done]);',
                                                   broken: '<<>> -> fill(Next#link{waiting = Rest}, Done);',
                                                   property: 'write_unanswered'),
    'output held while stopped' => Seed.new(text: 'held = Held, next = N, stopped = false})',
                                            broken: 'held = Held, next = N})',
                                            property: 'output_while_stopped'),
    'a flush dropping what is held' => Seed.new(text: '{Done, L#link{held = <<>>, waiting = queue:new(), unowned = 0}}.',
                                                broken: '{Done, L#link{waiting = queue:new(), unowned = 0}}.',
                                                property: 'sent_not_written'),
    'room/1 counting the outstanding output' => Seed.new(text: '{?MAX_HELD - held(L), outstanding_size(Outstanding), Stopped}',
                                                         broken: '{?MAX_HELD - held(L), byte_size(L#link.held), Stopped}',
                                                         property: 'room_wrong'),
    'room/1 naming the outstanding output' => Seed.new(text: '{?MAX_HELD - held(L), outstanding_size(Outstanding), Stopped}',
                                                       broken: '{?MAX_HELD - held(L), 0, Stopped}',
                                                       property: 'room_wrong')
  }.freeze
  DEADLINE_SECONDS = '60'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    output, status = fuzz(source, seed: seed)
    abort(output[0, 4000]) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
    SEEDED.each do |guarantee, planted|
      raise "no #{guarantee} (#{planted.text}) in #{MODULE_SOURCE}" unless source.include?(planted.text)

      output, status = fuzz(source.sub(planted.text, planted.broken), seed: seed)
      unless !status.success? && output.include?("fuzz_failure,#{planted.property}")
        abort("erx_tty_link without #{guarantee} did not fail #{planted.property}:\n#{output[0, 4000]}")
      end
    end
    puts "erx_tty_link keeps its guarantees, and copies without #{SEEDED.keys.join(', ')} do not"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-tty-link-fuzz') do |work|
      module_path = File.join(work, 'erx_tty_link.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-o', work,
                                       module_path, TTY_SOURCE, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_tty_link_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxTtyLinkFuzz.run(seed: seed)
end
