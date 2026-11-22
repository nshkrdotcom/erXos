# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_mini_uart_tests.erl, the EUnit cases of the mini UART driver's
# receive decisions, against erx_mini_uart compiled from source with the rest of its
# application on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). The
# driver's register and interrupt calls reach the stand-ins of erx_device and erx_irq_line,
# through which the order case plays the device.
class ErxMiniUartTest < Minitest::Test
  APPLICATIONS = %w[erx_uart].freeze
  TESTS = %w[test/erlang/stand_in/erx_device.erl test/erlang/stand_in/erx_irq_line.erl
             test/erlang/erx_mini_uart_tests.erl].freeze

  def test_receive_cases_pass_under_eunit
    Dir.mktmpdir('erx-mini-uart-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_mini_uart_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
