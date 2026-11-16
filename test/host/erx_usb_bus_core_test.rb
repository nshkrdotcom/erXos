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
# copy of the module, must fail what it names: one case, or the exploration at the
# smallest depth that catches it, so the seeds cost seconds; every depth named is
# within one of the module's own, so the unseeded run explores every path it does.
class ErxUsbBusCoreTest < Minitest::Test
  APPLICATIONS = %w[erx_usb].freeze
  CORE = 'erlang/apps/erx_usb/src/erx_usb_bus_core.erl'
  TESTS = %w[test/erlang/erx_usb_bus_core_tests.erl test/erlang/erx_usb_desc_tests.erl
             test/erlang/erx_hid_desc_tests.erl].freeze
  DEADLINE_SECONDS = '900'

  Seed = Data.define(:fault, :anchor, :replacement, :catching)

  SEEDS = [
    Seed.new(fault: 'a connection change with the port still connected not detaching the occupant',
             anchor: 'true -> {settling, Now + ?ERX_USB_POWER_UP_DELAY_MS};',
             replacement: 'true when Port =/= empty -> Port; true -> {settling, Now + ?ERX_USB_POWER_UP_DELAY_MS};',
             catching: [3, 0]),
    Seed.new(fault: "the address-zero turn released at the reset's end instead of the address",
             anchor: "holds_turn({recovering, _At, _Speed}) -> true;\n" \
                     'holds_turn({enumerating, _Ref, Step}) -> Step =:= enabling_slot orelse Step =:= addressing;',
             replacement: "holds_turn({recovering, _At, _Speed}) -> false;\n" \
                          'holds_turn({enumerating, _Ref, _Step}) -> false;',
             catching: [2, 0]),
    Seed.new(fault: 'the turn released when Address Device is sent, before its answer',
             anchor: 'holds_turn({enumerating, _Ref, Step}) -> Step =:= enabling_slot orelse Step =:= addressing;',
             replacement: 'holds_turn({enumerating, _Ref, Step}) -> Step =:= enabling_slot;',
             catching: [2, 0]),
    Seed.new(fault: "a port's status read before the hub's power-good time",
             anchor: 'next_read(Id, Hub = #{pending := [Target | _], power := good}) ->',
             replacement: 'next_read(Id, Hub = #{pending := [Target | _]}) ->',
             catching: 'the_root_hub_powers_its_ports_before_reading_them_test'),
    Seed.new(fault: 'a hub detached before the devices below it',
             anchor: '{Actions ++ [{detach, Ref}],',
             replacement: '{[{detach, Ref} | Actions],',
             catching: 'a_hub_detached_during_its_childs_enumeration_test'),
    Seed.new(fault: "`handled` sent to the first reporter, not a restarted hub function's",
             anchor: 'Hub#{pending := ordsets:union(P, ordsets:from_list(Named)), reporter := From}',
             replacement: 'Hub#{pending := ordsets:union(P, ordsets:from_list(Named)), reporter := case Hub of #{reporter := none} -> From; #{reporter := R} -> R end}',
             catching: 'handled_goes_to_the_reporter_test'),
    Seed.new(fault: 'a port given up with its device still enabled, the turn handed on',
             anchor: '{disabling, Reason, holds_turn_below(Old, State)}',
             replacement: '{disabled, Reason}',
             catching: [2, 0]),
    Seed.new(fault: 'a port given up after its address keeping the turn, so two ports hold it',
             anchor: '{disabling, Reason, holds_turn_below(Old, State)}',
             replacement: '{disabling, Reason, true}',
             catching: [2, 1]),
    Seed.new(fault: "a port's new state dropping its occupant without detaching it",
             anchor: 'case occupant(Old) -- occupant(New) of',
             replacement: 'case occupant(Old) -- occupant(Old) of',
             catching: [2, 0]),
    Seed.new(fault: "a hub given up handing on the turn a port below it held",
             anchor: 'holds_turn_below(Old, State)}',
             replacement: 'holds_turn(Old)}',
             catching: 'a_hub_given_up_keeps_its_childs_turn_test'),
    Seed.new(fault: "a full-speed device's EP0 packet size left at 8 when its descriptor says otherwise",
             anchor: 'Packet -> request(Ref, ep0_packet, {evaluate_context, #{ep0_packet => Packet}}, State)',
             replacement: '_Packet -> read_device(Ref, State)',
             catching: [1, 0]),
    Seed.new(fault: 'the step an answer echoes ignored, so a stale answer is taken at the step awaiting its kind',
             anchor: 'device_answered(Ref, Step, Kind, Result, Now, State = #{devices := Devices}) ->',
             replacement: 'device_answered(Ref, _Echoed, Kind, Result, Now, State = #{devices := Devices}) ->',
             catching: [1, 0]),
    Seed.new(fault: "a hub configured without its hub descriptor, so it never enters the bus",
             anchor: "\#{alternate := 0} ->\n            read_hub_descriptor(Ref, State);",
             replacement: "\#{alternate := 0} ->\n            configure_endpoints(Ref, State);",
             catching: [1, 0]),
    Seed.new(fault: "a device's first request sent at its address answer, without FreeBSD's settle",
             anchor: 'set_step(Ref, {address_settle, Now + ?ERX_USB_SET_ADDRESS_SETTLE_MS}, State);',
             replacement: 'first_read(Ref, State);',
             catching: [1, 0]),
    Seed.new(fault: 'a hub six tiers below the root powering its ports',
             anchor: 'hub_power(Route) when length(Route) > ?ERX_USB_HUB_DEPTH_MAX -> unpowered;',
             replacement: 'hub_power(Route) when length(Route) > ?ERX_USB_HUB_DEPTH_MAX + 1 -> unpowered;',
             catching: 'a_hub_past_the_depth_limit_keeps_its_ports_off_test'),
    Seed.new(fault: 'the attempt throttle removed, so a settled port always starts an attempt',
             anchor: 'case length(Recent) < ?ERX_USB_PORT_ATTEMPTS_MAX of',
             replacement: 'case length(Recent) >= 0 of',
             catching: 'a_port_starts_at_most_three_attempts_a_minute_test'),
    Seed.new(fault: "a port's attempts never leaving the window",
             anchor: 'Recent = [T || T <- Attempts, Now - T < ?ERX_USB_PORT_ATTEMPT_WINDOW_MS],',
             replacement: 'Recent = Attempts,',
             catching: 'a_port_starts_at_most_three_attempts_a_minute_test'),
    Seed.new(fault: 'an over-current change logged on every change',
             anchor: '{[{log, Id, N, over_current} || not Logged],',
             replacement: '{[{log, Id, N, over_current} || is_boolean(Logged)],',
             catching: 'over_current_changes_are_logged_once_per_attempt_test'),
    Seed.new(fault: 'the over-current log not rearmed by an attempt',
             anchor: 'Started = History#{attempts := Recent ++ [Now], over_current_logged := false},',
             replacement: 'Started = History#{attempts := Recent ++ [Now]},',
             catching: 'over_current_changes_are_logged_once_per_attempt_test')
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
      output, status = run_cases(replaced: { CORE => source.sub(seed.anchor) { seed.replacement } },
                                 cases: cases(seed.catching))
      refute status.success?, "#{seed.fault}: #{seed.catching} passed"
      assert_match(/Failed: 1\./, output, "#{seed.fault}:\n#{output[-2000..]}")
      assert_match(/#{seed.catching}[^\n]*\*failed\*/, output, seed.fault) if seed.catching.is_a?(String)
      refute_match(/no_such_function|undef/, output, seed.fault)
    end
  end

  private

  # The eunit test a seed names: a case by its name, or the exploration at a depth of
  # connects or disconnects and failed answers.
  def cases(catching)
    case catching
    in [Integer => stimuli, Integer => errors]
      "{timeout, 600, fun() -> erx_usb_bus_core_tests:explored(#{stimuli}, #{errors}) end}"
    in String => name
      "{test, erx_usb_bus_core_tests, #{name}}"
    end
  end

  def run_cases(replaced: {}, cases: 'erx_usb_bus_core_tests')
    Dir.mktmpdir('erx-usb-bus-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', "halt(case eunit:test(#{cases}, [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
