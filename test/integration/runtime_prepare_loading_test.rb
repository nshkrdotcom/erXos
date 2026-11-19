# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/runtime'
require_relative '../fixtures/runtime_probe'

# Preparing a module for loading runs on a dirty CPU scheduler, so a normal scheduler keeps
# running processes through it (docs/design-runtime.md, edit 76), and the system domain's
# watchdog pet, a process at priority max on its one normal scheduler, keeps its deadline while
# a slow machine prepares a large module. Stock OTP 29.1.2 prepares on the calling normal
# scheduler, which runs nothing else until the call returns. The probe
# (test/fixtures/prepare_loading_probe.erl) counts a millisecond ticker's wakes while it
# prepares unicode_util ten times with one normal scheduler online.
#
# `make check-runtime-hosted` builds the runtime and runs this. It is excused from
# `make check`, which does not build the runtime. With no runtime, or one older than the
# tree, it fails: nothing is skipped.
class RuntimePrepareLoadingTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # Ten prepares of unicode_util take longer than this on any host, long enough that a
  # ticker running beside them wakes many times.
  LOADS_MS_MIN = 20
  # A ticker held off the scheduler wakes at most once, if the probe is scheduled out between
  # two prepares; one running beside them wakes about once a millisecond.
  TICKS_MIN = 5
  # The probe takes under a second; the budget is a boot on a loaded host.
  BUDGET_SECONDS = 60

  # Each test reads the hosted build, so it runs holding the runtime tree's lock
  # shared, and a build waits for it (Runtime.reading).
  def run = Erx::Runtime.reading(root: ROOT) { super }

  def setup = Erx::Runtime.check_current(root: ROOT)

  def test_a_normal_scheduler_runs_processes_while_a_module_is_prepared
    found = probe.match(/^prepare loading: ms (?<ms>\d+) ticks (?<ticks>\d+)$/) or flunk("no timing line\n#{@output}")
    ms = Integer(found[:ms])
    assert_operator ms, :>=, LOADS_MS_MIN, 'the prepares were too short to tell'
    assert_operator Integer(found[:ticks]), :>=, TICKS_MIN, "the ticker's wakes during #{ms} ms of prepares"
  end

  # On a dirty scheduler the BIF runs on a shadow of its caller, which carries the caller's
  # group leader, so the loader's report of a refused module goes to it.
  def test_a_refused_module_is_reported_to_the_callers_group_leader
    found = probe.match(/^prepare loading: report gl (?<gl>.+)$/) or flunk("no report line\n#{@output}")
    assert_equal 'caller', found[:gl]
  end

  private

  # The probe's output, run once per test.
  def probe
    @output, status = RuntimeProbe.run('prepare_loading_probe', budget_seconds: BUDGET_SECONDS)
    assert status.success?, "exit #{status.exitstatus.inspect} (124 is the deadline), " \
                            "signal #{status.termsig.inspect}\n#{@output}"
    puts @output.scan(/^prepare loading: .*$/)
    @output
  end
end
