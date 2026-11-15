%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_hold, the header drivers' hold on a pin, a chip select or a
%% channel (docs/design-header-io.md, "Holding and granting" and the Verification
%% row of erx_hold): the design's named traces, then every sequence of six events
%% over two grants and two resources, checked against an independent model.
%% test/host/erx_hold_test.rb also runs them against seeded faults of the module,
%% each of which the cases named there must catch.

-module(erx_hold_tests).

-include_lib("eunit/include/eunit.hrl").

-define(RESOURCES, [17, 18]).
-define(GRANTS, [a, b]).
-define(DEPTH, 6).
-define(SEQUENCES, 373504).

%% ---------------------------------------------------------------------------
%% Fixtures
%% ---------------------------------------------------------------------------

%% The two grants' processes. The core only compares them, so they need not run.
grant(a) -> list_to_pid("<0.101.0>");
grant(b) -> list_to_pid("<0.102.0>").

%% A core of a newly started driver.
new() -> erx_hold:new(make_ref()).

%% An open the case expects to succeed: its handle, its actions and the next core.
opened(Grant, Resource, Core) ->
    {ok, Handle, Actions, Next} = erx_hold:open(grant(Grant), Resource, Core),
    {Handle, Actions, Next}.

%% ---------------------------------------------------------------------------
%% The named traces
%% ---------------------------------------------------------------------------

%% A holds 17, so B's open of it is busy and B's open of 18 is not.
an_open_of_a_resource_another_grant_holds_is_busy_test() ->
    {_, [{monitor, _}], Held} = opened(a, 17, new()),
    ?assertEqual({error, ebusy}, erx_hold:open(grant(b), 17, Held)),
    ?assertMatch({ok, _, [{monitor, _}], _}, erx_hold:open(grant(b), 18, Held)).

%% A opens 17 twice: the second open adds a handle and asks for no second monitor.
%% Closing the first handle keeps the hold; closing the second releases it.
a_grant_with_two_handles_releases_at_the_last_close_test() ->
    {First, _, Once} = opened(a, 17, new()),
    {Second, [], Twice} = opened(a, 17, Once),
    {[], OneLeft} = erx_hold:close(First, Twice),
    ?assertEqual({ok, 17}, erx_hold:operate(Second, OneLeft)),
    ?assertEqual({error, ebusy}, erx_hold:open(grant(b), 17, OneLeft)),
    {Released, _} = erx_hold:close(Second, OneLeft),
    ?assertEqual([{release, 17}, {demonitor, grant(a)}], Released).

%% The design's order: A's request reaches the driver after A's end and B's open of
%% the same resource, so it finds A's handle gone, and B's handle works.
an_operation_after_its_grants_end_and_anothers_open_is_refused_test() ->
    {Stale, _, Held} = opened(a, 17, new()),
    {[{release, 17}], Ended} = erx_hold:ended(grant(a), Held),
    {Fresh, _, Retaken} = opened(b, 17, Ended),
    ?assertEqual({error, eio}, erx_hold:operate(Stale, Retaken)),
    ?assertEqual({ok, 17}, erx_hold:operate(Fresh, Retaken)).

%% A grant keeps its handle across its driver's restart; in the restarted
%% driver's core, where B holds 17 by the same steps, the kept handle is dead.
a_handle_of_an_earlier_core_is_dead_test() ->
    {Kept, _, _} = opened(a, 17, new()),
    {Fresh, _, Restarted} = opened(b, 17, new()),
    ?assertEqual({error, eio}, erx_hold:operate(Kept, Restarted)),
    ?assertEqual({[], Restarted}, erx_hold:close(Kept, Restarted)),
    ?assertEqual({ok, 17}, erx_hold:operate(Fresh, Restarted)).

%% A grant's end releases every resource it holds, in order, and leaves B's alone.
a_grants_end_releases_only_what_it_holds_test() ->
    {_, _, One} = opened(a, 18, new()),
    {_, _, Two} = opened(a, 17, One),
    {Theirs, _, Three} = opened(b, 19, Two),
    {Released, Ended} = erx_hold:ended(grant(a), Three),
    ?assertEqual([{release, 17}, {release, 18}], Released),
    ?assertEqual({ok, 19}, erx_hold:operate(Theirs, Ended)).

%% A dead handle's close and operation change nothing and answer nothing but eio.
a_dead_handle_changes_nothing_test() ->
    {Handle, _, Held} = opened(a, 17, new()),
    {_, Closed} = erx_hold:close(Handle, Held),
    ?assertEqual({[], Closed}, erx_hold:close(Handle, Closed)),
    ?assertEqual({error, eio}, erx_hold:operate(Handle, Closed)).

%% A grant stays monitored while it holds anything: closing its handle on 17 while
%% it still holds 18 asks for no demonitor.
a_grant_is_demonitored_when_it_holds_nothing_test() ->
    {On17, [{monitor, _}], One} = opened(a, 17, new()),
    {On18, [], Two} = opened(a, 18, One),
    {[{release, 17}], Left} = erx_hold:close(On17, Two),
    ?assertMatch({[{release, 18}, {demonitor, _}], _}, erx_hold:close(On18, Left)).

