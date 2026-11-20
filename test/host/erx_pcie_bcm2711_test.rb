# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_pcie_bcm2711_tests.erl, the cases of the BCM2711 bridge's core
# over the register model test/erlang/erx_pcie_bcm2711_model.erl, against the erx_pcie
# application compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies). Then each seeded fault of the verification table's bridge row
# (docs/design-usb.md, "Verification"), applied to a copy of the core, must fail the
# case named for it: the bus-0 rule removed; the link read after the access removed,
# so a value read across a fall is reported; the reset run on a link up with firmware
# present; the notification skipped after a reset; the 100 ms wait dropped.
class ErxPcieBcm2711Test < Minitest::Test
  APPLICATIONS = %w[erx_pcie].freeze
  TESTS = %w[test/erlang/erx_pcie_bcm2711_model.erl test/erlang/erx_pcie_bcm2711_tests.erl].freeze
  CORE = 'erlang/apps/erx_pcie/src/erx_pcie_bcm2711_core.erl'
  DEADLINE_SECONDS = '120'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the bus-0 rule removed',
             anchor: '        {{0, _, _}, _} -> Then({error, absent});',
             replacement: '        {{0, _, _}, never} -> Then({error, absent});',
             catching_case: 'the_bus_0_rule_holds_whatever_the_record_says_test'),
    Seed.new(fault: 'the link read after the access removed',
             anchor: '                                                     true -> Then(Answer);',
             replacement: '                                                     _ -> Then(Answer);',
             catching_case: 'a_value_read_across_a_fall_is_not_taken_test'),
    Seed.new(fault: 'the reset run on a link up with firmware present',
             anchor: '        true -> keep(Plan);',
             replacement: '        true -> turn_off(Plan);',
             catching_case: 'a_kept_link_sees_no_perst_write_test'),
    Seed.new(fault: 'the notification skipped after a reset',
             anchor: '    run(Core#core{agenda = [{notify_firmware, fun(Answer) -> notified(Plan, Answer) end}]}).',
             replacement: '    run(Core#core{agenda = notified(Plan, ok)}).',
             catching_case: 'bring_up_ends_with_the_notification_test'),
    Seed.new(fault: 'the 100 ms wait dropped',
             anchor: "                    wait(?PERST_SETTLE_US),\n",
             replacement: '',
             catching_case: 'the_first_endpoint_access_is_100_ms_after_perst_release_test')
  ].freeze

  def test_bridge_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, CORE))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ CORE => source.sub(seed.anchor) { seed.replacement } })
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
                      '-eval', 'halt(case eunit:test([erx_pcie_bcm2711_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
