# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_hci_tests.erl, the cases of H4 framing (erx_h4), the HCI codec
# (erx_hci) and the controller process's core (erx_bt_hci_core), compiled from source on
# stock's emulator (ERX_ERL and ERX_ERLC). Then each seeded fault of
# docs/design-bluetooth.md, "Host tests of the cores", applied to a copy of its module,
# must fail the case named for it.
#
# Two of the design's seeds cannot be written against this core, which makes their
# faults unrepresentable: the ACL bound taken from LE Read Buffer Size (erx_h4:split/1
# takes no bound; the bound is the constant bt_acl_rx_max), and credits not returned at
# disconnection (the free credits are the buffer count less the live handles' packets in
# flight, so removing a handle returns its packets). In the second's place the handle is
# kept live after its Disconnection Complete. Nor can a second deadline armed or a
# deadline cancelled that was never armed: each deadline is a field of the slot's state
# it guards, so leaving the state drops it and there is no second one to arm.
class ErxBtHciTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_bt_hci_tests.erl].freeze
  DEADLINE_SECONDS = '300'
  H4 = 'erlang/apps/erx_bt/src/erx_h4.erl'
  CORE = 'erlang/apps/erx_bt/src/erx_bt_hci_core.erl'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the indicator check removed, so an unknown byte is skipped',
             module_path: H4,
             anchor: "split(<<Indicator, _/binary>>, _Packets) ->\n    {error, {bad_indicator, Indicator}};",
             replacement: "split(<<_, Rest/binary>>, Packets) ->\n    split(Rest, Packets);",
             catching_case: 'unknown_indicator_is_an_error_test'),
    Seed.new(fault: 'the ACL length read as one byte',
             module_path: H4,
             anchor: 'Word:16/little, Length:16/little, Data:Length/binary',
             replacement: 'Word:16/little, _:8, Length:8, Data:Length/binary',
             catching_case: 'a_stream_cut_anywhere_splits_the_same_test'),
    Seed.new(fault: 'the ACL bound one octet too long',
             module_path: H4,
             anchor: 'when Length > ?ERX_BT_ACL_RX_MAX ->',
             replacement: 'when Length > ?ERX_BT_ACL_RX_MAX + 1 ->',
             catching_case: 'acl_of_252_octets_is_an_error_test'),
    Seed.new(fault: 'the command slot not cleared by Command Status',
             module_path: CORE,
             anchor: 'answered(Label, Command, Answer, Core#core{slot = idle});',
             replacement: 'answered(Label, Command, Answer, case Answer of {status, _} -> Core; _ -> ' \
                          'Core#core{slot = idle} end);',
             catching_case: 'a_disconnect_answered_by_status_frees_the_slot_test'),
    Seed.new(fault: 'a handle kept live after its Disconnection Complete',
             module_path: CORE,
             anchor: 'Core#core{links = maps:remove(Handle, Links),',
             replacement: 'Core#core{links = Links,',
             catching_case: 'disconnection_returns_a_handles_packets_test'),
    Seed.new(fault: "a completion's count taken without the in-flight bound",
             module_path: CORE,
             anchor: '#{Handle := {Serial, InFlight}} when Count =< InFlight - Queued ->',
             replacement: '#{Handle := {Serial, InFlight}} ->',
             catching_case: 'a_forged_completion_stops_test'),
    Seed.new(fault: 'advertising not enabled again after a disconnection',
             module_path: CORE,
             anchor: 'Core#core{links = maps:remove(Handle, Links),',
             replacement: 'Core#core{advertising = true, links = maps:remove(Handle, Links),',
             catching_case: 'advertising_resumes_after_a_disconnection_test'),
    Seed.new(fault: "a completion's bound counting packets still on the writer's list",
             module_path: CORE,
             anchor: 'when Count =< InFlight - Queued ->',
             replacement: 'when Count =< InFlight ->',
             catching_case: 'a_completion_of_a_queued_packet_stops_test'),
    Seed.new(fault: 'the deadline armed only once the controller allows the command',
             module_path: CORE,
             anchor: "        _ -> {[], Core#core{slot = {due, Now + ?ERX_BT_COMMAND_TIMEOUT_MS}}}\n",
             replacement: "        _ when Core#core.allowed =:= 0 -> {[], Core};\n" \
                          "        _ -> {[], Core#core{slot = {due, Now + ?ERX_BT_COMMAND_TIMEOUT_MS}}}\n",
             catching_case: 'a_command_the_controller_never_allows_stops_on_its_deadline_test'),
    Seed.new(fault: 'the connection limit kept above the buffer count',
             module_path: CORE,
             anchor: 'limit = min(Limit, Credits)}',
             replacement: 'limit = Limit}',
             catching_case: 'fewer_buffers_than_connections_lower_the_limit_test'),
    Seed.new(fault: "LE's 27-octet minimum applied to Read Buffer Size",
             module_path: CORE,
             anchor: 'bringup(shared_buffers, {Length, Packets}, Core) when Length > 0, Packets > 0 ->',
             replacement: 'bringup(shared_buffers, {Length, Packets}, Core) when Length >= 27, Packets > 0 ->',
             catching_case: 'shared_buffers_take_any_length_from_one_test'),
    Seed.new(fault: "a handle's disconnect kept after its Disconnection Complete, so it reaches the next peer",
             module_path: CORE,
             anchor: 'disconnects = lists:keydelete(Handle, 1, Core#core.disconnects)}};',
             replacement: 'disconnects = Core#core.disconnects}};',
             catching_case: 'explored_core_keeps_its_invariants_test_'),
    Seed.new(fault: "a connection before the advertising enable's answer leaving advertising on",
             module_path: CORE,
             anchor: 'overtaken({sent, advertise, Command, Opcode, Deadline}) -> {sent, advertise_overtaken, Command, Opcode, Deadline};',
             replacement: 'overtaken({sent, advertise, Command, Opcode, Deadline}) -> {sent, advertise, Command, Opcode, Deadline};',
             catching_case: 'explored_core_keeps_its_invariants_test_'),
    Seed.new(fault: 'a connection accepted on a handle whose disconnect is handed over and unanswered',
             module_path: CORE,
             anchor: "connected(Handle, _Info, #core{slot = {sent, {disconnect, Handle}, _, _, _}}) ->\n" \
                     "    stop({connection_while_disconnecting, Handle});\n",
             replacement: '',
             catching_case: 'a_connection_on_a_handle_being_disconnected_stops_test'),
    Seed.new(fault: 'any failed disconnect taken as the handle gone',
             module_path: CORE,
             anchor: '        Failed -> stop({disconnect_failed, Handle, Failed})',
             replacement: '        _Failed -> {[], Core}',
             catching_case: 'a_disconnect_is_asked_once_and_its_failure_stops_test'),
    Seed.new(fault: "the line's reset under no deadline",
             module_path: CORE,
             anchor: '{line_reset, Deadline} -> Deadline;',
             replacement: '{line_reset, _Deadline} -> infinity;',
             catching_case: 'a_line_reset_that_never_ends_stops_test'),
    Seed.new(fault: 'the due deadline restarted on every input, so repeated traffic holds a command off',
             module_path: CORE,
             anchor: "command(_Now, #core{slot = {due, _}} = Core) ->\n    case due(Core) of\n" \
                     "        none -> {[], Core#core{slot = idle}};\n        _ -> {[], Core}\n",
             replacement: "command(Now, #core{slot = {due, _}} = Core) ->\n    case due(Core) of\n" \
                          "        none -> {[], Core#core{slot = idle}};\n" \
                          "        _ -> {[], Core#core{slot = {due, Now + ?ERX_BT_COMMAND_TIMEOUT_MS}}}\n",
             catching_case: 'explored_core_keeps_its_invariants_test_'),
    Seed.new(fault: 'a deadline passed only after its instant',
             module_path: CORE,
             anchor: 'case next_deadline(Core) =< Now of',
             replacement: 'case next_deadline(Core) < Now of',
             catching_case: 'explored_core_keeps_its_invariants_test_'),
    Seed.new(fault: 'a deadline passed a millisecond early',
             module_path: CORE,
             anchor: 'case next_deadline(Core) =< Now of',
             replacement: 'case next_deadline(Core) =< Now + 1 of',
             catching_case: 'explored_core_keeps_its_invariants_test_'),
    Seed.new(fault: "a request's link identity ignored, so a gone link's packet reaches its handle's next peer",
             module_path: CORE,
             anchor: "current({Handle, Serial}, #core{links = Links}) ->\n    case Links of\n" \
                     "        \#{Handle := {Serial, InFlight}} -> {current, InFlight};",
             replacement: "current({Handle, _Serial}, #core{links = Links}) ->\n    case Links of\n" \
                          "        \#{Handle := {_, InFlight}} -> {current, InFlight};",
             catching_case: 'explored_core_keeps_its_invariants_test_')
  ].freeze

  def test_bluetooth_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.module_path))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.module_path => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  # The modules, with replaced ones in place of the application's own, then the cases.
  def run_cases(replaced)
    Dir.mktmpdir('erx-bt-hci-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_bt_hci_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
