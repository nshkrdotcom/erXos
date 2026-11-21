# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_xhci_tests.erl, the controller process of docs/design-usb.md
# ("The controller process"), erx_xhci, over erx_device's stand-in for a device the test
# process plays and erx_irq_line's stand-in, on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies).
class ErxXhciTest < Minitest::Test
  APPLICATIONS = %w[erx_usb].freeze
  TESTS = %w[
    test/erlang/stand_in/erx_device.erl
    test/erlang/stand_in/erx_irq_line.erl
    test/erlang/erx_xhci_tests.erl
  ].freeze
  DEADLINE_SECONDS = '120'

  def test_xhci_process_cases_pass_under_eunit
    Dir.mktmpdir('erx-xhci-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-eval',
                                       'halt(case eunit:test(erx_xhci_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
