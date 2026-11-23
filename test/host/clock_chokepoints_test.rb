# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

# The clock setter's chokepoint (docs/design-time.md, "The NIF and the liberx calls"):
# only erx_clock calls erx_clock_nif:set_offset/1, so no other module of the system
# release, the date command or a session's code included, writes the time page.
class ClockChokepointsTest < Minitest::Test
  include ChokepointsHelper

  RULES = %w[clock-setter].freeze
  SERVICE = 'erlang/apps/erx/src/erx_clock.erl'
  OTHER = 'erlang/apps/erx_shell/src/erx_cmd_date.erl'

  def found(files) = erlang_found(RULES, files)

  def test_the_tree_passes
    assert_empty evaluate(RULES.map { |name| rule(name) }, erlang_tree).map(&:to_s)
  end

  def test_every_spelling_of_the_call_outside_the_service_is_refused
    ErlangCallSpellings.all('erx_clock_nif', 'set_offset').each do |spelling|
      assert_equal [['clock-setter', OTHER, spelling.line]], found(OTHER => spelling.source), spelling.form
    end
    ErlangCallSpellings.unrelated('erx_clock_nif', 'set_offset').each { |source| assert_empty found(OTHER => source), source }
  end

  def test_the_service_and_the_reading_side_pass
    assert_empty found(SERVICE => "f(W) -> erx_clock_nif:set_offset(W).\n")
    assert_empty found(OTHER => "%% erx_clock_nif:set_offset(W) in a comment is not code\n" \
                                "r() -> erx_clock_nif:read(), \"erx_clock_nif:set_offset\".\n")
  end
end
