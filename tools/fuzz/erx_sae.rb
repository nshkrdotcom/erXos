# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_sae, SAE's exchange (test/erlang/erx_sae_fuzz.erl,
# docs/design-wifi.md, "Untrusted input"): mutated commits, confirms and token requests
# from a hostile access point are dropped, end the exchange or are taken as erx_sae's
# contract says, never a crash. Its seeds are the genuine frames of
# test/erlang/erx_sae_peer.erl's access point, made at run time. Compiled from source
# with the ABI generator's include and modules, which it writes into build/gen, and run
# on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's). It runs erx_sae as it is,
# then with each of two seeded faults, the extension element's length bound by the frame
# dropped, which the target must find as a crash, and the reflection check removed.
module ErxSaeFuzz
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  SAE = File.join(ROOT, 'erlang/apps/erx_wifi/src/erx_sae.erl')
  GENERATED = File.join(Erx::Generated::OUTPUT, 'erlang/apps/erx/src/generated')
  SOURCES = [File.join(GENERATED, 'erx_abi_packed.erl'), File.join(GENERATED, 'erx_abi_translations.erl'),
             File.join(ROOT, 'erlang/apps/erx_wifi/src/erx_wifi_keys.erl'),
             File.join(ROOT, 'erlang/apps/erx_wifi/src/erx_wpa_kdf.erl'),
             File.join(ROOT, 'test/erlang/erx_sae_peer.erl'),
             File.join(ROOT, 'test/erlang/erx_sae_fuzz.erl')].freeze
  INCLUDE = File.join(Erx::Generated::OUTPUT, 'erlang/apps/erx/include')
  # Each seeded fault: the text replaced in erx_sae, its replacement, and what the
  # failed run must print, a crash for the dropped bound and the broken property for
  # the reflection check removed.
  FAULTS = [
    ["  when Length >= 1, byte_size(Rest) >= Length - 1 ->\n", "  when Length >= 1 ->\n", '{crash,'],
    ['not reflects(Peer, Own) orelse', 'true orelse', '{commit_not_reflected,']
  ].freeze
  DEADLINE_SECONDS = '240'

  module_function

  def run(seed:)
    source = File.binread(SAE)
    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, #\{/)
    puts output
    FAULTS.each do |anchor, replacement, finding|
      raise "#{anchor.strip} is not once in #{SAE}" unless source.scan(anchor).size == 1

      output, status = fuzz(source.sub(anchor) { replacement }, seed: seed)
      abort("replacing #{anchor.strip} passed:\n#{output}") if status.success? || !output.include?(finding)
    end
    puts 'erx_sae keeps its contract on every mutated frame without a crash, and finds both seeded faults'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(sae_text, seed:)
    Dir.mktmpdir('erx-sae-fuzz') do |work|
      sae_path = File.join(work, 'erx_sae.erl')
      File.binwrite(sae_path, sae_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, sae_path, *SOURCES,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_sae_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| options[:seed] = value } }.parse!
  ErxSaeFuzz.run(seed: options.fetch(:seed))
end
