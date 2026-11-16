%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_usb_hub_core (docs/design-usb.md, "Hubs"): the hub function's
%% machine, explored to a fixed point, and the decoders of the status-change bitmap and
%% of the hub and port status words. Every number is written out here, so a bound changed
%% in abi/formats/usb.txt or xhci.txt fails a case instead of moving with the module.
-module(erx_usb_hub_core_tests).

-include_lib("eunit/include/eunit.hrl").

-export([explore/1]).

%% The machine for a hub of each port count, explored from start over every event a
%% state accepts: each report of one byte, and of the port count's length, with every
%% port bit and the bits around it, and a failed transfer. The model's own count of
%% transfers posted and bitmaps unhandled must be exactly one until the function stops,
%% so it never has two in flight and never falls silent.
the_machine_keeps_one_bitmap_in_flight_test() ->
    [?assertMatch({ok, _}, explore(Ports)) || Ports <- [1, 2, 7, 8, 15]].

%% Explores the machine for Ports to a fixed point; {ok, StatesSeen} or {error, Why}.
explore(Ports) ->
    {S0, [{changed, First}]} = erx_usb_hub_core:step(start, erx_usb_hub_core:new(Ports)),
    case First =:= lists:seq(1, Ports) ++ [hub] of
        true -> explore(Ports, [{S0, {0, 1}}], #{{S0, {0, 1}} => true});
        false -> {error, {first_report, First}}
    end.

explore(_Ports, [], Seen) ->
    {ok, map_size(Seen)};
explore(Ports, [{State, Outstanding} | Rest], Seen) ->
    Next = [follow(Ports, Event, State, Outstanding) || Event <- events(Ports, Outstanding)],
    case [Why || {error, Why} <- Next] of
        [] ->
            New = [Node || {ok, Node} <- Next, not is_map_key(Node, Seen)],
            explore(Ports, New ++ Rest, maps:merge(Seen, maps:from_keys(New, true)));
        [Why | _] ->
            {error, Why}
    end.

%% The events the hub function's process can receive with Outstanding as
%% {transfers posted, bitmaps unhandled}: a completion only for a posted transfer, the
%% bus process's answer only for a bitmap it holds.
events(Ports, {1, 0}) ->
    [{transfer, {ok, B}} || B <- reports(Ports)] ++ [{transfer, {error, stall}}];
events(_Ports, {0, 1}) ->
    [handled];
events(_Ports, _Stopped) ->
    [].

reports(Ports) ->
    Length = Ports div 8 + 1,
    Edges = [0, 1, 1 bsl Ports, 1 bsl (Ports + 1), (1 bsl (Ports + 1)) - 1, (2 bsl (8 * Length)) - 1],
    [<<>>, <<255>>] ++ [<<V:(8 * Length)/little>> || V <- [B band ((1 bsl (8 * Length)) - 1) || B <- Edges]]
        ++ [<<(1 bsl P):(8 * Length)/little>> || P <- lists:seq(0, Ports)].

follow(Ports, Event, State, {Posted, Unhandled}) ->
    {Next, Actions} = erx_usb_hub_core:step(Event, State),
    After = lists:foldl(fun({post, Length}, {P, U}) when Length =:= Ports div 8 + 1 -> {P + 1, U};
                           ({changed, Set}, {P, U}) -> valid_set(Ports, Set), {P, U + 1};
                           ({stop, _}, _) -> stopped
                        end,
                        {Posted - posted_done(Event), Unhandled - handled_done(Event)}, Actions),
    case After of
        stopped -> {ok, {Next, stopped}};
        {P, U} when P + U =:= 1, P >= 0, U >= 0 -> {ok, {Next, {P, U}}};
        _ -> {error, {Event, Actions, {Posted, Unhandled}}}
    end.

posted_done({transfer, _}) -> 1;
posted_done(_) -> 0.

handled_done(handled) -> 1;
handled_done(_) -> 0.

valid_set(Ports, Set) ->
    true = Set =/= [] andalso Set =:= lists:usort(Set)
        andalso lists:all(fun(hub) -> true; (P) -> P >= 1 andalso P =< Ports end, Set).

a_report_naming_nothing_posts_again_test() ->
    {S, [{post, 1}]} = erx_usb_hub_core:step(handled, element(1, erx_usb_hub_core:step(start, erx_usb_hub_core:new(4)))),
    ?assertMatch({_, [{post, 1}]}, erx_usb_hub_core:step({transfer, {ok, <<0>>}}, S)),
    ?assertMatch({_, [{post, 1}]}, erx_usb_hub_core:step({transfer, {ok, <<2#11100000>>}}, S)),
    ?assertMatch({_, [{changed, [2, hub]}]}, erx_usb_hub_core:step({transfer, {ok, <<2#101>>}}, S)),
    ?assertMatch({_, [{changed, [1, 2, 3, 4, hub]}]}, erx_usb_hub_core:step({transfer, {ok, <<>>}}, S)),
    ?assertMatch({_, [{stop, {transfer, halted}}]}, erx_usb_hub_core:step({transfer, {error, halted}}, S)).

the_bitmap_names_bit_n_as_port_n_test() ->
    ?assertEqual([1, 3, hub], erx_usb_hub_core:bitmap(3, <<2#1011>>)),
    ?assertEqual([3], erx_usb_hub_core:bitmap(3, <<2#11111000>>)),
    ?assertEqual([7, 8, 15], erx_usb_hub_core:bitmap(15, <<16#80, 16#81, 16#ff>>)),
    ?assertEqual([8], erx_usb_hub_core:bitmap(8, <<0, 1>>)),
    %% A report shorter than the port count needs names every port and the hub, as
    %% FreeBSD's uhub explores every port on any report (usb_hub.c:185-218, 993-1090).
    ?assertEqual(lists:seq(1, 8) ++ [hub], erx_usb_hub_core:bitmap(8, <<16#ff>>)),
    ?assertEqual([1, 2, hub], erx_usb_hub_core:bitmap(2, <<>>)),
    ?assertEqual([7], erx_usb_hub_core:bitmap(7, <<16#80>>)),
    ?assertEqual(2, erx_usb_hub_core:transfer_length(8)),
    ?assertEqual(1, erx_usb_hub_core:transfer_length(7)).

a_hub_port_takes_its_speed_by_the_hubs_test() ->
    Speed = fun(Status, Parent) ->
                    {ok, #{speed := S}} = erx_usb_hub_core:port_status(<<Status:16/little, 0:16>>, Parent),
                    S
            end,
    ?assertEqual([full, low, high, high], [Speed(S, {hub, high}) || S <- [16#0101, 16#0301, 16#0501, 16#0701]]),
    ?assertEqual([full, low, full, low], [Speed(S, {hub, full}) || S <- [16#0101, 16#0301, 16#0501, 16#0701]]),
    ?assertEqual([full, low, high, super], [Speed(16#0701, {root, Id}) || Id <- [1, 2, 3, 4]]),
    ?assertEqual([unsupported, unsupported], [Speed(16#0001, {root, Id}) || Id <- [0, 5]]),
    ?assertMatch({ok, #{connected := false, speed := unsupported, changes := [connection]}},
                 erx_usb_hub_core:port_status(<<0, 0, 1, 0>>, {root, 0})).

the_port_words_decode_status_and_changes_test() ->
    ?assertEqual({ok, #{connected => true, enabled => true, suspended => false, over_current => true,
                        reset => false, powered => true, speed => high,
                        changes => [connection, over_current, reset]}},
                 erx_usb_hub_core:port_status(<<16#0b, 16#05, 16#19, 16#ff>>, {hub, high})),
    ?assertEqual({error, malformed_status}, erx_usb_hub_core:port_status(<<1, 0, 0>>, {hub, high})),
    ?assertEqual({error, malformed_status}, erx_usb_hub_core:port_status(<<1, 0, 0, 0, 0>>, {hub, high})),
    ?assertEqual({ok, #{local_power => false, over_current => true, changes => [over_current]}},
                 erx_usb_hub_core:hub_status(<<2, 0, 16#fe, 16#ff>>)),
    ?assertEqual({error, malformed_status}, erx_usb_hub_core:hub_status(<<>>)).
