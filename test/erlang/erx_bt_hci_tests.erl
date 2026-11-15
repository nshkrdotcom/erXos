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
    [{timer, Token, 5000}] = [Timer || {timer, _, _} = Timer <- Actions],
    ?assertEqual({stop, {command_timeout, reset}}, erx_bt_hci_core:step({timeout, Token}, Core)).

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
    {ok, [], Answered} = answer(Written, {command_status, 0, 1, 16#0406}),
    {ok, More, _} = erx_bt_hci_core:step({event, {disconnection_complete, 0, 16#40, 16#16}}, Answered),
    ?assert(lists:member({write, <<1, 16#0A, 16#20, 1, 1>>}, More)).

%% The explored case: every state reachable from start, breadth first, up to a bound on
%% the states seen. The controller at each state may: take the writer's item; answer the
%% command in flight well, with a failed status, or with another command's opcode; let a
%% deadline pass; and once ready, connect, disconnect, complete packets truly or
%% falsely, and take a link's packet. The invariants hold on every transition, every
%% path ends in ready or a stop with a reason, a path patches at most once, and at
%% quiescence advertising is on exactly while connections are below the limit.
-record(world, {core, writer = idle, command = none, timers = [], patches = 0, ready = false}).

explored_core_keeps_its_invariants_test_() ->
    {timeout, 120, fun() ->
        Patched = (?READY_CONFIG(2))#{patch => #{manufacturer => 15, records => [{16#FC4C, <<1, 2>>}, {16#FC4E, <<>>}]}},
        [explore(Config) || Config <- [?READY_CONFIG(2), Patched]]
    end}.

explore(Config) ->
    {ok, Actions, Core} = erx_bt_hci_core:step(start, erx_bt_hci_core:new(Config)),
    World = observe(Actions, #world{core = Core}),
    {ok, LineActions, Next} = erx_bt_hci_core:step(line_ready, World#world.core),
    Start = observe(LineActions, World#world{core = Next}),
    Stats = walk(queue:from_list([Start]), sets:from_list([key(Start)]), #{ready => 0, stops => #{}}, 30000),
    ?assert(maps:get(ready, Stats) > 0),
    ?assert(map_size(maps:get(stops, Stats)) > 3).

walk(Queue, Seen, Stats, Budget) ->
    case queue:out(Queue) of
        {empty, _} -> Stats;
        {_, _} when Budget =:= 0 -> Stats;
        {{value, World}, Rest} ->
            check_quiescent(World),
            {Queue1, Seen1, Stats1} = lists:foldl(fun(Input, Acc) -> visit(World, Input, Acc) end,
                                                  {Rest, Seen, count_ready(World, Stats)}, inputs(World)),
            walk(Queue1, Seen1, Stats1, Budget - 1)
    end.

visit(World, Input, {Queue, Seen, Stats}) ->
    case erx_bt_hci_core:step(Input, World#world.core) of
        {stop, Reason} ->
            ?assert(is_atom(Reason) orelse is_tuple(Reason)),
            {Queue, Seen, Stats#{stops := maps:update_with(element(1, tuple(Reason)), fun(N) -> N + 1 end, 1,
                                                          maps:get(stops, Stats))}};
        {ok, Actions, Core} ->
            Next = observe(Actions, consume(Input, World#world{core = Core})),
            check(Next),
            Key = key(Next),
            case sets:is_element(Key, Seen) of
                true -> {Queue, Seen, Stats};
                false -> {queue:in(Next, Queue), sets:add_element(Key, Seen), Stats}
            end
    end.

tuple(Reason) when is_tuple(Reason) -> Reason;
tuple(Reason) -> {Reason}.

key(#world{core = Core, writer = Writer, command = Command, timers = Timers, patches = Patches}) ->
    {Core, Writer, Command, length(Timers), Patches}.

count_ready(#world{ready = true}, #{ready := N} = Stats) -> Stats#{ready := N + 1};
count_ready(_, Stats) -> Stats.

%% What the controller and the clock may do next.
inputs(#world{core = Core, writer = Writer, command = Command, timers = Timers}) ->
    Facts = erx_bt_hci_core:facts(Core),
    Links = maps:get(links, Facts),
    [written || Writer =:= busy] ++
        [{timeout, Token} || Token <- Timers] ++
        answers(Command) ++
        [{event, {le_connection_complete, 0, Handle, #{}}} || maps:get(advertising, Facts), Handle <- [1, 2],
                                                              not is_map_key(Handle, Links)] ++
        lists:append([[{event, {disconnection_complete, 0, Handle, 16#13}},
                       {send, Handle, 0, <<Handle>>},
                       {event, {number_of_completed_packets, [{Handle, InFlight + 1}]}}] ++
                      [{event, {number_of_completed_packets, [{Handle, 1}]}} || InFlight > 0]
                      || Handle := InFlight <- Links]) ++
        [{event, {number_of_completed_packets, [{3, 1}]}}].

answers(none) -> [];
answers({Opcode, _}) when Opcode =:= 16#0406 ->
    [{event, {command_status, 0, 1, Opcode}}, {event, {command_status, 2, 1, Opcode}}];
answers({Opcode, _} = Command) ->
    [{event, complete(Opcode, good(Command))}, {event, complete(Opcode, <<1>>)},
     {event, complete(Opcode bxor 1, <<0>>)}, {event, {command_status, 0, 1, Opcode}}] ++
        [{event, complete(Opcode, <<0, 0, 0, 0>>)} || Opcode =:= 16#2002].

good({16#1001, _}) -> version(15);
good({16#1002, _}) -> <<0, 0:512>>;
good({16#2003, _}) -> <<0, 0:64>>;
good({16#1009, _}) -> <<0, 1, 2, 3, 4, 5, 6>>;
good({16#2002, _}) -> <<0, 27, 0, 4>>;
good({16#1005, _}) -> <<0, 27, 0, 0, 3, 0, 0, 0>>;
good(_) -> <<0>>.

%% The world after an input: the writer's item taken, the command answered, a timer
%% fired.
consume(written, World) -> World#world{writer = idle};
consume({timeout, Token}, #world{timers = Timers} = World) -> World#world{timers = lists:delete(Token, Timers)};
consume({event, {command_complete, _, Opcode, _}}, #world{command = {Opcode, _}} = World) -> World#world{command = none};
consume({event, {command_status, _, _, Opcode}}, #world{command = {Opcode, _}} = World) -> World#world{command = none};
consume(_, World) -> World.

%% The world after the core's actions, checking that the writer is given one item at a
%% time and that a command is written only while none is in flight.
observe(Actions, World) ->
    lists:foldl(fun observe_action/2, World, Actions).

observe_action({write, _}, #world{writer = busy}) ->
    erlang:error(second_item_before_written);
observe_action({write, <<1, Opcode:16/little, _/binary>> = Bytes}, #world{command = none, patches = P} = World) ->
    World#world{writer = busy, command = {Opcode, Bytes}, patches = P + patch_start(Opcode)};
observe_action({write, <<1, _/binary>>}, _World) ->
    erlang:error(second_command_in_flight);
observe_action({write, <<2, _/binary>>}, World) ->
    World#world{writer = busy};
observe_action({timer, Token, _}, #world{timers = Timers} = World) ->
    World#world{timers = [Token | Timers]};
observe_action({ready, _}, World) ->
    World#world{ready = true};
observe_action(_, World) ->
    World.

patch_start(16#FC2E) -> 1;
patch_start(_) -> 0.

check(#world{core = Core, patches = Patches}) ->
    #{links := Links, free := Free} = erx_bt_hci_core:facts(Core),
    ?assert(Patches =< 1),
    ?assert(Free >= 0),
    ?assert(lists:all(fun(InFlight) -> InFlight >= 0 end, maps:values(Links))).

%% With nothing written or in flight, a ready core advertises exactly while connections
%% are below the limit (2 in the explored configurations).
check_quiescent(#world{ready = true, writer = idle, command = none, core = Core}) ->
    #{links := Links, advertising := Advertising} = erx_bt_hci_core:facts(Core),
    ?assertEqual(map_size(Links) < 2, Advertising);
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
            [{timer, Token, _}] = [Timer || {timer, _, _} = Timer <- Actions],
            {ok, Next, Waited} = erx_bt_hci_core:step({timeout, Token}, Core),
            drive(Opcode, Next, Waited)
    end.

%% A ready core whose advertising enable has been written and answered.
ready(Limit) ->
    {Actions, Core} = to_command(16#200A, new(Limit)),
    {ok, [], Written} = erx_bt_hci_core:step(written, Core),
    {ok, [], Ready} = answer(Written, complete(16#200A, <<0>>)),
    {Actions, Ready}.

%% A ready core with one link on Handle.
connected(Limit, Handle) ->
    {_, Core} = ready(Limit),
    {ok, Actions, Linked} = answer(Core, {le_connection_complete, 0, Handle, #{}}),
    {Actions, Linked}.
