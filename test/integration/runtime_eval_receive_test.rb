# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/runtime'
require_relative '../fixtures/runtime_probe'

# A queued message that an interpreted receive is matching stays intact through a garbage
# collection the match itself causes (test/fixtures/eval_receive_probe.erl): erl_eval loads
# eval_bits on the way, through the code server, and code:ensure_loaded/1 then collects the
# heap. When prim_eval:'receive'/2 hands the match the message where it lies, in a fragment
# still attached to the queue, that collection moves the message's terms out and leaves
# forwarding words in the queued fragment: the hosted runtime then gets a wrong message
# back, or faults. Stock OTP 29.1.2 dies of SIGSEGV on the same probe. Edit 77 of
# docs/design-runtime.md.
#
# `make check-runtime-hosted` builds the runtime and runs this. It is excused from
# `make check`, which does not build the runtime. With no runtime, or one older than the
# tree, it fails: nothing is skipped.
class RuntimeEvalReceiveTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PROBE = 'eval_receive_probe'
  # Twenty rounds take about a second; the budget is a boot on a loaded host.
  BUDGET_SECONDS = 60

  # Each test reads the hosted build, so it runs holding the runtime tree's lock
  # shared, and a build waits for it (Runtime.reading).
  def run = Erx::Runtime.reading(root: ROOT) { super }

  def setup = Erx::Runtime.check_current(root: ROOT)

  def test_a_message_an_interpreted_receive_matches_stays_intact_in_the_queue
    output, status = RuntimeProbe.run(PROBE, budget_seconds: BUDGET_SECONDS)
    assert status.success?, "exit #{status.exitstatus.inspect} (124 is the deadline), " \
                            "signal #{status.termsig.inspect}\n#{output}"
    assert_match(/^eval receive probe: \d+ rounds, message intact$/, output)
  end
end
