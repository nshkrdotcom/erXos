%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_desk_clock_core_tests).
-moduledoc """
EUnit cases of clock's core (docs/design-desktop-programs.md, "clock", the
clock rows of "Verification and testing", D3, D5 and D6), fed recorded wall
readings and inspector answers. A world is an inspector model: a map from
each path clock asks, `[time]` and `[]`, to the answer erx:inspect/2 gives
it. Trees are read through erx_ui_query, never by position.
""".

-include_lib("eunit/include/eunit.hrl").

-define(CORE, erx_desk_clock_core).
-define(UI_NODES, 10000).

%%% Worlds.

%% The time page in State, and a machine up UptimeNs nanoseconds.
world(State, UptimeNs) ->
    #{[time] => record([time], clock, #{state => {kernel, {ok, State}}}),
      [] => record([], machine, #{uptime => {kernel, {ok, UptimeNs}}})}.

%% An answer of erx_inspector's answer() shape: a record whose attributes
%% are {Reporter, Value}.
record(Path, Kind, Attrs) ->
    {ok, #{schema => 1, path => Path, kind => Kind, id => Path, children => [], attrs => Attrs}}.

%% Milliseconds of the wall clock at DateTime, UTC.
at(DateTime) ->
    (calendar:datetime_to_gregorian_seconds(DateTime) - 62167219200) * 1000.

%%% Driving the core.

fresh() ->
    {State, [{tick_after, 0}]} = ?CORE:init(#{}),
    State.

%% A tick at Now, each inspection it asks answered from World with the wall
%% clock still at Now after the answer: the state
%% after the answers and the delay of the tick it asks for.
tick(Now, World, State0) ->
    {State1, Effects} = ?CORE:step({tick, Now}, State0),
    [Ms] = [Ms || {tick_after, Ms} <- Effects],
    Answer = fun({inspect, Tag, Path}, State) ->
                     {Next, []} = ?CORE:step({inspected, Tag, maps:get(Path, World), Now}, State),
                     Next;
                (_Other, State) ->
                     State
             end,
    {lists:foldl(Answer, State1, Effects), Ms}.

shown(Now, World) ->
    {State, _Ms} = tick(Now, World, fresh()),
    ?CORE:view(State).

text(Query, Tree) ->
    maps:get(text, erx_ui_query:find(Query, Tree)).

absent(Query, Tree) ->
    ?assertError({no_node, _}, erx_ui_query:find(Query, Tree)).

%%% clock: states (D3).

-define(NOW, {{2026, 11, 15}, {14, 7, 31}}).

the_set_clock_shows_the_time_and_date_test() ->
    Tree = shown(at(?NOW), world(set, 1)),
    ?assertEqual(<<"14:07">>, text(#{role => display}, Tree)),
    ?assertEqual(#{text => <<"Sunday 15 November 2026">>},
                 maps:with([text], erx_ui_query:find(#{text => <<"Sunday 15 November 2026">>, role => body}, Tree))),
    ?assertEqual(<<"UTC">>, text(#{text => <<"UTC">>, role => caption}, Tree)),
    absent(#{text => <<"from the real-time clock">>}, Tree).

the_boot_clock_says_where_the_time_came_from_test() ->
    Tree = shown(at(?NOW), world(boot, 1)),
    ?assertEqual(<<"14:07">>, text(#{role => display}, Tree)),
    _ = erx_ui_query:find(#{text => <<"Sunday 15 November 2026">>}, Tree),
    _ = erx_ui_query:find(#{text => <<"from the real-time clock">>, role => caption}, Tree).

the_approximate_clock_says_where_the_time_came_from_test() ->
    Tree = shown(at(?NOW), world(approximate, 1)),
    ?assertEqual(<<"14:07">>, text(#{role => display}, Tree)),
    _ = erx_ui_query:find(#{text => <<"Sunday 15 November 2026">>}, Tree),
    _ = erx_ui_query:find(#{text => <<"approximate, from the build date">>, role => caption}, Tree).

%% An unset clock reads the time since boot from 1970: twelve minutes in,
%% a core that ignored the state would show 00:12 on 1 January 1970.
the_unset_clock_shows_no_date_test() ->
    Twelve = 12 * 60 * 1000,
    Tree = shown(Twelve, world(unset, Twelve * 1000000)),
    ?assertEqual(<<"--:--">>, text(#{role => display}, Tree)),
    _ = erx_ui_query:find(#{text => <<"Clock not set">>}, Tree),
    _ = erx_ui_query:find(#{text => <<"12 minutes since boot">>}, Tree),
    absent(#{text => <<"Thursday 1 January 1970">>}, Tree),
    One = shown(Twelve, world(unset, 60 * 1000000000 + 5)),
    _ = erx_ui_query:find(#{text => <<"1 minute since boot">>}, One).

%% An unset clock whose uptime the machine record does not give shows that
%% reading's status, not a count.
the_unset_clock_without_uptime_shows_its_status_test() ->
    World = (world(unset, 0))#{[] => {error, timeout}},
    Tree = shown(720000, World),
    ?assertEqual(<<"--:--">>, text(#{role => display}, Tree)),
    _ = erx_ui_query:find(#{text => {kernel, {error, timeout}}}, Tree).

%% Each status that is not ok shows the time and date, since the reading
%% may still be the time since boot, with the status token beside the zone.
a_state_that_is_not_ok_shows_its_token_test() ->
    Cases = [{record([time], clock, #{state => {kernel, unknown}}), {kernel, unknown}},
             {record([time], clock, #{state => {kernel, unsupported}}), {kernel, unsupported}},
             {record([time], clock, #{state => {kernel, {timeout, 5}}}), {kernel, {timeout, 5}}},
             {record([time], clock, #{}), {kernel, unknown}},
             {{error, unsupported}, {kernel, unsupported}},
             {{error, scope}, {kernel, {error, scope}}}],
    lists:foreach(
      fun({Answer, Token}) ->
              Tree = shown(at(?NOW), (world(set, 1))#{[time] => Answer}),
              ?assertEqual(<<"14:07">>, text(#{role => display}, Tree)),
              _ = erx_ui_query:find(#{text => <<"Sunday 15 November 2026">>}, Tree),
              _ = erx_ui_query:find(#{text => <<"UTC">>}, Tree),
              ?assertEqual(Token, text(#{text => Token}, Tree))
      end, Cases).

a_failed_worker_shows_its_error_test() ->
    {State1, Effects} = ?CORE:step({tick, at(?NOW)}, fresh()),
    [TimeTag] = [Tag || {inspect, Tag, [time]} <- Effects],
    [MachineTag] = [Tag || {inspect, Tag, []} <- Effects],
    {State2, []} = ?CORE:step({failed, TimeTag, killed}, State1),
    {State3, []} = ?CORE:step({inspected, MachineTag, maps:get([], world(set, 1)), at(?NOW)}, State2),
    Tree = ?CORE:view(State3),
    _ = erx_ui_query:find(#{text => {kernel, {error, killed}}}, Tree).

%% A clock set between a tick's wall reading and its `[time]` answer: the
%% tick read twelve minutes since boot from 1970, and `[time]` answered
%% `set` with the wall clock already at the set time. The reading shows
%% the wall clock read after the state, never 00:12 on 1 January 1970 as a
%% set date.
a_clock_set_between_the_reads_shows_the_later_reading_test() ->
    Twelve = 12 * 60 * 1000,
    World = world(set, Twelve * 1000000),
    {State1, Effects} = ?CORE:step({tick, Twelve}, fresh()),
    [TimeTag] = [Tag || {inspect, Tag, [time]} <- Effects],
    [MachineTag] = [Tag || {inspect, Tag, []} <- Effects],
    {State2, []} = ?CORE:step({inspected, TimeTag, maps:get([time], World), at(?NOW)}, State1),
    {State3, []} = ?CORE:step({inspected, MachineTag, maps:get([], World), Twelve}, State2),
    Tree = ?CORE:view(State3),
    ?assertEqual(<<"14:07">>, text(#{role => display}, Tree)),
    _ = erx_ui_query:find(#{text => <<"Sunday 15 November 2026">>}, Tree),
    absent(#{text => <<"Thursday 1 January 1970">>}, Tree).

%% Before its first reading the window shows no time.
the_first_view_shows_no_time_test() ->
    ?assertEqual(<<"--:--">>, text(#{role => display}, ?CORE:view(fresh()))).

%%% clock: ticks.

%% Each tick shows the minute it read and asks for the delay from its
%% reading to the next minute's start, so a step of the wall clock is
%% shown by the first tick after it and an early tick shows the minute it
%% read.
each_tick_shows_the_minute_it_read_test() ->
    World = world(set, 1),
    T0 = at({{2026, 11, 15}, {14, 7, 0}}),
    Readings = [{T0 + 30000, <<"14:07">>, 30000},
                {T0 + 60000, <<"14:08">>, 60000},
                {T0 + 60000 + 3 * 3600000 + 17000, <<"17:08">>, 43000},
                {T0 - 600000 + 2000, <<"13:57">>, 58000},
                {T0 + 59995, <<"14:07">>, 5}],
    lists:foldl(
      fun({Now, Shown, Delay}, State0) ->
              {State, Ms} = tick(Now, World, State0),
              ?assertEqual({Shown, Delay, Now + Delay},
                           {text(#{role => display}, ?CORE:view(State)), Ms, ?CORE:next_deadline(State)}),
              State
      end, fresh(), Readings).

%% A tick that comes while the last one's answers wait cancels them, and an
%% answer of the earlier tick changes nothing.
an_answer_of_an_earlier_tick_changes_nothing_test() ->
    T0 = at(?NOW),
    {State1, Effects1} = ?CORE:step({tick, T0}, fresh()),
    Old = [Tag || {inspect, Tag, _Path} <- Effects1],
    {State2, Effects2} = ?CORE:step({tick, T0 + 60000}, State1),
    ?assertEqual(lists:sort([{cancel, Tag} || Tag <- Old]),
                 lists:sort([Effect || {cancel, _} = Effect <- Effects2])),
    {State3, []} = ?CORE:step({inspected, hd(Old), maps:get([time], world(set, 1)), T0}, State2),
    ?assertEqual(?CORE:view(State2), ?CORE:view(State3)).

%%% D5: every tree is valid, whatever the inspector answers.

%% Every form of answer for `[time]` against every form for `[]`, each
%% with a random wall reading and random numbers within it.
every_tree_is_valid_test() ->
    rand:seed(exsss, {7, 11, 13}),
    Uptime = fun() -> rand:uniform(1 bsl 64) - 1 end,
    Times = answers(clock, state, [unset, boot, approximate, set, later, 7]),
    Machines = answers(machine, uptime, [Uptime, -1, <<"x">>]),
    lists:foreach(
      fun({Time, Machine}) ->
              Tree = shown(rand:uniform(1 bsl 46) - 1, #{[time] => Time, [] => Machine()}),
              ?assertEqual(ok, erx_ui_schema:validate(Tree, ?UI_NODES))
      end, [{Time, Machine} || Time <- [T() || T <- Times], Machine <- Machines]),
    ?assertEqual(ok, erx_ui_schema:validate(?CORE:view(fresh()), ?UI_NODES)).

%% Each form an answer takes, as a function that makes one: a record with
%% Name from each reporter, with each value, a status, or none, and a failed
%% query. A value that is a function is drawn anew each time.
answers(Kind, Name, Values) ->
    Drawn = fun(Value) when is_function(Value) -> Value(); (Value) -> Value end,
    Attrs = [{ok, Value} || Value <- Values] ++ [{partial, Value} || Value <- Values]
        ++ [unknown, unsupported, timeout, {error, eio}],
    Status = fun(timeout) -> {timeout, rand:uniform(16#ffffffff)};
                ({Form, Value}) -> {Form, Drawn(Value)};
                (Form) -> Form
             end,
    [fun() -> record([Kind], Kind, #{Name => {Reporter, Status(Attr)}}) end
     || Reporter <- [kernel, service, runtime, {stopgap, liberx_pool}], Attr <- Attrs]
        ++ [fun() -> Answer end
            || Answer <- [record([Kind], Kind, #{}), {error, unsupported}, {error, scope},
                          {error, {failed, [1, 2]}}]].

%%% D6: clock issues one tree a minute.

%% Over a simulated day started mid-minute, each tick at the delay the last
%% one asked for, clock ticks once at its start and once a minute, each tick
%% changing its tree, and every tick after the first lands on a minute's
%% start.
one_tree_a_minute_test() ->
    World = world(set, 1),
    Start = at({{2026, 11, 15}, {14, 7, 23}}) + 456,
    Fresh = fresh(),
    {Ticks, Trees, Late} = day(Start, Start + 86400000, World, Fresh, ?CORE:view(Fresh), {0, 0, 0}),
    ?assertEqual({1441, 1441, 1}, {Ticks, Trees, Late}).

day(Now, End, _World, _State, _Last, Counts) when Now >= End ->
    Counts;
day(Now, End, World, State0, Last, {Ticks, Trees, Late}) ->
    {State, Ms} = tick(Now, World, State0),
    Tree = ?CORE:view(State),
    Changed = case Tree of Last -> 0; _ -> 1 end,
    OffMinute = case Now rem 60000 of 0 -> 0; _ -> 1 end,
    day(Now + Ms, End, World, State, Tree, {Ticks + 1, Trees + Changed, Late + OffMinute}).
