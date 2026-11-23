# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/ble_board_check'

# The verdicts of tools/ble_board_check.rb over blew's logs. The fixtures are cut
# from the recorded run of a Pi 4 (scan, connect and discover, write, read); the
# crowded scan has the shapes a busy room adds.
class BleBoardCheckTest < Minitest::Test
  Check = Erx::BleBoardCheck
  BOARD = 'F8A0E70B-141F-2388-9DA9-CCFD586437E0'

  def fixture(name) = File.read(File.join(__dir__, '../fixtures/ble_board_check', name))

  def run_of(name, status) = Check::Run.new(output: fixture(name), status: status)

  def step(name) = Check.steps(BOARD).find { |step| step.name == name }

  def verdict(name, fixture_name, status)
    Check.judge(run_of(fixture_name, status), &step(name).check).status
  end

  def test_the_scan_passes_on_one_device_with_the_exact_name
    assert_equal [BOARD], Check.board_ids(fixture('scan_board.log'), 'erxos')
    assert_equal :passed, Check.scan_outcome([BOARD]).status
  end

  def test_the_scan_matches_the_whole_name_not_a_part
    assert_equal [BOARD], Check.board_ids(fixture('scan_crowd.log'), 'erxos')
    assert_equal ['BCAC47AC-9213-8650-88C3-EF7CD155F7D1'], Check.board_ids(fixture('scan_crowd.log'), 'erxos spare')
  end

  def test_the_scan_fails_when_no_device_advertises_the_name
    assert_equal :failed, Check.scan_outcome(Check.board_ids(fixture('scan_crowd.log'), 'erx')).status
  end

  def test_the_scan_is_unknown_when_two_devices_advertise_the_name
    assert_equal :unknown, Check.scan_outcome([BOARD, BOARD.sub('F8', 'F9')]).status
  end

  def test_a_name_with_a_script_separator_reaches_no_script
    assert_empty Check.board_ids("id=#{BOARD} name=\"a; gatt tree\" rssi=-40 services=\"\"\n", 'erxos')
    assert_raises(Erx::Error) { Check.steps('F8A0E70B; write') }
  end

  def test_discovery_passes_on_a_table_with_nus
    assert_equal :passed, verdict('connect and discover', 'discover_nus.log', 0)
  end

  def test_discovery_fails_on_a_table_without_nus
    assert_equal :failed, Check.judge(Check::Run.new(output: "type=service uuid=180F\n", status: 0),
                                      &step('connect and discover').check).status
  end

  def test_the_write_is_unknown_when_no_handler_answered
    outcome = Check.judge(run_of('write_unlikely.log', 5), &step('write NUS RX').check)
    assert_equal :unknown, outcome.status
    assert_equal 'Unlikely Error: no handler answered', outcome.detail
  end

  def test_the_write_passes_when_an_app_takes_it
    assert_equal :passed, Check.judge(Check::Run.new(output: '', status: 0), &step('write NUS RX').check).status
  end

  def test_the_write_fails_on_any_other_refusal
    run = Check::Run.new(output: "Error: Write failed: Writing is not permitted.\nError: exit code 5\n", status: 5)
    assert_equal :failed, Check.judge(run, &step('write NUS RX').check).status
  end

  def test_the_read_passes_when_refused
    assert_equal :passed, verdict('read NUS RX, refused', 'read_refused.log', 5)
  end

  def test_the_read_fails_when_it_returns_a_value
    assert_equal :failed, Check.judge(Check::Run.new(output: "00\n", status: 0),
                                      &step('read NUS RX, refused').check).status
  end

  def test_the_steps_are_unknown_on_the_exits_that_say_nothing_about_the_board
    [3, 4, 6, 127, 124, 1, nil].each do |status|
      step('read NUS RX, refused').then do |read|
        run = Check::Run.new(output: "Error: Read failed: Reading is not permitted.\n", status: status)
        assert_equal :unknown, Check.judge(run, &read.check).status, status.inspect
      end
      assert_equal :unknown, Check.judge(Check::Run.new(output: fixture('discover_nus.log'), status: status),
                                         &step('connect and discover').check).status, status.inspect
    end
  end

  # exec prints the code of the command that failed, which decides over the process's.
  def test_the_last_exit_code_line_of_exec_decides
    timed_out = Check::Run.new(output: "connecting\nError: exit code 4\n", status: 1)
    assert_equal 4, Check.exit_code(timed_out)
    assert_equal :unknown, Check.judge(timed_out, &step('read NUS RX, refused').check).status
    assert_equal 5, Check.exit_code(run_of('read_refused.log', 0))
  end

  def test_the_echo_waits_for_blew_nus
    assert_nil step('NUS echo').argv
    assert_equal :unknown, step('NUS echo').check.call('', nil).status
  end

  def test_the_exit_status_of_a_checklist
    passed = Check.outcome(:passed, '')
    assert_equal 0, Check.exit_status([passed, Check.outcome(:unknown, '')])
    assert_equal 1, Check.exit_status([passed, Check.outcome(:failed, '')])
    assert_equal 3, Check.exit_status([Check.outcome(:unknown, '')])
  end
end
