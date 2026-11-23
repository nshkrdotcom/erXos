# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of the login facet's decoder, erx_ssh_wire
# (test/erlang/erx_ssh_wire_fuzz.erl, docs/design-ssh.md "Verification"), compiled from
# source and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it
# needs no hosted build. It runs the decoder as it is, then a copy that takes a string
# before checking its length against what remains, which must fail: a length past the
# end then raises.
module ErxSshWireFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_ssh_login/src/erx_ssh_wire.erl'
  FUZZ = 'test/erlang/erx_ssh_wire_fuzz.erl'
  # The key blob's matcher, which key_blob/1 calls.
  BLOB = 'erlang/apps/erx/src/erx_boot_keys.erl'
  CHECKED = 'string(<<Length:32, Rest/binary>>) when Length =< byte_size(Rest) ->'
  UNCHECKED = 'string(<<Length:32, Rest/binary>>) ->'
  DEADLINE_SECONDS = '120'
  VERDICT = 'raised'

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    core = File.binread(File.join(ROOT, CORE))
    raise "no length check in #{CORE}" unless core.scan(CHECKED).size == 1

    output, status = fuzz(core, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(core.sub(CHECKED, UNCHECKED), seed: seed)
    abort("a string taken before its length was checked passed:\n#{output}") if status.success? || !output.include?(VERDICT)
    puts 'erx_ssh_wire takes a string only once its length fits, and the unchecked copy does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(core_text, seed:)
    Dir.mktmpdir('erx-ssh-wire-fuzz') do |work|
      core_path = File.join(work, File.basename(CORE))
      File.binwrite(core_path, core_text)
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', include, '-o', work, core_path,
                                       File.join(ROOT, BLOB), File.join(ROOT, FUZZ), stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_ssh_wire_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxSshWireFuzz.run(seed: seed)
end
