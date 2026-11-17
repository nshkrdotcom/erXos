# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Runs test/erlang/erx_ntpd_flags_fuzz.erl, the fuzz target of ntpd's start flags
# reader, erx_ntp_core:servers/1 (docs/design-time.md, "Verification and testing"),
# on stock's emulator (ERX_ERL and ERX_ERLC), and then once with each seeded fault,
# which must fail the run with the property it breaks.

require 'open3'
require 'optparse'
require 'tmpdir'

module ErxNtpdFlagsFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_ntpd/src/erx_ntp_core.erl'
  TARGET = 'test/erlang/erx_ntpd_flags_fuzz.erl'
  Fault = Data.define(:name, :from, :to, :failure)
  FAULTS = [
    Fault.new(name: 'a reader without the 253-byte bound',
              from: 'server(Entry) when byte_size(Entry) > ?MAX_NAME -> false;', to: '',
              failure: 'entry_out_of_rule'),
    Fault.new(name: 'a reader that accepts a ninth entry',
              from: 'length(Entries) > ?MAX_SERVERS', to: 'length(Entries) > ?MAX_SERVERS + 1',
              failure: 'entry_count')
  ].freeze
  DEADLINE_SECONDS = '180'

  module_function

  def run(seed:)
    source = File.binread(File.join(ROOT, CORE))
    FAULTS.each { |fault| raise "#{CORE} lacks #{fault.from}" unless source.scan(fault.from).size == 1 }

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    FAULTS.each do |fault|
      output, status = fuzz(source.sub(fault.from) { fault.to }, seed: seed)
      abort("#{fault.name} passed:\n#{output}") if status.success? || !output.include?(fault.failure)
    end
    puts 'erx_ntp_core:servers/1 keeps the server-list rule on any flags, and each seeded fault fails'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(source, seed:)
    Dir.mktmpdir('erx-ntpd-flags-fuzz') do |work|
      core = File.join(work, File.basename(CORE))
      File.binwrite(core, source)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, core, File.join(ROOT, TARGET), stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_ntpd_flags_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxNtpdFlagsFuzz.run(seed: seed)
end
