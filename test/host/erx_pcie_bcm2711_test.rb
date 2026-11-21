# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_pcie_bcm2711_tests.erl, the cases of the BCM2711 bridge's core,
# and test/erlang/erx_pcie_bcm2711_driver_tests.erl, the cases of its driver, over the
# register model test/erlang/erx_pcie_bcm2711_model.erl, against the erx_pcie
# application compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies). Then each seeded fault, applied to a copy of its source, must fail the
# case named for it. The core's are the verification table's bridge row
# (docs/design-usb.md, "Verification"): the bus-0 rule removed; the link read after the
# access removed, so a value read across a fall is reported; the reset run on a link up
# with firmware present; the notification skipped after a reset; the 100 ms wait
# dropped; a bridge in reset taken as out of it, and a SerDes powered down taken as
# powered, so a register they gate is read and the model's bus hangs. The driver's
# are one for each of its failure paths: a failed start not matched, so a link that
# never comes up crashes the start; the port's state after an operation dropped; the
# VL805 given while its firmware reads absent; the notification asked for again at a
# later `ready`; a link that falls under the firmware read not matched.
class ErxPcieBcm2711Test < Minitest::Test
  APPLICATIONS = %w[erx_pcie].freeze
  TESTS = %w[test/erlang/erx_pcie_log_capture.erl test/erlang/erx_pcie_bcm2711_model.erl
             test/erlang/erx_pcie_bcm2711_tests.erl
             test/erlang/erx_pcie_bcm2711_driver_tests.erl].freeze
  CORE = 'erlang/apps/erx_pcie/src/erx_pcie_bcm2711_core.erl'
  DRIVER = 'erlang/apps/erx_pcie/src/erx_pcie_bcm2711.erl'
  DEADLINE_SECONDS = '120'
  # Silences the logger first, so no log line of the driver splits a case from its verdict.
  EVAL = 'logger:set_primary_config(level, none), ' \
         'halt(case eunit:test([erx_pcie_bcm2711_tests, erx_pcie_bcm2711_driver_tests], [verbose]) of ' \
         'ok -> 0; _ -> 1 end)'

  Seed = Data.define(:source, :fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(source: CORE, fault: 'the bridge reset bit not checked',
             anchor: "                      1 -> bring_up(Plan, not_run);\n                      0 -> powered(Plan)",
             replacement: '                      _ -> powered(Plan)',
             catching_case: 'a_bridge_left_in_reset_is_reached_only_at_its_reset_register_test'),
    Seed.new(source: CORE, fault: 'the SerDes power not checked',
             anchor: "                      1 -> bring_up(Plan, not_run);\n                      0 -> by_link(Plan)",
             replacement: '                      _ -> by_link(Plan)',
             catching_case: 'a_bridge_whose_serdes_is_off_is_brought_up_before_its_status_is_read_test'),
    Seed.new(source: CORE, fault: 'the bus-0 rule removed',
             anchor: '        {{0, _, _}, _} -> Then({error, absent});',
             replacement: '        {{0, _, _}, never} -> Then({error, absent});',
             catching_case: 'the_bus_0_rule_holds_whatever_the_record_says_test'),
    Seed.new(source: CORE, fault: 'the link read after the access removed',
             anchor: '                                                     true -> Then(Answer);',
             replacement: '                                                     _ -> Then(Answer);',
             catching_case: 'a_value_read_across_a_fall_is_not_taken_test'),
    Seed.new(source: CORE, fault: 'the reset run on a link up with firmware present',
             anchor: '        true -> keep(Plan);',
             replacement: '        true -> turn_off(Plan);',
             catching_case: 'a_kept_link_sees_no_perst_write_test'),
    Seed.new(source: CORE, fault: 'the notification skipped after a reset',
             anchor: '    run(Core#core{agenda = [{notify_firmware, fun(Answer) -> notified(Plan, Answer) end}]}).',
             replacement: '    run(Core#core{agenda = notified(Plan, ok)}).',
             catching_case: 'bring_up_ends_with_the_notification_test'),
    Seed.new(source: CORE, fault: 'the 100 ms wait dropped',
             anchor: "                    wait(?PERST_SETTLE_US),\n",
             replacement: '',
             catching_case: 'the_first_endpoint_access_is_100_ms_after_perst_release_test'),
    Seed.new(source: DRIVER, fault: 'a failed start not matched',
             anchor: '        {{error, _} = Error, _Core} ->',
             replacement: '        {{error, endpoint_mode} = Error, _Core} ->',
             catching_case: 'a_link_that_never_comes_up_fails_the_start_test'),
    Seed.new(source: DRIVER, fault: 'a wait slept in microseconds',
             anchor: '    ok = Sleep((Microseconds + 999) div 1000);',
             replacement: '    ok = Sleep(Microseconds);',
             catching_case: 'the_reset_path_brings_the_link_up_and_notifies_test'),
    Seed.new(source: DRIVER, fault: 'the notification not made through the firmware effect',
             anchor: "make(notify_firmware, _Device, \#{firmware := Firmware}) ->\n    Firmware().",
             replacement: "make(notify_firmware, _Device, \#{firmware := _Firmware}) ->\n    ok.",
             catching_case: 'the_reset_path_brings_the_link_up_and_notifies_test'),
    Seed.new(source: DRIVER, fault: 'the VL805 given while its firmware reads absent',
             anchor: '        {ok, Asked} -> {not_ready, Asked};',
             replacement: '        {ok, Asked} -> {ok, Asked};',
             catching_case: 'a_vl805_whose_firmware_stays_absent_is_not_ready_test'),
    Seed.new(source: DRIVER, fault: 'the notification asked for again at a later ready',
             anchor: 'ask_firmware(#bridge{firmware = unknown, ',
             replacement: 'ask_firmware(#bridge{firmware = _, ',
             catching_case: 'a_vl805_whose_notification_fails_is_not_ready_test'),
    Seed.new(source: DRIVER, fault: 'a link that falls under the firmware read not matched',
             anchor: "        {{error, link_down} = Error, _Core} ->\n            logger:warning(\"pcie: bridge ~b: link down under",
             replacement: "        {{error, never} = Error, _Core} ->\n            logger:warning(\"pcie: bridge ~b: link down under",
             catching_case: 'a_link_that_falls_under_the_firmware_read_answers_link_down_test')
  ].freeze

  def test_bridge_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.source))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.source => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  # The core's text, any replaced, compiled with the cases, then the cases run.
  def run_cases(replaced)
    Dir.mktmpdir('erx-pcie-bcm2711-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', EVAL,
                      chdir: work, stdin_data: '')
    end
  end
end
