# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_uart_sup_tests.erl, the cases of the line groups (erx_uart_sup):
# one group, and so one owner, for each interrupt line the system domain's host link and
# line UARTs use (docs/design-shared-devices.md, "Lines inside a domain"), and seeds that
# give one line two groups and take a configured domain's line service's grants.
class ErxUartSupTest < Minitest::Test
  APPLICATIONS = %w[erx_uart].freeze
  TESTS = %w[test/erlang/erx_uart_sup_tests.erl].freeze
  DEADLINE_SECONDS = '120'
  SUP = 'erlang/apps/erx_uart/src/erx_uart_sup.erl'
  ANCHOR = '|| Line <- lists:uniq([line(Spec) || {_Role, Spec} <- Members])].'

  def test_the_cases_pass
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/(?:\d+ tests|Test) passed/, output)
  end

  # A group for each record rather than each line: line 153 gets two groups, two owners.
  def test_a_group_for_each_record_fails_the_shared_line_case
    source = File.binread(File.join(ErlangBuild::ROOT, SUP))
    assert_equal 1, source.scan(ANCHOR).size
    output, status = run_cases({ SUP => source.sub(ANCHOR) { '|| Line <- [line(Spec) || {_Role, Spec} <- Members]].' } })
    refute status.success?, 'the cases passed'
    assert_match(/one_owner_binds_a_shared_line_test[^\n]*\*failed\*/, output)
  end

  # The grants of a service named line whatever its server, a configured domain's too.
  def test_line_grants_of_any_server_fail_the_server_case
    source = File.binread(File.join(ErlangBuild::ROOT, SUP))
    anchor = '{_Grantee, line, system, #{uart := Uart} = Grant} <- Grants}.'
    assert_equal 1, source.scan(anchor).size
    output, status = run_cases({ SUP => source.sub(anchor) { '{_Grantee, line, _Server, #{uart := Uart} = Grant} <- Grants}.' } })
    refute status.success?, 'the cases passed'
    assert_match(/line_grants_are_the_system_s_line_service_s_test[^\n]*\*failed\*/, output)
  end

  private

  def run_cases(replaced)
    Dir.mktmpdir('erx-uart-sup-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                      '-kernel', 'logger_level', 'none', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_uart_sup_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
