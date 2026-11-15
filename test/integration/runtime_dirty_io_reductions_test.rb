# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/oracle'
require_relative '../../tools/lib/erx/runtime'

# A call on a dirty I/O scheduler charges its caller its elapsed time in reductions, through
# erts_time2reds as on a dirty CPU scheduler (docs/design-runtime.md, NIFs and blocking), and
# the scheduler's idle time before the call is not charged (test/fixtures/dirty_io_reductions_probe.erl).
# Stock OTP 29.1.2 charges such a call one reduction, whatever it took. erXos loads only the
# NIFs linked into its runtime, so the probe calls erts_debug's dirty I/O test BIF, which runs
# through the dirty scheduler's loop and its one charge exactly as a dirty NIF does.
#
# `make check-runtime-hosted` builds the runtime and runs this. It is excused from
# `make check`, which does not build the runtime. With no runtime, or one older than the
# tree, it fails: nothing is skipped.
class RuntimeDirtyIoReductionsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OUTPUT = Erx::Runtime.output(root: ROOT)
  PROBE = 'dirty_io_reductions_probe'
  # Four reductions a microsecond (erts_time2reds) over the probe's 100 ms call.
  CALL_REDUCTIONS_MIN = 400_000
  # The idle case's short call, with 250 ms of room for a loaded host; its 500 ms of idle time
  # would be 2,000,000.
  IDLE_REDUCTIONS_MAX = 1_000_000
  # The probe takes under a second; the budget is a boot on a loaded host.
  BUDGET_SECONDS = 60
  COMPILE_SECONDS = 120

  # Each test reads the hosted build, so it runs holding the runtime tree's lock
  # shared, and a build waits for it (Runtime.reading).
  def run = Erx::Runtime.reading(root: ROOT) { super }

  def setup = Erx::Runtime.check_current(root: ROOT)

  def test_a_dirty_io_call_is_charged_its_elapsed_time_and_not_the_idle_time
    charged = probe
    assert_operator charged.fetch('sleep'), :>=, CALL_REDUCTIONS_MIN, 'a call sleeping in the kernel'
    assert_operator charged.fetch('busy'), :>=, CALL_REDUCTIONS_MIN, 'a call polling the clock'
    assert_operator charged.fetch('idle'), :<, IDLE_REDUCTIONS_MAX, "the scheduler's idle time"
  end

  private

  # The reductions of each of the probe's cases, by case name.
  def probe
    load_probe = "{module, #{PROBE}} = code:load_binary(#{PROBE}, \"#{PROBE}\", " \
                 "base64:decode(string:trim(io:get_line(\"\"))))"
    environment = Erx::Oracle::CLEAN_ERLANG_ENV.merge('ERL_CRASH_DUMP_BYTES' => '0')
    output, status = Open3.capture2e(environment, 'gtimeout', '-k', '10', BUDGET_SECONDS.to_s, OUTPUT.beam,
                                     OUTPUT.archive, '-noshell', '-eval', "#{load_probe}, #{PROBE}:main().",
                                     stdin_data: "#{compiled_probe}\n")
    assert status.success?, "exit #{status.exitstatus.inspect} (124 is the deadline), " \
                            "signal #{status.termsig.inspect}\n#{output}"
    puts output.scan(/^dirty io reductions: .*$/)
    output.scan(/^dirty io reductions: (\w+) (\d+)$/).to_h { |name, count| [name, Integer(count)] }
  end

  # The probe's BEAM, in base64, for standard input: the release has no compiler and reaches no
  # host file, and the boot page's limit on strings leaves no room for it among the arguments.
  def compiled_probe
    erlc = File.join(File.dirname(Erx::Oracle.new(root: ROOT).erl_path(Erx::Runtime::HOST_OTP_FLAVOUR)), 'erlc')
    Dir.mktmpdir('erx-dirty-io-') do |directory|
      log, status = Open3.capture2e(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', COMPILE_SECONDS.to_s, erlc,
                                    '-o', directory, File.join(ROOT, 'test/fixtures', "#{PROBE}.erl"), stdin_data: '')
      assert status.success?, "erlc exit #{status.exitstatus} (124 is the deadline)\n#{log}"
      [File.binread(File.join(directory, "#{PROBE}.beam"))].pack('m0')
    end
  end
end
