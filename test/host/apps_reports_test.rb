# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/apps'

# The apps suite's checks of what clock's sessions logged (Erx::Apps.reports!), over the
# lines the shell prints from /proc/kernel/log ahead of its answers, which the serial
# log holds even when the console's own copy of a record comes after the boot ends.
class AppsReportsTest < Minitest::Test
  REPORT = '#18 1.295783 debug space 6: notice: erx_clock_test: ' \
           '{clock_report,clock_1@erxos,[code_objects,home],true,{error,enoent},ok}'
  STARTED = '#21 1.500000 debug space 9: info: erx_clock_test: starting'

  def serial(*lines) = lines.map { |line| "#{line}\r\n" }.join

  # The typed lines carry the markers the shell searches /proc/kernel/log for; their
  # echo must not pass for a record of clock's.
  def test_the_echo_of_a_typed_line_is_no_record_of_clocks
    [Erx::Apps::KILL_CLOCK, Erx::Apps::NO_CLOCK, Erx::Apps::CLOCK_UP].each do |typed|
      refute_match Erx::Apps::ANY_REPORT, typed
      refute_match Erx::Apps::ANY_LINE, typed
    end
  end

  # The kept boot's records as the shell prints them before its answer, with no copy
  # from the console: the report counts. Without it the boot fails.
  def test_a_report_the_shell_printed_counts
    assert Erx::Apps.reports!(serial(REPORT, Erx::Apps::KILLED), boot: :kept)
    assert_raises(Erx::Error) { Erx::Apps.reports!(serial(Erx::Apps::KILLED), boot: :kept) }
  end

  # In the reenable boot a line of clock's printed ahead of NO_CLOCK's answer fails it.
  def test_a_line_printed_before_the_no_clock_answer_fails_the_reenable_boot
    up = Erx::Apps::CLOCK_IS_UP.fetch(:reenable)
    assert Erx::Apps.reports!(serial(Erx::Apps::NO_CLOCK_ANSWER.fetch(:reenable), REPORT, up), boot: :reenable)
    assert_raises(Erx::Error) do
      Erx::Apps.reports!(serial(STARTED, Erx::Apps::NO_CLOCK_ANSWER.fetch(:reenable), REPORT, up), boot: :reenable)
    end
  end
end
