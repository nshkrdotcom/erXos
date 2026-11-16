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
    {
      'a remote call' => "f(W) -> erx_clock_nif:set_offset(W).\n",
      'a fun' => "f() -> fun erx_clock_nif:set_offset/1.\n",
      'an apply' => "f(W) -> apply(erx_clock_nif, set_offset, [W]).\n",
      'a variable module' => "f(M, W) -> M:set_offset(W).\n",
      'a macro module' => "f(W) -> ?NIF:set_offset(W).\n",
      'an import' => "-import(erx_clock_nif, [set_offset/1]).\n",
      'a macro naming the module' => "-define(NIF, erx_clock_nif).\n"
    }.each do |form, source|
      assert_equal [['clock-setter', OTHER, 1]], found(OTHER => source), form
    end
  end

  def test_the_service_and_the_reading_side_pass
    assert_empty found(SERVICE => "f(W) -> erx_clock_nif:set_offset(W).\n")
    assert_empty found(OTHER => "%% erx_clock_nif:set_offset(W) in a comment is not code\n" \
                                "r() -> erx_clock_nif:read(), \"erx_clock_nif:set_offset\".\n")
  end
end
