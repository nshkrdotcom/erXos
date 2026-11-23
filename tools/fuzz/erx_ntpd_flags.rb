# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=600

# Runs test/erlang/erx_ntpd_flags_fuzz.erl, the fuzz target of ntpd's start flags
# reader, erx_ntp_core:servers/1, and the server-list rule it applies,
# erx_ntp_exchange:servers/1, with the host-name rule that one applies,
# erx_host_name:host_name/1 (docs/design-time.md, "Verification and testing"),
# on stock's emulator (ERX_ERL and ERX_ERLC), and then once with each seeded fault,
# which must fail the run with the property it breaks.

require 'open3'
require 'optparse'
require 'tmpdir'

module ErxNtpdFlagsFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_ntpd/src/erx_ntp_core.erl'
  # The seeded faults go into the rules' modules: the server-list rule, which ntpd's core
  # and ntpctl share, and the host-name rule it applies, which the resolver's check and
  # the DHCP client share too.
  RULE = 'erlang/apps/erx/src/erx_ntp_exchange.erl'
  HOST_NAME = 'erlang/apps/erx_net_client/src/erx_host_name.erl'
  TARGET = 'test/erlang/erx_ntpd_flags_fuzz.erl'
  Fault = Data.define(:name, :source, :from, :to, :failure)
  FAULTS = [
    Fault.new(name: 'a host-name rule without the 253-byte bound', source: HOST_NAME,
              from: 'host_name(Name) when is_binary(Name), byte_size(Name) =< ?MAX_NAME ->',
              to: 'host_name(Name) when is_binary(Name) ->', failure: 'entry_out_of_rule'),
    Fault.new(name: 'a reader that accepts a ninth entry', source: RULE,
              from: 'length(Names) =< ?MAX_SERVERS', to: 'length(Names) =< ?MAX_SERVERS + 1',
              failure: 'entry_count')
  ].freeze
  DEADLINE_SECONDS = '180'

  module_function

  def run(seed:)
    sources = [RULE, HOST_NAME].to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    FAULTS.each do |fault|
      raise "#{fault.source} lacks #{fault.from}" unless sources.fetch(fault.source).scan(fault.from).size == 1
    end

    output, status = fuzz(sources, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    FAULTS.each do |fault|
      faulty = sources.fetch(fault.source).sub(fault.from) { fault.to }
      output, status = fuzz(sources.merge(fault.source => faulty), seed: seed)
      abort("#{fault.name} passed:\n#{output}") if status.success? || !output.include?(fault.failure)
    end
    puts 'erx_ntp_core:servers/1 keeps the server-list rule on any flags, and each seeded fault fails'
  end

  # In a directory of its own, which also takes the crash dump of a failed round. sources
  # maps each rule module's root-relative path to the text compiled for it.
  def fuzz(sources, seed:)
    Dir.mktmpdir('erx-ntpd-flags-fuzz') do |work|
      written = sources.map do |path, text|
        File.join(work, File.basename(path)).tap { |copy| File.binwrite(copy, text) }
      end
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, *written, File.join(ROOT, CORE),
                                       File.join(ROOT, TARGET), stdin_data: '')
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
