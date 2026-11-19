# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/runtime'
require_relative '../fixtures/runtime_probe'

# A queued message whose term is a literal and whose seq_trace token is on the receiver's
# heap keeps its token through the collection of the literal's area
# (test/fixtures/literal_token_probe.erl). When the collection copies only the literal into
# a fragment of the message's own, the next garbage collection leaves the token in a freed
# heap: the hosted runtime then reads a wrong token, or faults where the backend has taken
# the freed pages away. Stock OTP 29.1.2 aborts on the same probe.
#
# `make check-runtime-hosted` builds the runtime and runs this. It is excused from
# `make check`, which does not build the runtime. With no runtime, or one older than the
# tree, it fails: nothing is skipped.
class RuntimeLiteralTokenTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PROBE = 'literal_token_probe'
  # Twenty rounds take well under a second; the budget is a boot on a loaded host.
  BUDGET_SECONDS = 60

  # Each test reads the hosted build, so it runs holding the runtime tree's lock
  # shared, and a build waits for it (Runtime.reading).
  def run = Erx::Runtime.reading(root: ROOT) { super }

  def setup = Erx::Runtime.check_current(root: ROOT)

  def test_a_queued_literal_keeps_its_token_through_the_area_collection
    output, status = RuntimeProbe.run(PROBE, budget_seconds: BUDGET_SECONDS)
    assert status.success?, "exit #{status.exitstatus.inspect} (124 is the deadline), " \
                            "signal #{status.termsig.inspect}\n#{output}"
    assert_match(/^literal token probe: \d+ rounds, token intact$/, output)
  end
end
