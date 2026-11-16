%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_h4, erx_hci and erx_bt_hci_core (docs/design-bluetooth.md,
%% "Verification"). Every number is written out here, so a value changed in
%% abi/formats/bluetooth.txt fails a case. The explored case walks every state the core
%% reaches from start against a controller that may answer each command well, badly or
%% not at all, and checks the core's invariants on every transition.
-module(erx_bt_hci_tests).

-include_lib("eunit/include/eunit.hrl").

-define(READY_CONFIG(Limit), config(Limit)).

%% erx_h4.

a_stream_cut_anywhere_splits_the_same_test() ->
    Stream = <<4, 16#0E, 4, 1, 3, 16#0C, 0,                      % Command Complete for HCI_Reset
               2, 16#40, 16#20, 5, 0, 1, 0, 4, 0, 16#AA,         % ACL on handle 0x040, start
               4, 16#13, 5, 1, 16#40, 0, 1, 0>>,                 % Number Of Completed Packets
    {Whole, <<>>} = erx_h4:split(Stream),
    ?assertEqual([{event, 16#0E, <<1, 3, 16#0C, 0>>}, {acl, 16#040, 2, 0, <<1, 0, 4, 0, 16#AA>>},
                  {event, 16#13, <<1, 16#40, 0, 1, 0>>}], Whole),
    [begin
         <<Head:Cut/binary, Tail/binary>> = Stream,
         {First, Rest} = erx_h4:split(Head),
         {Second, <<>>} = erx_h4:split(<<Rest/binary, Tail/binary>>),
         ?assertEqual(Whole, First ++ Second)
     end || Cut <- lists:seq(0, byte_size(Stream))].

unknown_indicator_is_an_error_test() ->
    ?assertEqual({error, {bad_indicator, 3}}, erx_h4:split(<<3, 1, 0, 0>>)),
    ?assertEqual({error, {bad_indicator, 1}}, erx_h4:split(<<4, 16#10, 1, 0, 1, 3, 16#0C, 0>>)).

acl_of_251_octets_splits_test() ->
    Data = binary:copy(<<7>>, 251),
    ?assertMatch({[{acl, 1, 2, 0, Data}], <<>>}, erx_h4:split(<<2, 1, 16#20, 251, 0, Data/binary>>)).

acl_of_252_octets_is_an_error_test() ->
    %% Refused at its header, before its data arrive.
    ?assertEqual({error, {acl_too_long, 252}}, erx_h4:split(<<2, 1, 16#20, 252, 0>>)),
    ?assertEqual({error, {acl_too_long, 16#0100}}, erx_h4:split(<<2, 1, 16#20, 0, 1>>)).

framing_round_trips_test() ->
    ?assertEqual(<<1, 3, 16#0C, 0>>, erx_h4:command(16#0C03, <<>>)),
    ?assertEqual(<<2, 16#41, 0, 2, 0, 9, 9>>, erx_h4:acl(16#041, 0, <<9, 9>>)).

%% erx_hci.

opcodes_are_ogf_and_ocf_test() ->
    ?assertEqual([16#0C03, 16#0C01, 16#0C33, 16#1001, 16#1002, 16#1005, 16#1009, 16#2001, 16#2002, 16#2003,
                  16#2005, 16#2006, 16#2008, 16#2009, 16#200A, 16#0406],
                 [erx_hci:opcode(Name) || Name <- [reset, set_event_mask, host_buffer_size, read_local_version,
                                                   read_local_commands, read_buffer_size, read_bd_addr,
                                                   le_set_event_mask, le_read_buffer_size, le_read_features,
                                                   le_set_random_address, le_set_advertising_parameters,
                                                   le_set_advertising_data, le_set_scan_response_data,
                                                   le_set_advertising_enable, disconnect]]).

command_parameters_test() ->
    ?assertEqual({16#0C33, <<251, 0, 0, 8, 0, 0, 0>>}, erx_hci:command({host_buffer_size, 251, 8})),
    ?assertEqual({16#2005, <<5, 4, 3, 2, 1, 16#C0>>}, erx_hci:command({le_set_random_address, <<16#C0, 1, 2, 3, 4, 5>>})),
    ?assertEqual({16#2006, <<160, 0, 160, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 7, 0>>},
                 erx_hci:command({le_set_advertising_parameters, 160})),
    {16#2008, <<3, 2, 1, 6, Zeros/binary>>} = erx_hci:command({le_set_advertising_data, <<2, 1, 6>>}),
    ?assertEqual(binary:copy(<<0>>, 28), Zeros),
    ?assertEqual({16#0406, <<16#41, 0, 16#13>>}, erx_hci:command({disconnect, 16#41, 16#13})).

events_decode_test() ->
    ?assertEqual({command_complete, 1, 16#0C03, <<0>>}, erx_hci:event(16#0E, <<1, 3, 16#0C, 0>>)),
    ?assertEqual({command_status, 0, 1, 16#0406}, erx_hci:event(16#0F, <<0, 1, 6, 4>>)),
    ?assertEqual({disconnection_complete, 0, 16#40, 16#13}, erx_hci:event(16#05, <<0, 16#40, 16#F0, 16#13>>)),
    ?assertEqual({number_of_completed_packets, [{1, 2}, {3, 4}]},
                 erx_hci:event(16#13, <<2, 1, 0, 2, 0, 3, 0, 4, 0>>)),
    ?assertEqual({hardware_error, 9}, erx_hci:event(16#10, <<9>>)),
    ?assertMatch({le_connection_complete, 0, 16#40, #{role := 1, peer := <<6, 5, 4, 3, 2, 1>>}},
                 erx_hci:event(16#3E, <<1, 0, 16#40, 0, 1, 0, 1, 2, 3, 4, 5, 6, 24, 0, 0, 0, 16#48, 0, 0>>)),
    ?assertEqual({le_long_term_key_request, 16#40, <<0:64>>, 0}, erx_hci:event(16#3E, <<5, 16#40, 0, 0:64, 0:16>>)).

wrong_lengths_are_malformed_and_unknown_codes_are_named_test() ->
    ?assertEqual(malformed, erx_hci:event(16#13, <<2, 1, 0, 2, 0>>)),
    ?assertEqual(malformed, erx_hci:event(16#13, <<1, 1, 0, 2, 0, 0>>)),
    ?assertEqual(malformed, erx_hci:event(16#05, <<0, 1, 0>>)),
    ?assertEqual(malformed, erx_hci:event(16#3E, <<1, 0>>)),
    ?assertEqual(malformed, erx_hci:event(16#05, <<0, 0, 16#0F, 16#13>>)),
    ?assertEqual({unknown, 16#FF}, erx_hci:event(16#FF, <<1, 2, 3>>)),
    ?assertEqual({unknown, {le_meta, 16#02}}, erx_hci:event(16#3E, <<2, 0>>)).

returns_decode_test() ->
    ?assertEqual({ok, #{hci_version => 9, hci_subversion => 16#0102, lmp_version => 9, company => 15,
                        lmp_subversion => 16#0304}},
                 erx_hci:return(read_local_version, <<0, 9, 2, 1, 9, 15, 0, 4, 3>>)),
    ?assertEqual({ok, {27, 4}}, erx_hci:return(le_read_buffer_size, <<0, 27, 0, 4>>)),
    ?assertEqual({failed, 12}, erx_hci:return(le_read_buffer_size, <<12>>)),
    ?assertEqual(malformed, erx_hci:return(le_read_buffer_size, <<0, 27, 0>>)),
    ?assertEqual(malformed, erx_hci:return(reset, <<>>)),
    ?assertEqual(malformed, erx_hci:return(le_read_buffer_size, <<0>>)),
    ?assertEqual(malformed, erx_hci:return(read_local_version, <<0>>)).

%% erx_bt_hci_core, case by case. A controller answers through answer/2.

bringup_reaches_ready_with_advertising_test() ->
    {Actions, Core} = ready(1),
    ?assert(lists:keymember(ready, 1, Actions)),
    ?assertMatch(#{advertising := true, free := 4, read_local_version := #{company := 15}},
                 erx_bt_hci_core:facts(Core)).

a_failed_step_stops_with_its_label_and_status_test() ->
    {_, Core} = to_command(16#2002, new(1)),
    ?assertEqual({stop, {step_failed, buffers, 12}}, answer(Core, complete(16#2002, <<12>>))).

an_answer_naming_another_command_stops_test() ->
    {_, Core} = to_command(16#0C03, new(1)),
    ?assertEqual({stop, {answer_to_other_command, 16#1001}}, answer(Core, complete(16#1001, <<0>>))).

opcode_zero_only_updates_the_count_test() ->
    {_, Core} = to_command(16#0C03, new(1)),
    {ok, [], Same} = answer(Core, {command_complete, 1, 0, <<>>}),
    ?assertMatch({ok, _, _}, answer(Same, complete(16#0C03, <<0>>))).

an_unanswered_command_stops_test() ->
    {Actions, Core} = to_command(16#0C03, new(1)),
    ?assert(lists:member({timer, 5000}, Actions)),
    ?assertEqual({stop, {command_timeout, reset}}, erx_bt_hci_core:step(timeout, Core)).

shared_buffers_are_read_with_read_buffer_size_test() ->
    {_, Core} = to_command(16#2002, new(1)),
    {ok, [], Written} = erx_bt_hci_core:step(written, Core),
    {ok, Actions, Next} = answer(Written, complete(16#2002, <<0, 0, 0, 0>>)),
    {_, Shared} = drive(16#1005, Actions, Next),
    {ok, _, Read} = answer(Shared, complete(16#1005, <<0, 27, 0, 0, 6, 0, 0, 0>>)),
    ?assertMatch(#{free := 6}, erx_bt_hci_core:facts(Read)).

reserved_buffer_lengths_stop_test() ->
    {_, Core} = to_command(16#2002, new(1)),
    ?assertEqual({stop, {step_failed, buffers, {buffers, 26, 4}}}, answer(Core, complete(16#2002, <<0, 26, 0, 4>>))).

a_patch_for_another_controller_stops_test() ->
    Patched = erx_bt_hci_core:new((?READY_CONFIG(1))#{patch => #{manufacturer => 305, records => [{16#FC4C, <<1>>}]}}),
    {_, Core} = to_command(16#1001, Patched),
    ?assertEqual({stop, {patch_for_other_controller, 15}}, answer(Core, complete(16#1001, version(15)))).

disconnection_returns_a_handles_packets_test() ->
    {_, Core} = connected(1, 16#40),
    {ok, _, Sent} = erx_bt_hci_core:step({send, 16#40, 0, <<1>>}, Core),
    ?assertMatch(#{free := 3, links := #{16#40 := 1}}, erx_bt_hci_core:facts(Sent)),
    {ok, Actions, Gone} = erx_bt_hci_core:step({event, {disconnection_complete, 0, 16#40, 16#13}}, Sent),
    ?assert(lists:member({link_down, 16#40}, Actions)),
    ?assertMatch(#{free := 4, links := #{}}, erx_bt_hci_core:facts(Gone)).

a_forged_completion_stops_test() ->
    {_, Core} = connected(1, 16#40),
    {ok, _, Sent} = erx_bt_hci_core:step({send, 16#40, 0, <<1>>}, Core),
    ?assertEqual({stop, {completion_beyond_in_flight, 16#40, 2}},
                 erx_bt_hci_core:step({event, {number_of_completed_packets, [{16#40, 2}]}}, Sent)),
    ?assertEqual({stop, {completion_for_dead_handle, 16#41}},
                 erx_bt_hci_core:step({event, {number_of_completed_packets, [{16#41, 1}]}}, Sent)).

a_link_beyond_its_share_is_busy_test() ->
    {_, Core} = connected(2, 16#40),
    {ok, _, One} = erx_bt_hci_core:step({send, 16#40, 0, <<1>>}, Core),
    {ok, _, Two} = erx_bt_hci_core:step({send, 16#40, 1, <<2>>}, One),
    ?assertMatch({ok, [{busy, 16#40}], _}, erx_bt_hci_core:step({send, 16#40, 1, <<3>>}, Two)).

advertising_resumes_after_a_disconnection_test() ->
    {_, Core} = connected(1, 16#40),
    ?assertMatch(#{advertising := false}, erx_bt_hci_core:facts(Core)),
    {ok, Actions, _} = erx_bt_hci_core:step({event, {disconnection_complete, 0, 16#40, 16#13}}, Core),
    ?assert(lists:member({write, <<1, 16#0A, 16#20, 1, 1>>}, Actions)).

a_disconnect_answered_by_status_frees_the_slot_test() ->
    {_, Core} = connected(1, 16#40),
    {ok, Actions, Asked} = erx_bt_hci_core:step({disconnect, 16#40, 16#13}, Core),
    ?assert(lists:member({write, <<1, 6, 4, 3, 16#40, 0, 16#13>>}, Actions)),
    {ok, [], Written} = erx_bt_hci_core:step(written, Asked),
    {ok, [cancel_timer], Answered} = answer(Written, {command_status, 0, 1, 16#0406}),
    {ok, More, _} = erx_bt_hci_core:step({event, {disconnection_complete, 0, 16#40, 16#16}}, Answered),
    ?assert(lists:member({write, <<1, 16#0A, 16#20, 1, 1>>}, More)).

%% A disconnect asked for while the writer holds a packet waits; when its handle goes
%% and the controller gives it to a new peer, the disconnect goes with the old one and
%% the writer's next item is the advertising enable, not a disconnect of the new peer.
a_disconnect_never_reaches_a_reused_handle_test() ->
    {Actions, Core} = connected(2, 1),
    ?assert(lists:member({write, <<1, 16#0A, 16#20, 1, 1>>}, Actions)),
    {ok, [], Written} = erx_bt_hci_core:step(written, Core),
    {ok, [cancel_timer], Advertising} = answer(Written, complete(16#200A, <<0>>)),
    {ok, [{write, <<2, _/binary>>}], Busy} = erx_bt_hci_core:step({send, 1, 0, <<1>>}, Advertising),
    {ok, [{timer, 5000}], Asked} = erx_bt_hci_core:step({disconnect, 1, 16#13}, Busy),
    {ok, _, Gone} = answer(Asked, {disconnection_complete, 0, 1, 16#13}),
    {ok, _, Reused} = answer(Gone, {le_connection_complete, 0, 1, #{}}),
    ?assertEqual({ok, [{write, <<1, 16#0A, 16#20, 1, 1>>}]},
                 element_pair(erx_bt_hci_core:step(written, Reused))).

%% A disconnect keeps its mark until Disconnection Complete: a second request is
%% ignored after the first was answered, Unknown Connection Identifier is the handle
%% already gone, and any other failure stops.
a_disconnect_is_asked_once_and_its_failure_stops_test() ->
    {_, Core} = connected(1, 16#40),
    {ok, _, Asked} = erx_bt_hci_core:step({disconnect, 16#40, 16#13}, Core),
    {ok, [], Written} = erx_bt_hci_core:step(written, Asked),
    {ok, [cancel_timer], Answered} = answer(Written, {command_status, 0, 1, 16#0406}),
    ?assertMatch({ok, [], _}, erx_bt_hci_core:step({disconnect, 16#40, 16#13}, Answered)),
    ?assertMatch({ok, [cancel_timer], _}, answer(Written, {command_status, 2, 1, 16#0406})),
    ?assertEqual({stop, {disconnect_failed, 16#40, {failed, 16#0C}}},
                 answer(Written, {command_status, 16#0C, 1, 16#0406})).

%% A connection that completes while the advertising enable is written and unanswered
%% came from that enable: its answer leaves advertising off, and the disconnection
%% enables it again.
a_connection_before_the_enable_answer_leaves_advertising_off_test() ->
    {_, Core} = to_command(16#200A, new(1)),
    {ok, _, Connected} = answer(Core, {le_connection_complete, 0, 1, #{}}),
    {ok, [], Written} = erx_bt_hci_core:step(written, Connected),
    {ok, [cancel_timer], Answered} = answer(Written, complete(16#200A, <<0>>)),
    ?assertMatch(#{advertising := false}, erx_bt_hci_core:facts(Answered)),
    {ok, Actions, _} = answer(Answered, {disconnection_complete, 0, 1, 16#13}),
    ?assert(lists:member({write, <<1, 16#0A, 16#20, 1, 1>>}, Actions)).

%% The line's reset is under a deadline too, cancelled when the line is ready.
a_line_reset_that_never_ends_stops_test() ->
    {ok, [line_reset, {timer, 5000}], Resetting} = erx_bt_hci_core:step(start, new(1)),
    ?assertEqual({stop, line_reset_timeout}, erx_bt_hci_core:step(timeout, Resetting)),
    ?assertMatch({ok, [cancel_timer, {timer, 5000}, {write, <<1, 3, 16#0C, 0>>}], _},
                 erx_bt_hci_core:step(line_ready, Resetting)).

element_pair({ok, Actions, _Core}) -> {ok, Actions}.

%% Num_HCI_Command_Packets 0: the next command falls due, unsent, under its deadline,
%% which passes unless an opcode-0 event allows it (Part E, 4.4).
a_command_the_controller_never_allows_stops_on_its_deadline_test() ->
    {_, Core} = to_command(16#0C03, new(1)),
    {ok, [], Written} = erx_bt_hci_core:step(written, Core),
    {ok, Actions, Due} = answer(Written, {command_complete, 0, 16#0C03, <<0>>}),
    ?assertEqual([cancel_timer, {timer, 5000}], Actions),
    ?assertEqual({stop, {command_timeout, {first, read_local_version}}}, erx_bt_hci_core:step(timeout, Due)),
    {ok, Allowed, _} = answer(Due, {command_complete, 1, 0, <<>>}),
    ?assertEqual([{write, <<1, 1, 16#10, 0>>}], Allowed).

%% A packet still on the writer's list has not reached the controller, so a completion
%% of it is forged: the list stays within the credits however the line stalls.
a_completion_of_a_queued_packet_stops_test() ->
    {_, Core} = connected(1, 16#40),
    {ok, [{write, _}], One} = erx_bt_hci_core:step({send, 16#40, 0, <<1>>}, Core),
    {ok, [], Two} = erx_bt_hci_core:step({send, 16#40, 0, <<2>>}, One),
    ?assertMatch({ok, [], _}, erx_bt_hci_core:step({event, {number_of_completed_packets, [{16#40, 1}]}}, Two)),
    ?assertEqual({stop, {completion_beyond_in_flight, 16#40, 2}},
                 erx_bt_hci_core:step({event, {number_of_completed_packets, [{16#40, 2}]}}, Two)).

%% A command is in flight once the writer has it: with the line stalled, an answer to
%% the next command, due and not yet written, is forged.
an_answer_to_a_command_not_yet_written_stops_test() ->
    {_, Core} = to_command(16#0C03, new(1)),
    {ok, Actions, Due} = answer(Core, complete(16#0C03, <<0>>)),
    ?assertEqual([cancel_timer, {timer, 5000}], Actions),
    ?assertEqual({stop, {answer_to_other_command, 16#1001}}, answer(Due, complete(16#1001, version(15)))).

fewer_buffers_than_connections_lower_the_limit_test() ->
    {_, Core} = to_command(16#2002, new(2)),
    {ok, _, Read} = answer(Core, complete(16#2002, <<0, 27, 0, 1>>)),
    ?assertMatch(#{limit := 1, free := 1}, erx_bt_hci_core:facts(Read)).

%% LE Read Buffer Size's length 0 also means shared buffers; Read Buffer Size reserves
%% no lengths, but a length or count of 0 is outside its range (7.8.2, 7.4.5).
shared_buffers_take_any_length_from_one_test() ->
    {_, Core} = to_command(16#2002, new(1)),
    {ok, [], Written} = erx_bt_hci_core:step(written, Core),
    {ok, Actions, Next} = answer(Written, complete(16#2002, <<0, 0, 0, 4>>)),
    {_, Shared} = drive(16#1005, Actions, Next),
    {ok, _, Read} = answer(Shared, complete(16#1005, <<0, 8, 0, 0, 3, 0, 0, 0>>)),
    ?assertMatch(#{free := 3}, erx_bt_hci_core:facts(Read)),
    ?assertEqual({stop, {step_failed, shared_buffers, {buffers, 0, 3}}},
                 answer(Shared, complete(16#1005, <<0, 0, 0, 0, 3, 0, 0, 0>>))).

%% The explored case: every state reachable from start, breadth first, until none is
%% left; running out of the budget first fails. The world is the core and what the
%% process and the controller hold: whether the line is being reset, the writer's item,
%% the command written and not yet answered, whether the one deadline is armed, and the
%% live handles whose disconnect was asked for since they connected. No timer token or
%% counter is in the state, so the states are finite. From start, at each state the line,
%% the controller and the clock may: finish the line's reset; take the writer's item; let
%% the deadline pass; answer the command written well (and allowing one more command or
%% none), with a failed status, with another command's opcode, or by Command Status;
%% send an opcode-0 event allowing one command or none; report a hardware error or a
%% malformed event; once, an event or ACL packet the core drops; connect, during the
%% bring-up, while advertising, or while the advertising enable is written and not yet
%% answered; and for each live handle, disconnect it from either side, take or deliver a
%% packet, and complete packets truly or falsely. The invariants hold on every
%% transition; every state before ready has its deadline armed, so every path ends in
%% ready or a stop; a path patches at most once; a written disconnect names a handle
%% whose disconnect was asked for since it last connected; advertising is never on at
%% the limit in force, and at quiescence it is on exactly while connections are below
%% it.
-record(world, {core, line = none, writer = idle, command = none, deadline = false, asked = #{}, patches = 0,
                ready = false}).

%% About 11,000 states for each configuration explored.
-define(EXPLORE_BUDGET, 100000).

explored_core_keeps_its_invariants_test_() ->
    {timeout, 60, fun() ->
        Patched = (?READY_CONFIG(2))#{patch => #{manufacturer => 15, records => [{16#FC4C, <<1, 2>>}, {16#FC4E, <<>>}]}},
        [explore(Config) || Config <- [?READY_CONFIG(2), Patched]]
    end}.

explore(Config) ->
    {ok, Actions, Core} = erx_bt_hci_core:step(start, erx_bt_hci_core:new(Config)),
    Start = observe(Actions, #world{core = Core}),
    {exhausted, Stats} = walk(queue:from_list([Start]), sets:from_list([key(Start)], [{version, 2}]),
                              #{ready => 0, stops => #{}}, ?EXPLORE_BUDGET),
    ?assert(maps:get(ready, Stats) > 0),
    ?assertEqual([answer_to_other_command, command_timeout, completion_beyond_in_flight, completion_for_dead_handle,
                  connection_beyond_limit, connection_during_bringup, disconnect_failed, duplicate_handle,
                  hardware_error, line_reset_timeout, malformed_event, step_failed],
                 lists:sort(maps:keys(maps:get(stops, Stats)))).

walk(Queue, Seen, Stats, Budget) ->
    case queue:out(Queue) of
        {empty, _} -> {exhausted, Stats};
        {_, _} when Budget =:= 0 -> {budget_spent, Stats};
        {{value, World}, Rest} ->
            check_progress(World),
            check_quiescent(World),
            {Queue1, Seen1, Stats1} = lists:foldl(fun(Input, Acc) -> visit(World, Input, Acc) end,
                                                  {Rest, Seen, count_ready(World, Stats)}, inputs(World)),
            walk(Queue1, Seen1, Stats1, Budget - 1)
    end.

visit(World, Input, {Queue, Seen, Stats}) ->
    case erx_bt_hci_core:step(Input, World#world.core) of
        {stop, Reason} ->
            ?assertNotMatch({unexpected_input, _}, Reason),
            {Queue, Seen, Stats#{stops := maps:update_with(element(1, tuple(Reason)), fun(N) -> N + 1 end, 1,
                                                          maps:get(stops, Stats))}};
        {ok, Actions, Core} ->
            check_deadline_kept(Input, Actions),
            Next = observe(Actions, (consume(Input, World))#world{core = Core}),
            check(Next),
            Key = key(Next),
            case sets:is_element(Key, Seen) of
                true -> {Queue, Seen, Stats};
                false -> {queue:in(Next, Queue), sets:add_element(Key, Seen), Stats}
            end
    end.

tuple(Reason) when is_tuple(Reason) -> Reason;
tuple(Reason) -> {Reason}.

key(#world{core = Core, line = Line, writer = Writer, command = Command, deadline = Deadline, asked = Asked,
           patches = Patches}) ->
    {Core, Line, Writer, Command, Deadline, Asked, Patches}.

count_ready(#world{ready = true}, #{ready := N} = Stats) -> Stats#{ready := N + 1};
count_ready(_, Stats) -> Stats.

%% What the line, the controller and the clock may do next. Left out: a dropped input
%% after the first, since the count is all it changes; a new connection while
%% advertising is off with no enable written and unanswered, which a controller sends
%% only from advertising; and an answer to a command due and not yet written, which a
%% case gives.
inputs(#world{core = Core, line = Line, writer = Writer, command = Command, deadline = Deadline, ready = Ready}) ->
    #{links := Links, advertising := Advertising, dropped := Dropped, limit := Limit} = erx_bt_hci_core:facts(Core),
    Enabling = element(1, tuple(Command)) =:= 16#200A,
    [line_ready || Line =:= resetting] ++
        [written || Writer =:= busy] ++
        [timeout || Deadline] ++
        answers(Command) ++
        [{event, {command_complete, Allowed, 0, <<>>}} || Allowed <- [0, 1]] ++
        [{event, {hardware_error, 1}}, {event, malformed}] ++
        [Drop || Dropped =:= 0, Drop <- [{event, {unknown, 16#FF}}, {acl, 3, 2, 0, <<1>>},
                                         {event, {disconnection_complete, 0, 3, 16#13}}]] ++
        [{event, {le_connection_complete, 0, Handle, #{}}} || Advertising orelse Enabling orelse not Ready,
                                                              Handle <- [1, 2],
                                                              not is_map_key(Handle, Links)] ++
        [{event, {le_connection_complete, 0, 4, #{}}} || Ready, map_size(Links) >= Limit] ++
        lists:append([[{event, {le_connection_complete, 0, Handle, #{}}},
                       {event, {disconnection_complete, 0, Handle, 16#13}},
                       {disconnect, Handle, 16#13},
                       {send, Handle, 0, <<Handle>>},
                       {acl, Handle, 2, 0, <<Handle>>},
                       {event, {encryption_change, 0, Handle, 1}},
                       {event, {number_of_completed_packets, [{Handle, InFlight + 1}]}}] ++
                      [{event, {number_of_completed_packets, [{Handle, 1}]}} || InFlight > 0]
                      || Handle := InFlight <- Links]) ++
        [{event, {number_of_completed_packets, [{3, 1}]}}].

answers(none) -> [];
answers({Opcode, _}) when Opcode =:= 16#0406 ->
    [{event, {command_status, 0, 1, Opcode}}, {event, {command_status, 2, 1, Opcode}},
     {event, {command_status, 16#0C, 1, Opcode}},
     {event, complete(Opcode, <<0>>)}, {event, complete(Opcode, <<2>>)}];
answers({Opcode, _} = Command) ->
    [{event, {command_complete, Allowed, Opcode, good(Command)}} || Allowed <- [0, 1], not is_buffers(Opcode)] ++
        [{event, complete(Opcode, <<1>>)}, {event, complete(Opcode, bad_layout(Command))},
         {event, complete(Opcode bxor 1, <<0>>)}, {event, {command_status, 0, 1, Opcode}}] ++
        [{event, complete(Opcode, Return)} || Return <- buffers(Opcode)].

good({16#1001, _}) -> version(15);
good({16#1002, _}) -> <<0, 0:512>>;
good({16#2003, _}) -> <<0, 0:64>>;
good({16#1009, _}) -> <<0, 1, 2, 3, 4, 5, 6>>;
good({16#2002, _}) -> <<0, 27, 0, 4>>;
good({16#1005, _}) -> <<0, 27, 0, 0, 3, 0, 0, 0>>;
good(_) -> <<0>>.

%% A success whose return parameters are one octet too long.
bad_layout(Command) -> <<(good(Command))/binary, 0>>.

%% The buffer answers explored, in place of good/1's: two buffers, one per connection;
%% five, two per connection and one no link may take; shared buffers by a count or a length of 0; one buffer,
%% below the limit of 2; and a reserved LE length; then from Read Buffer Size two
%% buffers, and a count of 0.
buffers(16#2002) -> [<<0, 27, 0, 2>>, <<0, 27, 0, 5>>, <<0, 27, 0, 0>>, <<0, 0, 0, 2>>, <<0, 27, 0, 1>>, <<0, 26, 0, 2>>];
buffers(16#1005) -> [<<0, 27, 0, 0, 2, 0, 0, 0>>, <<0, 27, 0, 0, 0, 0, 0, 0>>];
buffers(_) -> [].

is_buffers(Opcode) -> buffers(Opcode) =/= [].

%% The world after an input, from the world before it: the line ready, the writer's item
%% taken, the command answered, the deadline passed, a live handle's disconnect asked
%% for, a live handle gone.
consume(line_ready, World) -> World#world{line = none};
consume(written, World) -> World#world{writer = idle};
consume({disconnect, Handle, _}, #world{asked = Asked} = World) ->
    case is_live(Handle, World) of
        true -> World#world{asked = Asked#{Handle => true}};
        false -> World
    end;
consume({event, {disconnection_complete, 0, Handle, _}}, #world{asked = Asked} = World) ->
    World#world{asked = maps:remove(Handle, Asked)};
consume(timeout, World) -> World#world{deadline = false};
consume({event, {command_complete, _, Opcode, _}}, #world{command = {Opcode, _}} = World) -> World#world{command = none};
consume({event, {command_status, _, _, Opcode}}, #world{command = {Opcode, _}} = World) -> World#world{command = none};
consume(_, World) -> World.

%% The world after the core's actions, checking that the writer is given one item at a
%% time, that a command is written only while none is in flight, and that one deadline
%% at most is armed.
observe(Actions, World) ->
    lists:foldl(fun observe_action/2, World, Actions).

observe_action({write, _}, #world{writer = busy}) ->
    erlang:error(second_item_before_written);
observe_action({write, <<1, 16#0406:16/little, 3, Handle:16/little, _>>}, #world{command = none, asked = Asked})
  when not is_map_key(Handle, Asked) ->
    erlang:error({disconnect_not_asked_since_connected, Handle});
observe_action({write, <<1, Opcode:16/little, _/binary>> = Bytes}, #world{command = none, patches = P} = World) ->
    World#world{writer = busy, command = {Opcode, Bytes}, patches = P + patch_start(Opcode)};
observe_action({write, <<1, _/binary>>}, _World) ->
    erlang:error(second_command_in_flight);
observe_action({write, <<2, _/binary>>}, World) ->
    World#world{writer = busy};
observe_action({timer, _}, #world{deadline = true}) ->
    erlang:error(second_deadline);
observe_action({timer, _}, World) ->
    World#world{deadline = true};
observe_action(cancel_timer, #world{deadline = false}) ->
    erlang:error(cancel_without_deadline);
observe_action(cancel_timer, World) ->
    World#world{deadline = false};
observe_action(line_reset, World) ->
    World#world{line = resetting};
observe_action({ready, _}, World) ->
    World#world{ready = true};
observe_action(_, World) ->
    World.

patch_start(16#FC2E) -> 1;
patch_start(_) -> 0.

is_live(Handle, #world{core = Core}) -> is_map_key(Handle, maps:get(links, erx_bt_hci_core:facts(Core))).

check(#world{core = Core, patches = Patches}) ->
    #{links := Links, free := Free, limit := Limit, advertising := Advertising} = erx_bt_hci_core:facts(Core),
    ?assert(Patches =< 1),
    ?assert(not Advertising orelse map_size(Links) < Limit),
    ?assert(Free >= 0),
    ?assert(map_size(Links) =< Limit),
    ?assert(lists:all(fun(InFlight) -> InFlight >= 0 end, maps:values(Links))).

%% An opcode-0 event only updates the count: it neither arms nor disarms the deadline, so
%% repeating it cannot hold a command off for ever.
check_deadline_kept({event, {command_complete, _, 0, _}}, Actions) ->
    ?assertEqual([], [Action || Action <- Actions, Action =:= cancel_timer orelse element(1, tuple(Action)) =:= timer]);
check_deadline_kept(_Input, _Actions) ->
    ok.

%% Before ready, a deadline is always armed, which passes into the next step or a stop.
check_progress(#world{ready = false, deadline = Deadline}) ->
    ?assert(Deadline);
check_progress(_) ->
    ok.

%% With nothing written, in flight or due, a ready core advertises exactly while
%% connections are below the limit in force.
check_quiescent(#world{ready = true, writer = idle, command = none, deadline = false, core = Core}) ->
    #{links := Links, advertising := Advertising, limit := Limit} = erx_bt_hci_core:facts(Core),
    ?assertEqual(map_size(Links) < Limit, Advertising);
check_quiescent(_) ->
    ok.

%% Helpers: a core driven by a controller that answers every command well.

new(Limit) -> erx_bt_hci_core:new(?READY_CONFIG(Limit)).

%% A configuration of Limit connections with no patch.
config(Limit) ->
    #{connections => Limit, address => <<16#C0, 1, 2, 3, 4, 5>>, advertising_data => <<2, 1, 6>>,
      scan_response_data => <<>>, patch => none}.

complete(Opcode, Return) -> {command_complete, 1, Opcode, Return}.

version(Company) -> <<0, 9, 0, 0, 9, Company:16/little, 0, 0>>.

answer(Core, Event) -> erx_bt_hci_core:step({event, Event}, Core).

%% Runs the bring-up, answering each command well, until the command Opcode is written;
%% returns that step's actions and the core waiting for its answer.
to_command(Opcode, Core0) ->
    {ok, _, Core1} = erx_bt_hci_core:step(start, Core0),
    {ok, Actions, Core2} = erx_bt_hci_core:step(line_ready, Core1),
    drive(Opcode, Actions, Core2).

drive(Opcode, Actions, Core) ->
    case [Op || {write, <<1, Op:16/little, _/binary>>} <- Actions] of
        [Opcode] -> {Actions, Core};
        [Other] ->
            {ok, [], Written} = erx_bt_hci_core:step(written, Core),
            {ok, Next, Answered} = answer(Written, complete(Other, good({Other, x}))),
            drive(Opcode, Next, Answered);
        [] ->
            [{timer, _}] = [Timer || {timer, _} = Timer <- Actions],
            {ok, Next, Waited} = erx_bt_hci_core:step(timeout, Core),
            drive(Opcode, Next, Waited)
    end.

%% A ready core whose advertising enable has been written and answered.
ready(Limit) ->
    {Actions, Core} = to_command(16#200A, new(Limit)),
    {ok, [], Written} = erx_bt_hci_core:step(written, Core),
    {ok, [cancel_timer], Ready} = answer(Written, complete(16#200A, <<0>>)),
    {Actions, Ready}.

%% A ready core with one link on Handle.
connected(Limit, Handle) ->
    {_, Core} = ready(Limit),
    {ok, Actions, Linked} = answer(Core, {le_connection_complete, 0, Handle, #{}}),
    {Actions, Linked}.
