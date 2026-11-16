# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_wpa_key, the EAPOL-Key codec (test/erlang/erx_wpa_key_fuzz.erl,
# docs/design-wifi.md, "Untrusted input"): mutated frames and key data from a hostile
# access point fail with an error, never a crash. Compiled from source with the ABI
# generator's erx_abi_packed and erx_abi_translations, which it writes into build/gen,
# and run on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's). It runs the codec as
# it is, then with the key data length's bound by the EAPOL body dropped, which the
# target must find as a crash.
module ErxWpaKeyFuzz
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  CODEC = File.join(ROOT, 'erlang/apps/erx_wifi/src/erx_wpa_key.erl')
  GENERATED = File.join(Erx::Generated::OUTPUT, 'erlang/apps/erx/src/generated')
  SOURCES = [File.join(GENERATED, 'erx_abi_packed.erl'), File.join(GENERATED, 'erx_abi_translations.erl'),
             File.join(ROOT, 'erlang/apps/erx_wifi/src/erx_wpa_kdf.erl'),
             File.join(ROOT, 'test/erlang/erx_wpa_key_fuzz.erl')].freeze
  INCLUDE = File.join(Erx::Generated::OUTPUT, 'erlang/apps/erx/include')
  BOUND = "    require(?ERX_EAPOL_KEY_SIZE + DataLength =< ?EAPOL_HEADER + BodyLength, data_length),\n"
  DEADLINE_SECONDS = '240'

  module_function

  def run(seed:)
    source = File.binread(CODEC)
    raise "no key data length bound in #{CODEC}" unless source.scan(BOUND).size == 1

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(source.sub(BOUND, ''), seed: seed)
    abort("dropping the key data length's bound passed:\n#{output}") if status.success? || !output.include?('crash')
    puts 'erx_wpa_key refuses every mutated frame and key data without a crash, and finds the dropped bound'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(codec_text, seed:)
    Dir.mktmpdir('erx-wpa-key-fuzz') do |work|
      codec_path = File.join(work, 'erx_wpa_key.erl')
      File.binwrite(codec_path, codec_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, codec_path, *SOURCES,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_wpa_key_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| options[:seed] = value } }.parse!
  ErxWpaKeyFuzz.run(seed: options.fetch(:seed))
end
