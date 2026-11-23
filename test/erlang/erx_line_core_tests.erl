%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Explores erx_line_core, the line keeper's state machine (docs/design-bluetooth.md, "The
%% controller's line", "A reset"), exhaustively up to a bound: from a fresh line, every
%% event the world can send in every reachable state, breadth first, each state once.
%% The bound, ?DEPTH events, holds three requests and two resets that each power cycle
%% (six events of the world apiece); past it only the buffer's length grows.
%%
%% The world is a model of what the edge, erx_line, and the processes around it do. The
%% edge's two process-making actions are stepped at once with their result: a start
%% answers both {ok, Pid} and {error, refused}, each a branch, and a notifier is a fresh
%% process. The world then sends, in any order: a read, a write or a reset (at most
%% ?REQUESTS in all), a flush of any request held, a byte of input or more input than the
%% buffer holds, the written answer of any write a driver holds, a late answer no write
%% matches, the end of any process (a driver's crash, an ended one's exit, a notifier's
%% answer of ok or of a refusal), and any timer the core started.
%%
%% After each event the state must hold:
%%
%% * no driver started with flow none survives a reset: outside a reset there is none;
%% * the one driver of the grant's flow alive is the core's driver, and bytes are sent
%%   only to it;
%% * a reset in progress waits for an event the world can still send, so it ends;
%% * a reset answers ok only with a fresh driver and an empty buffer, and eio only with
%%   the line broken with none;
%% * each timer waits the power line's own off or on time.
-module(erx_line_core_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").
-include("erx_fs_waits.hrl").

-define(REQUESTS, 3).
-define(DEPTH, 18).
-define(RESET_DONE, {ok, 5, 0}).

%% The world: the core, the processes the edge made, each {Pid, Kind, live | killed},
%% the timers not yet fired, the written answers drivers owe as {Driver, Token}, the
%% requests sent and the waits of the resets among them, and the power line's times.
-record(world, {core, procs = [], timers = [], owed = [], sent = 0, resets = [], next = 0, power}).

explore_without_a_power_line_test_() ->
    {timeout, 120, fun() -> explore(none) end}.

explore_with_a_power_line_test_() ->
    {timeout, 120, fun() -> explore(#{off => 60, on => 90}) end}.

explore(Power) ->
    Grant = spawn(fun() -> receive stop -> ok end end),
    {Core, Actions} = erx_line_core:new(Power),
    try
        Starts = perform(Actions, #world{core = Core, power = Power}),
        Seen = bfs([{W, 0} || W <- Starts], #{}, Grant),
        Steps = lists:usort([step_kind(Step) || {_, _, Step} <- maps:values(Seen)]),
        %% The bound reaches every step of the reset, so the exploration is not vacuous.
        Expected = case Power of
                       none -> [idle, stopping];
                       _ -> [failing, idle, notifying, releasing, stopping, waiting]
                   end,
        ?assertEqual(Expected, Steps)
    after
        Grant ! stop
    end.

step_kind(none) -> idle;
step_kind({stopping, _}) -> stopping;
step_kind({notifying, _, _}) -> notifying;
step_kind({waiting, _}) -> waiting;
step_kind(Atom) when is_atom(Atom) -> Atom.

%% Breadth first over unseen states; Seen maps a state's key to its reset step.
bfs([], Seen, _Grant) ->
    Seen;
bfs([{W, Depth} | Queue], Seen, Grant) ->
    Key = key(W),
    case Seen of
        #{Key := _} ->
            bfs(Queue, Seen, Grant);
        #{} ->
            #{reset := Reset} = erx_line_core:facts(W#world.core),
            Step = case Reset of none -> none; {_, _, S} -> S end,
            Next = case Depth < ?DEPTH of
                       true -> [{N, Depth + 1} || E <- events(W, Grant), N <- deliver(E, W)];
                       false -> []
                   end,
            bfs(Queue ++ Next, Seen#{Key => {W, Depth, Step}}, Grant)
    end.

%% The world's events --------------------------------------------------------

events(#world{core = Core, procs = Procs, timers = Timers, owed = Owed, sent = Sent}, Grant) ->
    #{requests := Requests} = erx_line_core:facts(Core),
    New = case Sent < ?REQUESTS of
              true -> [{request, {Grant, alias()}, Request}
                       || Request <- [{read, 1}, {write, 0, <<"w">>}, {reset, 0, 5}]];
              false -> []
          end,
    Ends = lists:append([ends(Proc) || Proc <- Procs]),
    New ++
        [{info, ?ERX_FS_FLUSH(Wait)} || {Wait, _, _} <- Requests] ++
        [{info, {erx_console_input, <<"i">>}},
         {info, {erx_console_input, binary:copy(<<"x">>, ?ERX_LINE_RX_MAX + 1)}},
         {info, {erx_console_written, late}}] ++
        [{owed, Owe} || Owe <- Owed] ++
        [{ended, Pid, Reason} || {Pid, Reason} <- Ends] ++
        [{timer, Token} || Token <- Timers].

ends({Pid, _Kind, killed}) -> [{Pid, killed}];
ends({Pid, notifier, live}) -> [{Pid, {notified, ok}}, {Pid, {notified, {error, refused}}}];
ends({Pid, {driver, _}, live}) -> [{Pid, crashed}].

deliver({request, Wait, Request}, #world{sent = Sent, resets = Resets} = W) ->
    Marked = case Request of
                 {reset, _, _} -> [Wait | Resets];
                 _ -> Resets
             end,
    run({info, ?ERX_FS_WAIT(Wait, Request)}, W#world{sent = Sent + 1, resets = Marked});
deliver({owed, {_Driver, Token} = Owe}, #world{owed = Owed} = W) ->
    run({info, {erx_console_written, Token}}, W#world{owed = Owed -- [Owe]});
deliver({ended, Pid, Reason}, #world{procs = Procs, owed = Owed} = W) ->
    %% A process's messages arrive before its end; what it still owed it never sends.
    run({info, {'EXIT', Pid, Reason}},
        W#world{procs = lists:keydelete(Pid, 1, Procs), owed = [O || {D, _} = O <- Owed, D =/= Pid]});
deliver({timer, Token}, #world{timers = Timers} = W) ->
    run({info, {timeout, make_ref(), Token}}, W#world{timers = Timers -- [Token]});
deliver({info, _} = Event, W) ->
    run(Event, W).

%% The edge -------------------------------------------------------------------

%% One event stepped and its actions performed: every world it can lead to, each checked.
run(Event, W) ->
    [check(Done) || Done <- step(Event, W)].

perform([], W) ->
    [W];
perform([{start, Flow} | Rest], W) ->
    {Pid, Made} = fresh(W),
    Started = step({started, Flow, {ok, Pid}}, add(Pid, {driver, Flow}, Made)) ++
              step({started, Flow, {error, refused}}, W),
    [Done || Next <- Started, Done <- perform(Rest, Next)];
perform([{notify, Phase} | Rest], W) ->
    {Pid, Made} = fresh(W),
    [Done || Next <- step({notifying, Phase, Pid}, add(Pid, notifier, Made)), Done <- perform(Rest, Next)];
perform([{timer, Ms, {_Wait, Phase} = Token} | Rest], #world{timers = Timers, power = Power} = W) ->
    %% Each wait is the power line's own off or on time.
    ?assertEqual(maps:get(Phase, Power), Ms),
    perform(Rest, W#world{timers = [Token | Timers]});
perform([{output, Driver, Token, _Bytes} | Rest], #world{core = Core, procs = Procs, owed = Owed} = W) ->
    %% Bytes go only to the core's driver, alive with the grant's flow.
    ?assertMatch(#{driver := Driver, reset := none}, erx_line_core:facts(Core)),
    ?assertMatch({Driver, {driver, grant}, live}, lists:keyfind(Driver, 1, Procs)),
    perform(Rest, W#world{owed = [{Driver, Token} | Owed]});
perform([{kill, Pid} | Rest], #world{procs = Procs} = W) ->
    {Pid, Kind, live} = lists:keyfind(Pid, 1, Procs),
    perform(Rest, W#world{procs = lists:keystore(Pid, 1, Procs, {Pid, Kind, killed})}).

%% The core answers through erx_fs_waits, which sends each answer as it is made, so a
%% step's answers are in the mailbox when it returns, apart from any other branch's. A
%% reset answers ok only at its fresh driver's start, with the buffer empty, and eio only
%% leaving the line broken with no driver, which a reset that begins in the same step keeps.
step(Event, #world{resets = Resets} = W) ->
    {Core, Actions} = erx_line_core:step(Event, W#world.core),
    #{driver := Driver, broken := Broken, rx := Rx} = erx_line_core:facts(Core),
    [answered(Result, Event, {Driver, Broken, Rx})
     || {Alias, Result} <- answers(), lists:keymember(Alias, 2, Resets)],
    perform(Actions, W#world{core = Core}).

fresh(#world{next = Next} = W) ->
    {list_to_pid("<0." ++ integer_to_list(900000 + Next) ++ ".0>"), W#world{next = Next + 1}}.

add(Pid, Kind, #world{procs = Procs} = W) ->
    W#world{procs = [{Pid, Kind, live} | Procs]}.

%% The invariants -------------------------------------------------------------

check(#world{core = Core, procs = Procs, timers = Timers} = W) ->
    #{driver := Driver, reset := Reset} = erx_line_core:facts(Core),
    Holding = [Pid || {Pid, {driver, none}, _} <- Procs],
    Grants = [Pid || {Pid, {driver, grant}, live} <- Procs],
    ?assertEqual([D || D <- [Driver], D =/= none], Grants),
    case Reset of
        none ->
            ?assertEqual([], Holding);
        {Wait, HoldingPid, Step} ->
            ?assert(length(Holding) =< 1),
            ?assert(awaited(Step, Wait, HoldingPid, Procs, Timers))
    end,
    W.

answered(?RESET_DONE, Event, {_Driver, _Broken, Rx}) ->
    ?assertMatch({started, grant, {ok, _}}, Event),
    ?assertEqual(<<>>, Rx);
answered({error, eio}, _Event, {Driver, Broken, _Rx}) ->
    ?assertEqual({none, true}, {Driver, Broken});
answered({error, eintr}, _Event, _Line) ->
    ok.

answers() ->
    receive ?ERX_FS_ANSWER(Alias, Result) -> [{Alias, Result} | answers()]
    after 0 -> []
    end.

%% Whether the world can still send the event a reset's step waits for.
awaited({stopping, Old}, _Wait, _Holding, Procs, _Timers) ->
    lists:keymember(Old, 1, Procs);
awaited({notifying, _Phase, Notifier}, _Wait, _Holding, Procs, _Timers) ->
    lists:member({Notifier, notifier, live}, Procs);
awaited({waiting, Phase}, Wait, _Holding, _Procs, Timers) ->
    lists:member({Wait, Phase}, Timers);
awaited(Ending, _Wait, Holding, Procs, _Timers) when Ending =:= releasing; Ending =:= failing ->
    lists:member({Holding, {driver, none}, killed}, Procs);
awaited(_Transient, _Wait, _Holding, _Procs, _Timers) ->
    false.

%% A state's key: the core's facts and the world, each pid and reference renamed by its
%% first appearance, so states that differ only in names are one.
key(#world{core = Core, procs = Procs, timers = Timers, owed = Owed, sent = Sent}) ->
    Term = {erx_line_core:facts(Core), lists:sort(Procs), lists:sort(Timers), lists:sort(Owed), Sent},
    element(1, rename(Term, #{})).

rename(Name, Names) when is_pid(Name); is_reference(Name) ->
    case Names of
        #{Name := N} -> {{n, N}, Names};
        #{} -> N = map_size(Names), {{n, N}, Names#{Name => N}}
    end;
rename(Tuple, Names) when is_tuple(Tuple) ->
    {List, Renamed} = rename(tuple_to_list(Tuple), Names),
    {list_to_tuple(List), Renamed};
rename([Head | Tail], Names) ->
    {H, N1} = rename(Head, Names),
    {T, N2} = rename(Tail, N1),
    {[H | T], N2};
rename(Map, Names) when is_map(Map) ->
    {List, Renamed} = rename(lists:sort(maps:to_list(Map)), Names),
    {maps:from_list(List), Renamed};
rename(Other, Names) ->
    {Other, Names}.
