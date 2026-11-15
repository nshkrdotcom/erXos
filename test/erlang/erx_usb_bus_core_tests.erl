%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_usb_bus_core (docs/design-usb.md, "Ports, hubs and devices: the bus
%% core", "Hubs" and the bus core's row of "Host tests of the cores"): the core explored
%% to a fixed point against a simulated bus of a root hub of two ports, one external hub
%% of two ports and devices of one and two functions; then traces of 1,000 attach and
%% detach cycles on one port, a connection storm, and a hub detached during its child's
%% enumeration.
%%
%% The simulation is the test's own model of the hardware and the processes around the
%% core: every port's connection, enable, power and latched change bits; the port
%% operations, commands and hub reports in flight; and the slots the controller handed
%% out. Each transition checks the design's invariants against that model and the
%% actions, not against the core's own bookkeeping:
%% * at most one port is between its reset and its device's address answer (the
%%   address-zero window), and a reset is never issued while another port's window is
%%   open; a failed address keeps the window until its answer;
%% * a connection change read on an occupied port detaches the occupant first;
%% * every slot handed out belongs to a device the core still holds, and a detached
%%   device's reference is gone and named by no later action;
%% * a hub has at most one port operation in flight, and `handled` goes only to the hub
%%   function whose report is outstanding;
%% * no status read reaches a hub's port before its power-good time has passed since
%%   its last power-on answer;
%% * at most one simulated device is enabled and not yet addressed;
%% * no reset names a port that is off or empty.
%% Times start at 2^40, so every integer at or above it in a state is a time; states are
%% compared with times taken relative to the clock and device references renumbered in
%% order, so equal situations at different times are one state. Every number is
%% written out here, so a constant changed in the module fails a case.
-module(erx_usb_bus_core_tests).

-include_lib("eunit/include/eunit.hrl").

-export([states/2]).

-define(T0, (1 bsl 40)).
%% The depths explored, as connects or disconnects and failed answers the environment
%% may spend: three of the first carry a hub, a device behind it and the hub's unplugging;
%% two and a failure carry a failed address with another device waiting for the turn.
-define(DEPTHS, [{3, 0}, {2, 1}]).
%% Power-good times: the root's 10 units, the simulated hub's 50, each times 2 ms plus 20.
-define(ROOT_POWER_GOOD, 40).
-define(HUB_POWER_GOOD, 120).

%% The exploration.

explored_to_a_fixed_point_test_() ->
    {timeout, 600, fun() ->
                           [begin
                                {ok, Seen} = states(Stimuli, Errors),
                                io:format(user, "~nerx_usb_bus_core: ~b states, ~b connects or disconnects "
                                          "and ~b failed answers deep~n", [Seen, Stimuli, Errors])
                            end || {Stimuli, Errors} <- ?DEPTHS]
                   end}.

