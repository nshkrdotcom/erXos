# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of the decoder of root's authorized_keys, erx_boot_keys
# (test/erlang/erx_boot_keys_fuzz.erl, docs/design-ssh.md "Verification"), compiled
# from source and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's),
# so it needs no hosted build. It runs the decoder as it is, then a copy that takes any
# 68 base64 characters as a key without checking the blob's layout, which must fail:
# a key that does not decode is then returned as a blob.
module ErxBootKeysFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_storage/src/erx_boot_keys.erl'
  FUZZ = 'test/erlang/erx_boot_keys_fuzz.erl'
  CHECKED = "blob(<<NameSize:32, Name:NameSize/binary, KeySize:32, _:KeySize/binary>> = Blob)\n  " \
            'when Name =:= ?ERX_SSH_ED25519_NAME_BYTES, KeySize =:= ?ERX_SSH_ED25519_KEY_SIZE ->'
  UNCHECKED = 'blob(<<_:51/binary>> = Blob) ->'
  DEADLINE_SECONDS = '120'
  VERDICT = 'not_a_key_blob'

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    core = File.binread(File.join(ROOT, CORE))
    raise "no blob layout check in #{CORE}" unless core.scan(CHECKED).size == 1

    output, status = fuzz(core, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(core.sub(CHECKED, UNCHECKED), seed: seed)
    abort("a key taken without its blob's layout checked passed:\n#{output}") if status.success? || !output.include?(VERDICT)
    puts 'erx_boot_keys returns only ssh-ed25519 key blobs, and the unchecked copy does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(core_text, seed:)
    Dir.mktmpdir('erx-boot-keys-fuzz') do |work|
      core_path = File.join(work, File.basename(CORE))
      File.binwrite(core_path, core_text)
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', include, '-o', work, core_path,
                                       File.join(ROOT, FUZZ), stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_boot_keys_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxBootKeysFuzz.run(seed: seed)
end
