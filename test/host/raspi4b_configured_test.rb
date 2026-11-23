# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/raspi4b_shell'

# The raspi4b suite's decision of which configured domains the serial log
# still lacks the expected line of (Raspi4bShell.missing_lines), which the
# system's Erlang shell waits on before it halts the machine: a domain whose
# line the log holds is not missing, one whose line has not come yet is, and
# a domain with no expected line fails the run rather than pass unchecked.
class Raspi4bConfiguredTest < Minitest::Test
  SHELL = Erx::Raspi4bShell

  def record(text) = "#3 21.912345 debug space 7: #{text}\r\n"

  def display_line = record(SHELL::DRIVER_LINE)
  def bt_line = record("#{SHELL::BT_WRITER_END}0.81.0>, reason: line_write")

  def test_a_domain_whose_line_has_not_come_is_missing
    assert_equal %w[bt], SHELL.missing_lines(display_line, names: %w[display bt])
  end

  def test_no_domain_is_missing_once_every_line_has_come
    assert_empty SHELL.missing_lines(display_line + bt_line, names: %w[display bt])
  end

  def test_a_domain_with_no_expected_line_fails
    error = assert_raises(Erx::Error) { SHELL.missing_lines(display_line, names: %w[display serial]) }
    assert_match(/configured domain serial has no expected line/, error.message)
  end
end
