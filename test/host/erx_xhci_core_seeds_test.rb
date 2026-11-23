# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../fixtures/xhci_core_cases'

# Runs the case named for each seeded fault of test/erlang/erx_xhci_core_tests.erl (the cases
# test/host/erx_xhci_core_test.rb passes unseeded) against the seeded module, in a file of its
# own so these runs have their own deadline. Each case passes unseeded when run alone, and
# each seeded fault, applied to a copy of the module, must fail the case named for it:
# Reset Endpoint issued on a stopped queue; a stopped EP0 dropped and added; the
# translator's buffer left uncleared after a halt; a reset whose Stop Endpoint still waits
# keeping it when the endpoint halts, so the stop goes to a halted queue; a pipe that leaves
# open dropping the requests waiting on it unanswered; Disable Slot posted while a queue
# runs a transfer, or before the stops; a halt on a draining queue left running; a detach
# that frees the slot without Disable Slot; a reset in progress at the detach left
# unanswered; a reset step's answer taken by a later reset of a pipe of the same name on a
# slot enabled again; a detached reference left bound; a slot nobody owns left enabled; an
# Enable Slot naming a held slot taken; an Address Device whose device detached while it was
# posted left unanswered; the translator's clear skipped after a failed address; the abort
# answered after Stop Endpoint alone; an aborted request's own completion answered too; the
# control deadlines left out of next_deadline/1; a PORTSC write keeping the change and
# enable bits it read; a change bit no clear reaches; the install called while the BIOS
# still owns the controller; the BIOS's semaphore never polled again, a start that stalls;
# an interrupt before the controller runs acknowledged at once; a held interrupt
# acknowledged with a failure; a host system error ignored; a host controller error ignored;
# a halt ignored; a running controller's status never read between interrupts; an interrupt
# pass not bounded; the interrupter's pending bit left set when the line is acknowledged;
# that bit cleared only after the event ring is read; a lost command never failing the
# controller; a reported change bit left set by its clear; a change bit cleared that no
# status read reported; one port's reported changes taken as another's; and every add of a
# configuration posted in one Configure Endpoint, past the adds one carries; and the pipes
# of a configuration's first part lost when the next part is posted.
class ErxXhciCoreSeedsTest < Minitest::Test
  EXPLORED = 'the_pipe_machine_is_explored_to_a_fixed_point_test_'
  ADDRESS_EXPLORED = 'the_failed_address_is_explored_to_a_fixed_point_test_'
  START_EXPLORED = 'the_start_is_explored_to_a_fixed_point_test_'
  STATUS = 'the_status_of_a_running_controller_is_read_each_second_test'
  PORTS_EXPLORED = 'the_root_port_machine_is_explored_to_a_fixed_point_test'
  OWN_PORT = 'a_port_keeps_its_own_reported_changes_test'
  CONFIGURE_EXPLORED = 'the_configuration_is_explored_to_a_fixed_point_test_'
  LEVEL_LINE = 'a_level_line_neither_storms_nor_loses_an_event_test'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'Reset Endpoint issued on a stopped queue',
             anchor: 'replan(Pipe, Reset, stopped, Acc);',
             replacement: 'replan(Pipe, Reset, halted, Acc);',
             catching_case: EXPLORED),
    Seed.new(fault: 'a stopped EP0 dropped and added',
             anchor: "plan(stopped, \#{type := control}, _Device) ->\n    [set_tr_dequeue];",
             replacement: "plan(stopped, \#{type := control}, _Device) ->\n    [drop_add];",
             catching_case: EXPLORED),
    Seed.new(fault: "the translator's clear skipped",
             anchor: '[clear_tt || buffered_in_tt(Endpoint, Device)]',
             replacement: '[clear_tt || buffered_in_tt(Endpoint, Device) andalso false]',
             catching_case: EXPLORED),
    Seed.new(fault: 'a waiting Stop Endpoint kept when its endpoint halts',
             anchor: 'false -> replan(Pipe, Reset, halted, Acc)',
             replacement: 'false -> replan(Pipe, Reset, busy, Acc)',
             catching_case: EXPLORED),
    Seed.new(fault: 'the requests waiting on a pipe that leaves open dropped',
             anchor: 'Left, Waiting).',
             replacement: 'Left, []).',
             catching_case: 'ep0_is_reset_before_its_halted_request_is_answered_test'),
    Seed.new(fault: 'Disable Slot posted while a queue of the slot runs a posted transfer',
             anchor: 'activity(Pipe, open, Acc) -> running_if_posted(Pipe, Acc);',
             replacement: 'activity(_Pipe, open, _Acc) -> quiet;',
             catching_case: EXPLORED),
    Seed.new(fault: 'Disable Slot posted before the stops',
             anchor: '[Dci | _] -> {ok, {stop_endpoint, Slot, Dci}};',
             replacement: '[_Dci | _] -> {ok, {disable_slot, Slot}};',
             catching_case: EXPLORED),
    Seed.new(fault: 'a halt on a draining queue left running, so the teardown stops a halted queue',
             anchor: "        {true, \#{Pipe := \#{state := {draining, running}}}} ->\n" \
                     "            answer(Requester, Result, set_pipe(Pipe, {draining, quiet}, Acc));\n",
             replacement: '',
             catching_case: 'a_halt_while_the_teardown_waits_leaves_the_queue_unstopped_test'),
    Seed.new(fault: 'a detach that frees the slot without Disable Slot',
             anchor: '#{Ref := Slot} when is_integer(Slot) -> tear_down(Slot, nothing, Unbound);',
             replacement: "\#{Ref := Slot} when is_integer(Slot) ->\n" \
                          "            {Us, Ua} = Unbound, {Us\#{slots := maps:remove(Slot, maps:get(slots, Us))}, Ua};",
             catching_case: EXPLORED),
    Seed.new(fault: "a reset in progress at the detach left unanswered",
             anchor: 'answer(asked_by(Requester), {error, gone}, set_pipe(Pipe, {draining, Activity}, Acc));',
             replacement: 'set_pipe(Pipe, {draining, Activity}, Acc);',
             catching_case: EXPLORED),
    Seed.new(fault: 'a detached reference left bound, so it reaches the next device on its slot',
             anchor: 'Unbound = {S#{refs := maps:remove(Ref, Refs)}, A},',
             replacement: 'Unbound = {S, A},',
             catching_case: 'a_detached_device_is_torn_down_and_its_reference_stays_gone_test'),
    Seed.new(fault: "a reset step's answer taken by a later reset of a pipe of the same name on a slot enabled again",
             anchor: '        true -> step_answered(Pipe, Answer, Acc);
        false -> Acc',
             replacement: '        _ -> step_answered(Pipe, Answer, Acc)',
             catching_case: 'a_reset_step_answered_after_its_slot_is_reused_is_stale_test'),
    Seed.new(fault: 'a slot nobody owns left enabled',
             anchor: '#{} -> answer({bus, Request}, {error, gone}, tear_down(Slot, nothing, Enabled))',
             replacement: '#{} -> answer({bus, Request}, {error, gone}, Enabled)',
             catching_case: 'a_slot_nobody_owns_is_disabled_test'),
    Seed.new(fault: 'an Enable Slot naming a slot still held taken',
             anchor: 'when is_map_key(Slot, Slots) ->',
             replacement: 'when is_map_key(Slot, Slots), Slot < 0 ->',
             catching_case: 'the_controller_fails_on_a_malformed_answer_or_a_lost_command_test'),
    Seed.new(fault: 'an Address Device whose device detached while it was posted left unanswered',
             anchor: '    answer({bus, Request}, {ok, Address}, Added);',
             replacement: "    case live(Ref, Slot, S) of true -> answer({bus, Request}, {ok, Address}, Added); " \
                          'false -> Added end;',
             catching_case: ADDRESS_EXPLORED),
    Seed.new(fault: "the translator's clear skipped after a failed address on a transaction error",
             anchor: '{TransactionError, #{}} ->',
             replacement: '{TransactionError, never} ->',
             catching_case: ADDRESS_EXPLORED),
    Seed.new(fault: 'the abort answered after Stop Endpoint alone, so the next request finds EP0 stopped',
             anchor: 'replan(Pipe, Reset, stopped, Acc);',
             replacement: "case Reset of \#{requester := {abort, _}} -> finish(Pipe, ok, Acc); " \
                          '_ -> replan(Pipe, Reset, stopped, Acc) end;',
             catching_case: EXPLORED),
    Seed.new(fault: "the aborted request's own completion answered as well",
             anchor: '{S#{inflight := Inflight#{Tag := {Pipe, aborted, none}}}, A}',
             replacement: '{S#{inflight := Inflight#{Tag := {Pipe, Requester, none}}}, A}',
             catching_case: EXPLORED),
    Seed.new(fault: 'the control deadlines left out of next_deadline/1',
             anchor: 'Control = [At || {_Pipe, _Requester, At} <- maps:values(Inflight)],',
             replacement: 'Control = [none || maps:size(Inflight) < 0],',
             catching_case: 'an_unanswered_control_request_is_aborted_test'),
    Seed.new(fault: 'a PORTSC write keeping the change and enable bits it read',
             anchor: '(Read band Preserve band bnot Mask) bor Bits',
             replacement: '(Read band bnot Preserve band bnot Mask) bor Bits',
             catching_case: 'portsc_writes_set_only_what_they_mean_test'),
    Seed.new(fault: 'the configuration error change behind no clear',
             anchor: '?ERX_HW_XHCI_PORTSC_PEC_MASK bor ?ERX_HW_XHCI_PORTSC_CEC_MASK',
             replacement: '?ERX_HW_XHCI_PORTSC_PEC_MASK',
             catching_case: 'every_change_bit_can_be_cleared_test'),
    Seed.new(fault: 'the install called while the BIOS still owns the controller',
             anchor: '?ERX_HW_XHCI_BIOS_OWNED_OWNED_GET(Byte) =:= 0 -> install(Now, Acc);',
             replacement: '?ERX_HW_XHCI_BIOS_OWNED_OWNED_GET(Byte) >= 0 -> install(Now, Acc);',
             catching_case: START_EXPLORED),
    Seed.new(fault: 'a host system error ignored',
             anchor: '?ERX_HW_XHCI_USBSTS_HSE_GET(Status) =/= 0 -> host_system_error;',
             replacement: '?ERX_HW_XHCI_USBSTS_HSE_GET(Status) =:= 2 -> host_system_error;',
             catching_case: 'an_interrupt_pass_test'),
    Seed.new(fault: 'a host controller error ignored',
             anchor: '?ERX_HW_XHCI_USBSTS_HCE_GET(Status) =/= 0 -> host_controller_error;',
             replacement: '?ERX_HW_XHCI_USBSTS_HCE_GET(Status) =:= 2 -> host_controller_error;',
             catching_case: STATUS),
    Seed.new(fault: 'a halt ignored',
             anchor: '?ERX_HW_XHCI_USBSTS_HCH_GET(Status) =/= 0 -> host_controller_halted;',
             replacement: '?ERX_HW_XHCI_USBSTS_HCH_GET(Status) =:= 2 -> host_controller_halted;',
             catching_case: STATUS),
    Seed.new(fault: "a running controller's status never read between interrupts",
             anchor: 'phase_deadline({running, At}) -> At;',
             replacement: 'phase_deadline({running, _At}) -> none;',
             catching_case: STATUS),
    Seed.new(fault: 'the command deadline dropped',
             anchor: "when At =< Now ->\n    emit({fail, {command_timeout, Command}}, Acc);",
             replacement: "when At =< Now, false ->\n    emit({fail, {command_timeout, Command}}, Acc);",
             catching_case: 'the_controller_fails_on_a_malformed_answer_or_a_lost_command_test'),
    Seed.new(fault: "the BIOS's semaphore never polled again",
             anchor: 'true -> set_phase({bios_handoff, GiveUp, {poll, Now + ?ERX_XHCI_POLL_MS}}, Acc)',
             replacement: 'true -> set_phase({bios_handoff, GiveUp, reading}, Acc)',
             catching_case: START_EXPLORED),
    Seed.new(fault: 'an interrupt before the controller runs acknowledged at once',
             anchor: "event(interrupt, _Now, {S, A}) ->\n    {S\#{line := held}, A};",
             replacement: "event(interrupt, _Now, Acc) ->\n    emit(ack, Acc);",
             catching_case: START_EXPLORED),
    Seed.new(fault: 'an interrupt pass not bounded',
             anchor: 'Count =:= 0; Events >= ?ERX_XHCI_EVENTS_PER_INTERRUPT ->',
             replacement: 'Count =:= 0 ->',
             catching_case: 'an_interrupt_pass_is_bounded_test'),
    Seed.new(fault: "the interrupter's pending bit left set when the line is acknowledged",
             anchor: 'Cleared = emit({write, iman, modify(Iman, ?ERX_HW_XHCI_IMAN_PRESERVE, Ip, Ip)},',
             replacement: 'Cleared = emit({write, iman, modify(Iman, ?ERX_HW_XHCI_IMAN_PRESERVE, Ip, 0)},',
             catching_case: LEVEL_LINE),
    Seed.new(fault: "the interrupter's pending bit cleared only after the event ring is read",
             anchor: "            emit(complete, set_line({draining, 0}, Cleared));",
             replacement: "            {S1, A1} = set_line({draining, 0}, Acc), {_, [Iman1, Usbsts1 | _]} = Cleared,\n" \
                          "            {S1, [Iman1, Usbsts1, complete | A1]};",
             catching_case: LEVEL_LINE),
    Seed.new(fault: 'a held interrupt acknowledged with a failure',
             anchor: 'Fails -> {Next, [lists:last(Fails)]}',
             replacement: "Fails -> {_, Owed} = release_line({Next, []}), {Next, Owed ++ [lists:last(Fails)]}",
             catching_case: START_EXPLORED),
    Seed.new(fault: 'a reported change bit not cleared (the USB 2 word kept as the PORTSC bits)',
             anchor: 'Word band change_bits()};',
             replacement: 'port_changes(Word)};',
             catching_case: PORTS_EXPLORED),
    Seed.new(fault: 'a change bit cleared that was not reported',
             anchor: 'Clear = Bits band Reported,',
             replacement: 'Clear = Bits,',
             catching_case: PORTS_EXPLORED),
    Seed.new(fault: "a port's reset change taken as another port's",
             anchor: 'reported := Reported#{Port => StillReported}',
             replacement: 'reported := Reported#{1 => StillReported}',
             catching_case: OWN_PORT),
    Seed.new(fault: 'every add of a configuration posted in one Configure Endpoint',
             anchor: 'lists:split(min(length(Add), ?ERX_XHCI_CONFIGURE_ADDS_MAX), Add).',
             replacement: '{Add, []}.',
             catching_case: CONFIGURE_EXPLORED),
    Seed.new(fault: "the pipes of a configuration's first part lost when the next is posted",
             anchor: 'Config#{add := Left}}}, Added)',
             replacement: 'Config#{add := Left}}}, Acc)',
             catching_case: CONFIGURE_EXPLORED)
  ].freeze

  # Seeds run WORKERS at a time, each against only the case named for it.
  WORKERS = 4

  # A seed's run that raised, naming the seed.
  class SeedError < Erx::Error; end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, XhciCoreCases::CORE))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
    end
    assert_catching_cases_pass_unseeded
    runs = in_parallel(SEEDS) do |seed|
      XhciCoreCases.run(replaced: { XhciCoreCases::CORE => source.sub(seed.anchor) { seed.replacement } },
                        cases: [seed.catching_case])
    end
    SEEDS.zip(runs).each do |seed, (output, status)|
      refute status.success?, "#{seed.fault}: the case passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  # A case that fails alone, unseeded, would "catch" every seed vacuously.
  def assert_catching_cases_pass_unseeded
    cases = SEEDS.map(&:catching_case).uniq
    output, status = XhciCoreCases.run(cases: cases)
    return if status.success?

    failed = cases.select { |name| output.match?(/#{Regexp.escape(name)}[^\n]*\*failed\*/) }
    flunk "cases that fail unseeded: #{failed.join(', ')}\n#{output}"
  end

  # The block's value for each of items, in order, WORKERS at a time. Every worker
  # finishes before a block's failure is raised, as a SeedError naming the item.
  def in_parallel(items)
    pending = Queue.new
    items.each_index { |index| pending << index }
    pending.close
    results = Array.new(items.size)
    Array.new(WORKERS) do
      Thread.new do
        while (index = pending.pop)
          results[index] = begin
            yield items[index]
          rescue StandardError => e
            e
          end
        end
      end
    end.each(&:join)
    failure = results.zip(items).find { |result, _| result.is_a?(StandardError) }
    raise SeedError, "#{failure[1].fault}: #{failure[0].class}: #{failure[0].message}" if failure

    results
  end
end
