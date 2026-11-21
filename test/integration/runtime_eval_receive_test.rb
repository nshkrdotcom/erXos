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
# And an interpreted receive removes exactly the message its match accepted, whatever the
# match runs: a receive nested in the match sees every queued message, takes what it takes,
# and the outer receive then finds no message it no longer has; an exception out of the
# match leaves the queue at its start; and the timeout keeps running while the match does,
# without firing into it. Edit 78.
#
# `make check-runtime-hosted` builds the runtime and runs this. It is excused from
# `make check`, which does not build the runtime. With no runtime, or one older than the
# tree, it fails: nothing is skipped.
class RuntimeEvalReceiveTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PROBE = 'eval_receive_probe'
  # Twenty rounds and the cases take about two seconds; the budget is a boot on a loaded host.
  BUDGET_SECONDS = 60

  # The probe runs once, for every test: its output and exit status.
  def self.result = @result ||= RuntimeProbe.run(PROBE, budget_seconds: BUDGET_SECONDS)

  # Each test reads the hosted build, so it runs holding the runtime tree's lock
  # shared, and a build waits for it (Runtime.reading).
  def run = Erx::Runtime.reading(root: ROOT) { super }

  def setup = Erx::Runtime.check_current(root: ROOT)

  def test_a_message_an_interpreted_receive_matches_stays_intact_in_the_queue
    assert_probe_line(/^eval receive probe: \d+ rounds, message intact$/)
  end

  def test_an_interpreted_receive_removes_the_message_its_match_accepted
    assert_probe_line(/^eval receive case order: ok$/)
  end

  def test_an_interpreted_receive_whose_match_took_the_message_delivers_nothing
    assert_probe_line(/^eval receive case taken: ok$/)
  end

  def test_an_exception_out_of_an_interpreted_match_leaves_the_queue_at_its_start
    assert_probe_line(/^eval receive case thrown: ok$/)
  end

  def test_a_receive_nested_in_an_interpreted_match_sees_the_earlier_messages
    assert_probe_line(/^eval receive case nested: ok$/)
  end

  def test_an_interpreted_receive_keeps_its_timeout_while_its_match_runs
    assert_probe_line(/^eval receive case timer: ok$/)
  end

  def test_an_interpreted_receive_times_out_after_a_match_that_outlasted_its_timeout
    assert_probe_line(/^eval receive case expired: ok$/)
  end

  def test_the_probe_ends_cleanly
    output, status = self.class.result
    assert status.success?, "exit #{status.exitstatus.inspect} (124 is the deadline), " \
                            "signal #{status.termsig.inspect}\n#{output}"
  end

  private

  def assert_probe_line(line)
    output, status = self.class.result
    assert_match line, output, "exit #{status.exitstatus.inspect} (124 is the deadline), " \
                               "signal #{status.termsig.inspect}\n#{output}"
  end
end
