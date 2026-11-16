# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_usb_bus_core_tests.erl, the bus core explored to a fixed point
# against a simulated bus and its traces, against the module compiled from source on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). Then each seeded
# fault of docs/design-usb.md's bus core row that this module carries, applied to a
# copy of the module, must fail the case named for it.
class ErxUsbBusCoreTest < Minitest::Test
  APPLICATIONS = %w[erx_usb].freeze
  CORE = 'erlang/apps/erx_usb/src/erx_usb_bus_core.erl'
  TESTS = %w[test/erlang/erx_usb_bus_core_tests.erl test/erlang/erx_usb_desc_tests.erl
             test/erlang/erx_hid_desc_tests.erl].freeze
  DEADLINE_SECONDS = '900'
  EXPLORATION = 'explored_to_a_fixed_point_test_'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'a connection change with the port still connected not detaching the occupant',
             anchor: 'true -> {settling, Now + ?POWER_UP_DELAY_MS};',
             replacement: 'true when Port =/= empty -> Port; true -> {settling, Now + ?POWER_UP_DELAY_MS};',
             catching_case: EXPLORATION),
    Seed.new(fault: "the address-zero turn released at the reset's end instead of the address",
             anchor: "holds_turn({recovering, _At, _Speed}) -> true;\n" \
                     'holds_turn({enumerating, _Ref, Step}) -> Step =:= enabling_slot orelse Step =:= addressing;',
             replacement: "holds_turn({recovering, _At, _Speed}) -> false;\n" \
                          'holds_turn({enumerating, _Ref, _Step}) -> false;',
             catching_case: EXPLORATION),
    Seed.new(fault: 'the turn released when Address Device is sent, before its answer',
             anchor: 'holds_turn({enumerating, _Ref, Step}) -> Step =:= enabling_slot orelse Step =:= addressing;',
             replacement: 'holds_turn({enumerating, _Ref, Step}) -> Step =:= enabling_slot;',
             catching_case: EXPLORATION),
    Seed.new(fault: "a port's status read before the hub's power-good time",
             anchor: 'next_read(Id, Hub = #{pending := [Target | _], power := good}) ->',
             replacement: 'next_read(Id, Hub = #{pending := [Target | _]}) ->',
             catching_case: 'the_root_hub_powers_its_ports_before_reading_them_test'),
    Seed.new(fault: 'a hub detached before the devices below it',
             anchor: '{Actions ++ [{detach, Ref}],',
             replacement: '{[{detach, Ref} | Actions],',
             catching_case: 'a_hub_detached_during_its_childs_enumeration_test'),
    Seed.new(fault: "`handled` sent to the first reporter, not a restarted hub function's",
             anchor: 'Hub#{pending := ordsets:union(P, ordsets:from_list(Named)), reporter := From}',
             replacement: 'Hub#{pending := ordsets:union(P, ordsets:from_list(Named)), reporter := case Hub of #{reporter := none} -> From; #{reporter := R} -> R end}',
             catching_case: 'handled_goes_to_the_reporter_test'),
    Seed.new(fault: 'a port given up with its device still enabled, the turn handed on',
             anchor: '{disabling, Reason, holds_turn_below(Old, State)}',
             replacement: '{disabled, Reason}',
             catching_case: EXPLORATION),
    Seed.new(fault: 'a port given up after its address keeping the turn, so two ports hold it',
             anchor: '{disabling, Reason, holds_turn_below(Old, State)}',
             replacement: '{disabling, Reason, true}',
             catching_case: EXPLORATION),
    Seed.new(fault: "a port's new state dropping its occupant without detaching it",
             anchor: 'case occupant(Old) -- occupant(New) of',
             replacement: 'case occupant(Old) -- occupant(Old) of',
             catching_case: EXPLORATION),
    Seed.new(fault: "a hub given up handing on the turn a port below it held",
             anchor: 'holds_turn_below(Old, State)}',
             replacement: 'holds_turn(Old)}',
             catching_case: 'a_hub_given_up_keeps_its_childs_turn_test'),
    Seed.new(fault: "a full-speed device's EP0 packet size left at 8 when its descriptor says otherwise",
             anchor: 'Packet -> request(Ref, ep0_packet, {evaluate_context, Ref, #{ep0_packet => Packet}}, State)',
             replacement: '_Packet -> read_device(Ref, State)',
             catching_case: EXPLORATION),
    Seed.new(fault: "a hub configured without its hub descriptor, so it never enters the bus",
             anchor: "\#{alternate := 0} ->\n            read_hub_descriptor(Ref, State);",
             replacement: "\#{alternate := 0} ->\n            configure_endpoints(Ref, State);",
             catching_case: EXPLORATION),
    Seed.new(fault: "a device's first request sent at its address answer, without FreeBSD's settle",
             anchor: 'set_step(Ref, {address_settle, Now + ?ERX_USB_SET_ADDRESS_SETTLE_MS}, State);',
             replacement: 'first_read(Ref, State);',
             catching_case: EXPLORATION),
    Seed.new(fault: 'a hub six tiers below the root powering its ports',
             anchor: 'hub_power(Route) when length(Route) > ?ERX_USB_HUB_DEPTH_MAX -> unpowered;',
             replacement: 'hub_power(Route) when length(Route) > ?ERX_USB_HUB_DEPTH_MAX + 1 -> unpowered;',
             catching_case: 'a_hub_past_the_depth_limit_keeps_its_ports_off_test')
  ].freeze

  def test_bus_core_cases_pass_under_eunit
    output, status = run_cases
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, CORE))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases(replaced: { CORE => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  def run_cases(replaced: {})
    Dir.mktmpdir('erx-usb-bus-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_usb_bus_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