%% The node after the bus's first step: the root hub powering its ports.
start(Stimuli, Errors) ->
    deliver(expired, (model0())#{stimuli := Stimuli, errors := Errors}, erx_usb_bus_core:new(2)).

%% The number of states reachable with Stimuli connects or disconnects and Errors failed answers.
states(Stimuli, Errors) -> explore(start(Stimuli, Errors)).

explore(Start) ->
    explore([Start], #{key(Start) => true}).

explore([], Seen) ->
    {ok, map_size(Seen)};
explore([Node | Rest], Seen) ->
    Next = maps:from_list([{key(N), N} || Choice <- choices(Node), N <- [follow(Choice, Node)]]),
    New = maps:filter(fun(Key, _Node) -> not is_map_key(Key, Seen) end, Next),
    explore(maps:values(New) ++ Rest, maps:merge(Seen, maps:map(fun(_, _) -> true end, New))).

%% A power-on answered longer ago than any hub's power-good time is as good as any
%% older one, so its time is clamped and the key stays finite as time passes.
key({Model = #{now := Now, powered := Powered}, Core}) ->
    Clamped = maps:map(fun(_Hub, At) -> max(At, Now - 1000) end, Powered),
    canon({maps:remove(last, Model#{powered := Clamped}), Core}, Now).

%% The simulated bus.

model0() ->
    #{now => ?T0, deadline => none,
      world => #{{root, 1} => port0(), {root, 2} => port0()},
      ext => none, hub_fn => none, ops => #{}, cmds => [], slots => #{}, things => #{},
      powered => #{}, window => none, stimuli => 0, errors => 0}.

port0() -> #{thing => none, chg => [], enabled => false, addressed => false, powered => false, signaled => false}.

%% The choices the environment has in a node. It answers what is in flight, finishes
%% a device's descriptor steps and delivers reports and port events in one fixed
%% order, the first of them only, which keeps two devices' lifecycles from multiplying
%% into each other; reports and port events arrive in any state; any answer may fail, the next deadline may pass first,
%% so an answer can come after its deadline or never, and anything may be connected
%% or disconnected at any point.
choices(Node = {M, _Core}) ->
    {Ready, Failed} = environment(Node),
    {Answers, Reports} = lists:partition(fun({Kind, _}) -> Kind =:= core end, Ready),
    lists:sublist(Answers, 1) ++ Reports ++ Failed ++ expiry(M) ++ stimuli(M).

%% What the environment can deliver now, in its fixed order, and the failures it may
%% deliver instead.
environment({M, Core}) ->
    All = answers(M) ++ commands(M) ++ configured(M, Core) ++ reports(M),
    {[C || C = {Kind, _} <- All, Kind =/= core_error], [C || C = {core_error, _} <- All]}.

answers(M = #{ops := Ops, errors := Errors}) ->
    lists:append([[{core, {port_done, H, T, answer(H, T, Op, M)}}]
                  ++ [{core_error, {port_done, H, T, {error, stall}}} || Errors > 0, H =/= root, live(H, M)]
                  || H := {T, Op} <- Ops]).

commands(#{cmds := Cmds, errors := Errors, slots := Slots}) ->
    lists:append([[{core, {Kind, Ref, {ok, free_slot(Slots)}}}]
                  ++ [{core_error, {Kind, Ref, {error, transaction}}} || Errors > 0]
                  || {Kind, Ref} <- Cmds]).

configured(#{things := Things, errors := Errors}, Core) ->
    lists:append([descriptor_steps(Ref, maps:get(Ref, Things))
                  ++ [{core_error, {enumeration_failed, Ref, stall}} || Errors > 0]
                  || {_, {enumerating, Ref, configuring}} <- maps:to_list(erx_usb_bus_core:ports(Core))]).

reports(M = #{hub_fn := #{ref := Ref, first := First, outstanding := false}}) ->
    Changed = [N || N <- [1, 2], maps:get(chg, maps:get({ext, N}, maps:get(world, M), port0())) =/= []],
    case {First, Changed} of
        {true, _} -> [{report, {changed, Ref, [1, 2, hub], {fn, Ref}}}];
        {false, []} -> [];
        {false, _} -> [{report, {changed, Ref, Changed, {fn, Ref}}}]
    end ++ root_events(M);
reports(M) ->
    root_events(M).

root_events(#{world := World}) ->
    [{signal, {port_event, N}} || N <- [1, 2], #{chg := [_ | _], signaled := false} <- [maps:get({root, N}, World)]].

expiry(#{deadline := none}) -> [];
expiry(#{deadline := At}) -> [{expire, At}].

stimuli(#{stimuli := 0}) ->
    [];
stimuli(#{world := World}) ->
    HubPresent = lists:any(fun(#{thing := T}) -> T =:= hub end, maps:values(World)),
    [{stimulus, Where, New}
     || Where := #{thing := Thing} <- World,
        New <- case Thing of
                   none -> [dev1, dev2] ++ [hub || element(1, Where) =:= root, not HubPresent];
                   _ -> [none]
               end].

%% A device unplugged before its descriptor steps fails them.
descriptor_steps(Ref, Gone) when Gone =:= none; Gone =:= gone -> [{core, {enumeration_failed, Ref, gone}}];
descriptor_steps(Ref, Thing) -> [{core, {configured, Ref, config(Thing)}}].

config(dev1) -> #{functions => [f1], hub => none};
config(dev2) -> #{functions => [f1, f2], hub => none};
config(hub) -> #{functions => [hub], hub => #{ports => 2, power_good => 50, multi_tt => false}}.

live(root, _M) -> true;
live(H, #{ext := Ext}) -> H =:= Ext.

free_slot(Slots) -> hd(lists:seq(1, 16) -- maps:values(Slots)).

where(root, N) -> {root, N};
where(_Ext, N) -> {ext, N}.

%% A live port operation's answer from the world; an operation on a hub already gone
%% is answered as its pipe would be.
answer(H, T, Op, M) ->
    case live(H, M) andalso (T =:= hub orelse is_map_key(where(H, T), maps:get(world, M))) of
        true -> world_answer(H, T, Op, M);
        false -> {error, gone}
    end.

world_answer(_H, hub, get_status, _M) ->
    {ok, <<0:16, 0:16>>};
world_answer(H, N, get_status, #{world := World}) ->
    #{thing := Thing, chg := Chg, enabled := Enabled, powered := Powered} = maps:get(where(H, N), World),
    Status = bit(Thing =/= none, 1) bor bit(Enabled, 2) bor bit(Powered, 256)
        bor bit(H =/= root andalso (Thing =:= dev2 orelse Thing =:= hub), 1024),
    Change = lists:sum([maps:get(C, #{connection => 1, enabled => 2, reset => 16}) || C <- Chg]),
    Words = <<Status:16/little, Change:16/little>>,
    case H of
        root -> {ok, Words, root_speed(Thing)};
        _ -> {ok, Words}
    end;
world_answer(_H, _T, _Op, _M) ->
    ok.

bit(true, Mask) -> Mask;
bit(false, _Mask) -> 0.

root_speed(dev1) -> 1;
root_speed(_HighOrNone) -> 3.

%% One choice taken: the world moves, then the core steps when the choice reaches it.
follow({stimulus, Where, New}, {M = #{world := World, stimuli := S}, Core}) ->
    Port = #{thing := Old, chg := Chg} = maps:get(Where, World),
    Moved = World#{Where := Port#{thing := New, enabled := false, addressed := false,
                                  chg := ordsets:add_element(connection, Chg)}},
    Downstream = case {Old, New} of
                     {hub, none} -> maps:without([{ext, 1}, {ext, 2}], Moved);
                     {_, hub} -> Moved#{{ext, 1} => port0(), {ext, 2} => port0()};
                     _ -> Moved
                 end,
    {M#{world := Downstream, stimuli := S - 1}, Core};
follow({expire, At}, {M = #{now := Now}, Core}) ->
    At > Now orelse error({deadline_not_in_the_future, At - Now}),
    deliver(expired, M#{now := At}, Core);
follow({signal, Event = {port_event, N}}, {M = #{world := World}, Core}) ->
    deliver(Event, M#{world := World#{{root, N} := (maps:get({root, N}, World))#{signaled := true}}}, Core);
follow({report, Event}, {M = #{hub_fn := Fn}, Core}) ->
    deliver(Event, M#{hub_fn := Fn#{first := false, outstanding := true}}, Core);
follow({core_error, Event}, {M = #{errors := E}, Core}) ->
    deliver(Event, consume(Event, M#{errors := E - 1}), Core);
follow({core, Event = {addressed, Ref, {ok, _}}}, {M = #{world := World}, Core}) ->
    Where = case maps:find(Ref, erx_usb_bus_core:devices(Core)) of
                {ok, #{port := {H, N}}} when H =:= root; H =:= map_get(ext, M) -> where(H, N);
                _Gone -> gone
            end,
    Addressed = case maps:find(Where, World) of
                    {ok, Port} ->
                        M#{world := World#{Where := Port#{addressed := true}}};
                    _ -> M
                end,
    deliver(Event, consume(Event, Addressed), Core);
follow({core, Event}, {M, Core}) ->
    deliver(Event, consume(Event, world_effect(Event, M)), Core).

consume({port_done, H, _T, _Result}, M = #{ops := Ops}) -> M#{ops := maps:remove(H, Ops)};
consume({Kind, Ref, _Result}, M = #{cmds := Cmds}) when Kind =:= slot; Kind =:= addressed ->
    M#{cmds := Cmds -- [{Kind, Ref}]};
consume(_Event, M) -> M.

%% What a successful port operation does to the simulated hardware.
world_effect({port_done, H, N, ok}, M = #{world := World, ops := Ops}) when is_integer(N) ->
    case {live(H, M), maps:find(where(H, N), World)} of
        {true, {ok, Port}} ->
            Op = element(2, maps:get(H, Ops)),
            Powered = case Op of
                          power_on -> (map_get(powered, M))#{H => map_get(now, M)};
                          _ -> map_get(powered, M)
                      end,
            M#{world := World#{where(H, N) := port_effect(Op, Port)}, powered := Powered};
        _ -> M
    end;
world_effect(_Event, M) ->
    M.

port_effect(power_on, Port) ->
    Port#{powered := true};
port_effect(reset, Port = #{thing := Thing, chg := Chg}) when Thing =/= none ->
    Port#{enabled := true, addressed := false, chg := ordsets:add_element(reset, Chg)};
port_effect(disable, Port) ->
    Port#{enabled := false};
port_effect({clear, C}, Port = #{chg := Chg, signaled := Signaled}) ->
    Left = ordsets:del_element(C, Chg),
    Port#{chg := Left, signaled := Signaled andalso Left =/= []};
port_effect(_Op, Port) ->
    Port.

deliver(Event, M, Core0) ->
    {Actions, Core} = erx_usb_bus_core:step(Event, maps:get(now, M), Core0),
    observe(Event, Actions, M, Core0, Core).

%% The checks, and the model's bookkeeping of the actions.

observe(Event, Actions, M0, Before, After) ->
    check_default_state(M0, Event),
    check_turn(After, Event),
    check_connection_detach(Event, Actions, Before),
    M1 = close_window(Event, M0, Before, After),
    M2 = lists:foldl(fun(Action, M) -> action(Action, M, Before, After) end,
                     M1#{deadline := none, last => Actions}, Actions),
    [is_map_key(Ref, erx_usb_bus_core:devices(After)) orelse error({slot_of_gone_device, Ref, Event})
     || Ref := _ <- maps:get(slots, M2)],
    {M2, After}.

%% The test's own notion of the address-zero window, from the design's port table.
in_window({resetting, _, _}) -> true;
in_window({recovering, _, _}) -> true;
in_window({enumerating, _, Step}) -> Step =/= configuring;
in_window(_) -> false.

%% The hardware's own count: at most one device enabled and not yet addressed, so at
%% most one answers address zero, whatever the core believes about its ports.
check_default_state(#{world := World}, Event) ->
    case [W || W := #{thing := T, enabled := true, addressed := false} <- World, T =/= none] of
        [_, _ | _] = Two -> error({two_devices_at_address_zero, Two, Event});
        _ -> ok
    end.

check_turn(Core, Event) ->
    case [P || P := S <- erx_usb_bus_core:ports(Core), in_window(S)] of
        [_, _ | _] = Two -> error({two_ports_at_address_zero, Two, Event});
        _ -> ok
    end.

check_connection_detach({port_done, H, N, {ok, <<_:16, Change:16/little>>, _SpeedId}}, Actions, Before) ->
    connection_detach(H, N, Change, Actions, Before);
check_connection_detach({port_done, H, N, {ok, <<_:16, Change:16/little>>}}, Actions, Before) when N =/= hub ->
    connection_detach(H, N, Change, Actions, Before);
check_connection_detach(_Event, _Actions, _Before) ->
    ok.

connection_detach(H, N, Change, Actions, Before) when Change band 1 =/= 0 ->
    case maps:get({H, N}, erx_usb_bus_core:ports(Before), none) of
        {enumerating, Ref, _} -> first_detaches(Ref, Actions);
        {running, Ref} -> first_detaches(Ref, Actions);
        _ -> ok
    end;
connection_detach(_H, _N, _Change, _Actions, _Before) ->
    ok.

first_detaches(Ref, Actions = [{detach, _} | _]) ->
    lists:member({detach, Ref}, Actions) orelse error({occupant_kept, Ref, Actions});
first_detaches(Ref, Actions) ->
    error({connection_change_without_detach_first, Ref, Actions}).

%% A window opens with its port's reset and closes with its device's address answer,
%% or when the port leaves it by a failure, a detach or a connection change; it never
%% reaches `configuring` without the answer.
close_window(_Event, M = #{window := none}, _Before, _After) ->
    M;
close_window({addressed, Ref, _}, M = #{window := Window}, Before, _After) ->
    case maps:find(Ref, erx_usb_bus_core:devices(Before)) of
        {ok, #{port := Window}} -> M#{window := none};
        _ -> left(M, _After)
    end;
close_window(_Event, M, _Before, After) ->
    left(M, After).

left(M = #{window := Window}, After) ->
    case maps:get(Window, erx_usb_bus_core:ports(After), gone) of
        {enumerating, _, configuring} -> error({window_closed_without_address_answer, Window});
        State ->
            case in_window(State) of
                true -> M;
                false -> M#{window := none}
            end
    end.

action({port, H, T, Op}, M = #{ops := Ops, now := Now, powered := Powered}, _Before, After) ->
    is_map_key(H, Ops) andalso error({two_operations_on_hub, H, Op}),
    Opened = case {T, Op} of
                 {N, get_status} when is_integer(N) ->
                     Now >= maps:get(H, Powered, Now + 1) + power_good(H)
                         orelse error({read_before_power_good, H, N}),
                     M;
                 {N, reset} ->
                     {resetting, _, sent} = maps:get({H, N}, erx_usb_bus_core:ports(After)),
                     open_window({H, N}, M);
                 _ ->
                     M
             end,
    Opened#{ops := Ops#{H => {T, Op}}};
action({handled, H, From}, M = #{hub_fn := Fn}, _Before, _After) ->
    case Fn of
        #{ref := Ref, outstanding := true} when From =:= {fn, Ref}, H =:= Ref -> M#{hub_fn := Fn#{outstanding := false}};
        _ -> error({handled_without_report, From, Fn})
    end;
action({enable_slot, Ref}, M = #{cmds := Cmds, things := Things, world := World}, Before, After) ->
    is_map_key(Ref, erx_usb_bus_core:devices(Before)) andalso error({reference_reused, Ref}),
    #{port := {H, N}} = maps:get(Ref, erx_usb_bus_core:devices(After)),
    #{thing := Thing} = maps:get(where(H, N), World, #{thing => gone}),
    M#{cmds := Cmds ++ [{slot, Ref}], things := Things#{Ref => Thing}};
action({address, Ref, #{slot := Slot}}, M = #{cmds := Cmds, slots := Slots}, _Before, After) ->
    is_map_key(Ref, erx_usb_bus_core:devices(After)) orelse error({address_for_gone_device, Ref}),
    M#{cmds := Cmds ++ [{addressed, Ref}], slots := Slots#{Ref => Slot}};
action({start, Ref, Functions}, M, _Before, After) ->
    is_map_key(Ref, erx_usb_bus_core:devices(After)) orelse error({start_for_gone_device, Ref}),
    case Functions of
        [hub] -> M#{hub_fn := #{ref => Ref, first => true, outstanding => false}, ext => Ref};
        _ -> M
    end;
action({detach, Ref}, M = #{slots := Slots, things := Things, hub_fn := Fn, ext := Ext}, Before, After) ->
    is_map_key(Ref, erx_usb_bus_core:devices(Before)) orelse error({detached_twice, Ref}),
    is_map_key(Ref, erx_usb_bus_core:devices(After)) andalso error({reference_kept, Ref}),
    M#{slots := maps:remove(Ref, Slots), things := maps:remove(Ref, Things),
       hub_fn := case Fn of #{ref := Ref} -> none; _ -> Fn end,
       ext := case Ext of Ref -> none; _ -> Ext end};
action({deadline, At}, M, _Before, _After) ->
    M#{deadline := At}.

power_good(root) -> ?ROOT_POWER_GOOD;
power_good(_Ext) -> ?HUB_POWER_GOOD.

open_window(Port, #{window := Window}) when Window =/= none, Window =/= Port ->
    error({reset_with_window_open, Window, Port});
open_window(Port, M) ->
    M#{window := Port}.

%% The traces.

%% Drives the node by the first choice Allow takes, answers before deadlines, until
%% Stop holds or no choice is left; at most Steps steps.
drive(Node, Stop, Allow) ->
    drive(Node, Stop, Allow, 10000).

drive(Node, _Stop, _Allow, 0) ->
    error({drive_did_not_settle, Node});
drive(Node, Stop, Allow, Steps) ->
    case Stop(Node) of
        true ->
            Node;
        false ->
            {Ready, _Failed} = environment(Node),
            case [C || C <- Ready ++ expiry(element(1, Node)), Allow(C)] of
                [] -> Node;
                [Choice | _] -> drive(follow(Choice, Node), Stop, Allow, Steps - 1)
            end
    end.

settle(Node) -> drive(Node, fun(_) -> false end, fun(_) -> true end).

port_of({_M, Core}, Where) -> maps:get(Where, erx_usb_bus_core:ports(Core)).

trace_start() -> settle(start(1 bsl 30, 0)).

attach_and_detach_cycles_leave_nothing_behind_test_() ->
    {timeout, 300, fun() ->
        Cycle = fun(_, Node) ->
                        Running = settle(follow({stimulus, {root, 1}, dev2}, Node)),
                        ?assertMatch({running, _}, port_of(Running, {root, 1})),
                        Gone = settle(follow({stimulus, {root, 1}, none}, Running)),
                        ?assertEqual(empty, port_of(Gone, {root, 1})),
                        ?assertEqual(#{}, erx_usb_bus_core:devices(element(2, Gone))),
                        Gone
                end,
        First = {#{now := Now1}, Core1} = Cycle(1, trace_start()),
        {#{now := Now}, Core} = lists:foldl(Cycle, First, lists:seq(2, 1000)),
        ?assertEqual(canon(Core1, Now1), canon(Core, Now))
    end}.

a_connection_storm_stays_bounded_test() ->
    Toggle = fun(I, Node) ->
                     Thing = case I rem 2 of 0 -> none; 1 -> dev1 end,
                     drive(follow({stimulus, {root, 1}, Thing}, Node), fun(_) -> false end,
                           fun({expire, _}) -> false; (_) -> true end)
             end,
    Storm = {_, Core} = lists:foldl(Toggle, trace_start(), lists:seq(1, 201)),
    ?assert(erts_debug:flat_size(Core) < 400),
    ?assertMatch({running, _}, port_of(settle(Storm), {root, 1})).

%% A hub is unplugged while its child waits for its address: the child is detached
%% before the hub, every reference is gone, the late address answer changes nothing,
%% and the turn is free for the next device.
a_hub_detached_during_its_childs_enumeration_test() ->
    Hub = settle(follow({stimulus, {root, 1}, hub}, trace_start())),
    {running, HubRef} = port_of(Hub, {root, 1}),
    Addressing = fun(Node) -> port_of(Node, {HubRef, 1}) =:= {enumerating, {device, 2}, addressing} end,
    Child = drive(follow({stimulus, {ext, 1}, dev1}, Hub), Addressing, fun(_) -> true end),
    ?assert(Addressing(Child)),
    Root = fun({signal, _}) -> true; ({core, {port_done, root, _, _}}) -> true; (_) -> false end,
    Unplugged = {#{last := Last}, Core} =
        drive(follow({stimulus, {root, 1}, none}, Child),
              fun(Node) -> not is_map_key(HubRef, erx_usb_bus_core:devices(element(2, Node))) end, Root),
    ?assertEqual([{detach, {device, 2}}, {detach, HubRef}], [A || A = {detach, _} <- Last]),
    ?assertEqual(#{}, erx_usb_bus_core:devices(Core)),
    {Late, _} = erx_usb_bus_core:step({addressed, {device, 2}, {ok, 2}}, maps:get(now, element(1, Unplugged)), Core),
    ?assertEqual([], [A || A <- Late, element(1, A) =/= deadline]),
    Next = settle(follow({stimulus, {root, 2}, dev1}, settle(Unplugged))),
    ?assertMatch({running, _}, port_of(Next, {root, 2})).

%% Power: every port off until its power-on answer, then no status read before the
%% hub's power-good time; the root's is 40 ms after its last port's answer.
the_root_hub_powers_its_ports_before_reading_them_test() ->
    {A1, S1} = erx_usb_bus_core:step(expired, 0, erx_usb_bus_core:new(2)),
    ?assertEqual([{port, root, 1, power_on}], A1),
    {A2, S2} = erx_usb_bus_core:step({port_done, root, 1, ok}, 5, S1),
    ?assertEqual([{port, root, 2, power_on}], A2),
    {A3, S3} = erx_usb_bus_core:step({port_done, root, 2, ok}, 7, S2),
    ?assertEqual([{deadline, 47}], A3),
    ?assertEqual(#{{root, 1} => empty, {root, 2} => empty}, erx_usb_bus_core:ports(S3)),
    ?assertMatch({[{deadline, 47}], _}, erx_usb_bus_core:step(expired, 46, S3)),
    ?assertMatch({[{port, root, 1, get_status}], _}, erx_usb_bus_core:step(expired, 47, S3)).

%% decision 3: `handled` goes to the instance that reported; a restarted hub
%% function's report replaces its predecessor's, which is never answered.
handled_goes_to_the_reporter_test() ->
    {_, Node} = Hub = settle(follow({stimulus, {root, 1}, hub}, trace_start())),
    {running, HubRef} = port_of(Hub, {root, 1}),
    {A1, S1} = erx_usb_bus_core:step({changed, HubRef, [1], old}, maps:get(now, element(1, Hub)), Node),
    ?assertMatch([{port, HubRef, 1, get_status} | _], A1),
    {A2, S2} = erx_usb_bus_core:step({changed, HubRef, [2], new}, maps:get(now, element(1, Hub)), S1),
    ?assertEqual([], [A || A = {handled, _, _} <- A2]),
    {A3, S3} = erx_usb_bus_core:step({port_done, HubRef, 1, {ok, <<1:16/little, 0:16>>}}, maps:get(now, element(1, Hub)), S2),
    ?assertMatch([{port, HubRef, 2, get_status} | _], A3),
    {A4, _} = erx_usb_bus_core:step({port_done, HubRef, 2, {ok, <<0:16, 0:16>>}}, maps:get(now, element(1, Hub)), S3),
    ?assertEqual([{handled, HubRef, new}], [A || A = {handled, _, _} <- A4]).

%% Canonical form: times relative to Now, references renumbered in order.
canon(Term, Now) ->
    Refs = lists:usort(collect(Term, [])),
    Map = maps:from_list(lists:zip(Refs, [{device, I} || I <- lists:seq(1, length(Refs))])),
    rewrite(Term, Map, Now).

collect(R = {device, N}, Acc) when is_integer(N) -> [R | Acc];
collect(T, Acc) when is_tuple(T) -> collect(tuple_to_list(T), Acc);
collect(L, Acc) when is_list(L) -> lists:foldl(fun collect/2, Acc, L);
collect(M, Acc) when is_map(M) -> collect(maps:to_list(M), Acc);
collect(_, Acc) -> Acc.

rewrite(R = {device, N}, Map, _Now) when is_integer(N) -> maps:get(R, Map);
rewrite(T, Map, Now) when is_tuple(T) -> list_to_tuple(rewrite(tuple_to_list(T), Map, Now));
rewrite(L, Map, Now) when is_list(L) -> [rewrite(E, Map, Now) || E <- L];
rewrite(M, Map, Now) when is_map(M) ->
    maps:from_list([{rewrite(K, Map, Now), rewrite(V, Map, Now)} || K := V <- M]);
rewrite(I, _Map, Now) when is_integer(I), I >= ?T0 -> {at, I - Now};
rewrite(X, _Map, _Now) -> X.
