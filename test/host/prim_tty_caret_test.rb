# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/otp_eunit'

# Runs the EUnit cases of test/erlang/prim_tty_caret_tests.erl against the tree's prim_tty,
# otp/lib/kernel/src/prim_tty.erl, loaded over the kernel's once the emulator has started.
class PrimTtyCaretTest < Minitest::Test
  SOURCES = %w[otp/lib/kernel/src/prim_tty.erl].freeze
  TESTS = 'test/erlang/prim_tty_caret_tests.erl'

  def test_control_characters_are_shown_in_caret_notation_by_the_trees_prim_tty
    Dir.mktmpdir('erx-prim-tty') do |work|
      result = OtpEunit.run(work, sources: SOURCES, test: TESTS, late: SOURCES)
      assert result.passed, result.output
    end
  end
end
