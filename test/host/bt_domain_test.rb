# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/bt_domain'

# The Bluetooth suite's harness (tools/lib/erx/bt_domain.rb): the bring-up case's check of
# the shell's answer, and the manifest's line grant on the platform's line unit. The
# manifest's admission and plan are dom_planner_test's.
class BtDomainTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PLATFORM = Erx::Platform.development(ROOT)

  # The facts the Bluetooth domain prints come as a string after the prompt; a timeout, a
  # missing domain or a term that arrived as a foreign reason is refused with what came.
  def test_the_bring_up_case_wants_the_facts_as_a_string
    Erx::BtDomain.check_ready(%(4> {bt_ready,"\#{core => \#{free => 8},ready => \#{free => 8}}"}\r\n))
    ['{bt_ready,{timeout,none}}', '{bt_ready,{no_domain,[]}}',
     "{bt_ready,{timeout,{'EXIT',{signal,{erx_foreign_reason,<<131>>}}}}}"].each do |answer|
      error = assert_raises(Erx::Error) { Erx::BtDomain.check_ready(answer) }
      assert_includes error.message, answer
    end
  end

  # The grant names the platform's line unit's virtio console and states no rate or flow,
  # and the manifest places that unit on the system domain.
  def test_the_manifest_grants_the_line_unit_s_console
    source = Erx::BtDomain.manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM)
    assert_includes source, "unit line\n  placement \"line\"\n  holder system\n"
    assert_includes source, "  parameter device \"/virtio_mmio@a000e00\"\n"
    refute_match(/^  parameter (rate|flow)/, source[source.index("facet line\n")..])
  end
end
