# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/runtime'
require_relative '../fixtures/runtime_probe'

# The NIFs whose call on Fiasco is a round trip to the root's one service thread run on a
# dirty I/O scheduler (docs/design-fiasco.md, "The root service"), so no normal scheduler of
# the system domain waits behind a long service body, such as a stopped domain's teardown,
# and the watchdog pet on it keeps its deadline. The probe (test/fixtures/service_nifs_probe.erl)
# calls each in a process under a running trace and reports whether the process was scheduled
# out with the NIF as its current function, which a dirty NIF's caller is and a normal NIF's
# is not. Its list of calls is the one list; partial, a NIF that answers from the caller's own
# memory, is the control.
#
# `make check-runtime-hosted` builds the runtime and runs this. It is excused from
# `make check`, which does not build the runtime. With no runtime, or one older than the
# tree, it fails: nothing is skipped.
class RuntimeServiceNifsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CONTROL = 'partial'
  # The probe takes under a second; the budget is a boot on a loaded host.
  BUDGET_SECONDS = 60

  # Each test reads the hosted build, so it runs holding the runtime tree's lock
  # shared, and a build waits for it (Runtime.reading).
  def run = Erx::Runtime.reading(root: ROOT) { super }

  def setup = Erx::Runtime.check_current(root: ROOT)

  def test_each_call_that_waits_on_the_service_leaves_the_normal_scheduler
    verdicts = probe
    assert_equal 'stays', verdicts.delete(CONTROL), 'the control left the normal scheduler, so the probe tells nothing'
    refute_empty verdicts, 'the probe made no call but the control'
    verdicts.each { |name, verdict| assert_equal 'out', verdict, "#{name}'s NIF ran on the normal scheduler" }
  end

  private

  # The probe's verdicts by call name.
  def probe
    output, status = RuntimeProbe.run('service_nifs_probe', budget_seconds: BUDGET_SECONDS)
    assert status.success?, "exit #{status.exitstatus.inspect} (124 is the deadline), " \
                            "signal #{status.termsig.inspect}\n#{output}"
    puts output.scan(/^service nifs: .*$/)
    output.scan(/^service nifs: (\S+) (out|stays)$/).to_h
  end
end