%% ---------------------------------------------------------------------------
%% Every sequence of up to six events
%% ---------------------------------------------------------------------------

%% The model is independent of the core's map of holds: it keeps every handle the
%% core ever made, numbered in order, with its grant, its resource and whether it is
%% still open, and states the design's rules over those handles alone:
%%   - an open is busy exactly when another grant has an open handle on the resource
%%     (so no two grants ever hold one resource); otherwise it makes a handle never
%%     seen before, with a monitor when the grant had no open handle at all;
%%   - a resource is released exactly when its last open handle closes or its grant
%%     ends, so exactly once per hold; a demonitor follows a close that leaves the
%%     grant no open handle;
%%   - an operation is applied exactly when its handle is open;
%%   - a dead handle's close and every operation leave the core as it was.
-record(h, {handle, grant, resource, open = true}).

every_sequence_of_six_events_over_two_grants_and_two_resources_test() ->
    Sequences = explore(new(), #{}, [], ?DEPTH),
    io:format(user, "~nerx_hold: ~b event sequences~n", [Sequences]),
    %% Which events may come next depends on the model alone, so the count is
    %% fixed: it pins the exploration's reach.
    ?assertEqual(?SEQUENCES, Sequences).

explore(_Core, _Model, _Trace, 0) ->
    1;
explore(Core, Model, Trace, Depth) ->
    lists:sum([begin
                   Trace1 = [Event | Trace],
                   {Core1, Model1} =
                       check(Event, Core, Model, lists:reverse(Trace1)),
                   explore(Core1, Model1, Trace1, Depth - 1)
               end || Event <- events(Model)]).

%% Any grant may open any resource, and end, at any time; a close or an operation
%% may name any handle the core made, closed and ended ones included.
events(Model) ->
    Handles = lists:sort(maps:keys(Model)),
    [{open, G, R} || G <- ?GRANTS, R <- ?RESOURCES]
        ++ [{close, N} || N <- Handles]
        ++ [{'end', G} || G <- ?GRANTS]
        ++ [{operate, N} || N <- Handles].

check({open, G, R}, Core, Model, Trace) ->
    Answer = erx_hold:open(grant(G), R, Core),
    case [H || _ := #h{grant = G1, resource = R1, open = true} = H <- Model,
               R1 =:= R, G1 =/= G] of
        [_ | _] ->
            expect(Trace, {error, ebusy}, Answer),
            {Core, Model};
        [] ->
            ?assertMatch({Trace, {ok, _, _, _}}, {Trace, Answer}),
            {ok, Handle, Actions, Core1} = Answer,
            Monitor = [{monitor, grant(G)} || open_of_grant(G, Model) =:= []],
            expect(Trace, Monitor, Actions),
            Earlier = [H#h.handle || _ := H <- Model],
            expect(Trace, false, lists:member(Handle, Earlier)),
            New = #h{handle = Handle, grant = G, resource = R},
            {Core1, Model#{map_size(Model) + 1 => New}}
    end;
check({close, N}, Core, Model, Trace) ->
    H = maps:get(N, Model),
    #h{handle = Handle, grant = G, resource = R, open = Open} = H,
    {Actions, Core1} = erx_hold:close(Handle, Core),
    Model1 = Model#{N := H#h{open = false}},
    case Open of
        true ->
            Release = [{release, R} || open_on_resource(R, Model1) =:= []],
            Demonitor = [{demonitor, grant(G)} || open_of_grant(G, Model1) =:= []],
            expect(Trace, Release ++ Demonitor, Actions);
        false ->
            expect(Trace, {[], Core}, {Actions, Core1})
    end,
    {Core1, Model1};
check({'end', G}, Core, Model, Trace) ->
    {Actions, Core1} = erx_hold:ended(grant(G), Core),
    Ending = #{N => H#h{open = false}
               || N := #h{grant = G1, open = true} = H <- Model, G1 =:= G},
    Held = lists:usort([R || _ := #h{resource = R} <- Ending]),
    expect(Trace, [{release, R} || R <- Held], Actions),
    {Core1, maps:merge(Model, Ending)};
check({operate, N}, Core, Model, Trace) ->
    #h{handle = Handle, resource = R, open = Open} = maps:get(N, Model),
    Expected = case Open of
                   true -> {ok, R};
                   false -> {error, eio}
               end,
    expect(Trace, Expected, erx_hold:operate(Handle, Core)),
    {Core, Model}.

%% The numbers of the grant's, or the resource's, open handles.
open_of_grant(G, Model) ->
    [N || N := #h{grant = G1, open = true} <- Model, G1 =:= G].

open_on_resource(R, Model) ->
    [N || N := #h{resource = R1, open = true} <- Model, R1 =:= R].

%% A failure shows the event sequence that led to it beside both values.
expect(Trace, Expected, Actual) ->
    ?assertEqual({Trace, Expected}, {Trace, Actual}).
