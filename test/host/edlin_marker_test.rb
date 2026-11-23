# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/otp_eunit'

# Runs the EUnit cases of test/erlang/edlin_marker_tests.erl against the tree's line editor
# and group, otp/lib/stdlib/src/edlin.erl and edlin_key.erl and otp/lib/kernel/src/group.erl,
# loaded over stock's.
class EdlinMarkerTest < Minitest::Test
  SOURCES = %w[otp/lib/stdlib/src/edlin.erl otp/lib/stdlib/src/edlin_key.erl
               otp/lib/kernel/src/group.erl].freeze
  TESTS = 'test/erlang/edlin_marker_tests.erl'

  def test_the_trees_editor_finishes_no_line_that_holds_the_overrun_marker
    Dir.mktmpdir('erx-edlin') do |work|
      result = OtpEunit.run(work, sources: SOURCES, test: TESTS)
      assert result.passed, result.output
    end
  end
end
