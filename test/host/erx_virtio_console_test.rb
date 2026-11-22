# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_virtio_console_tests.erl, the EUnit cases of the driver's
# format_status/1, against erx_virtio_console compiled from source with the rest of its
# application on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). The
# cases call no device, so they need no hosted build.
class ErxVirtioConsoleTest < Minitest::Test
  # The application, compiled whole (ErlangBuild), and the suite.
  APPLICATIONS = %w[erx_uart].freeze
  TESTS = %w[test/erlang/erx_virtio_console_tests.erl].freeze

  def test_format_status_cases_pass_under_eunit
    Dir.mktmpdir('erx-virtio-console-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval',
                                       'halt(case eunit:test(erx_virtio_console_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      # EUnit says "Test passed.", "2 tests passed." or "All N tests passed." (eunit_tty).
      assert_match(/\d+ tests passed/, output)
    end
  end
end
