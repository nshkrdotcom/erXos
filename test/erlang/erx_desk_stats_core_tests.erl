%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_desk_stats_core_tests).
-moduledoc """
EUnit cases of stats' core (docs/design-desktop-programs.md, "stats" and the
stats rows of "Verification and testing"), fed recorded inspector answers
and ticks. A world is an inspector model: a map from each path to the
answer erx:inspect/2 gives it, any other path answering `{error, scope}`
as the inspector answers a path that names nothing.
""".

-include_lib("eunit/include/eunit.hrl").

%%% Worlds.

%% One CPU {Id, IdleNs, ReadyThreads}, one domain a map of its numbers. A
%% domain's connections answer `{error, scope}` unless the map says
%% otherwise, as the inspector answers a path abi/inspection.txt does not
%% declare.
world(Cpus, {Total, Free}, Domains) ->
    maps:merge(
      maps:from_list(
        [{[], record([], #{memory_total => Total, memory_free => Free,
                           cpus_online => {ok, length(Cpus)}})},
         {[cpus], listing([cpus], [Id || {Id, _, _} <- Cpus])},
         {[domains], listing([domains], [maps:get(id, D) || D <- Domains])}
         | [{[cpus, Id], record([cpus, Id], #{idle_time => Idle, ready_threads => Ready})}
            || {Id, Idle, Ready} <- Cpus]]),
      maps:from_list(lists:flatmap(fun domain/1, Domains))).

domain(#{id := Id} = D) ->
    Path = [domains, Id],
    Field = fun(Name, Default) -> maps:get(Name, D, Default) end,
    [{Path, record(Path, #{name => {ok, <<"d">>}, state => {ok, running},
                           run_queue => {ok, 2}, processes => {ok, 30}})},
     {Path ++ [group], record(Path ++ [group], #{used_ns => Field(used, {ok, 0}),
                                                 capacity_mcpu => Field(capacity, {ok, 1000})})},
     {Path ++ [budget], record(Path ++ [budget], #{spending => Field(spending, {ok, 10}),
                                                   cap => Field(cap, {ok, 100}),
                                                   guarantee => {ok, 20}})},
     {Path ++ [connections], Field(connections, {error, scope})}].

record(Path, Attrs) ->
    {ok, #{schema => 1, path => Path, kind => machine, id => Path, children => [],
           attrs => maps:map(fun(_Name, Value) -> {kernel, Value} end, Attrs)}}.

listing(Path, Children) ->
    {ok, #{schema => 1, path => Path, kind => listing, id => Path, attrs => #{},
           children => Children}}.

%% Each answer has the shape of erx_inspector's answer() and of the schema's
%% record(): a record's attributes are {Reporter, Value}.
frames(Lanes) -> record([], #{frames => {ok, Lanes}}).

%%% Driving the core.

fresh() ->
    {State, [{tick_after, 0}]} = erx_desk_stats_core:init(),
    State.

%% One sample at Now against World, every query answered in the order
%% asked; the state and the effects other than queries.
sample(Now, World, State) ->
    {Started, Effects} = erx_desk_stats_core:step({tick, Now}, State),
    answer(Effects, World, Started, []).

answer([{inspect, Tag, Path} | Rest], World, State, Others) ->
    {Next, More} = erx_desk_stats_core:step({inspected, Tag, maps:get(Path, World, {error, scope})},
                                            State),
    answer(Rest ++ More, World, Next, Others);
answer([Effect | Rest], World, State, Others) ->
    answer(Rest, World, State, Others ++ [Effect]);
answer([], _World, State, Others) ->
    {State, Others}.

%% The samples of Worlds, one each, at times 0, 2000, 4000 and so on.
run(Worlds) ->
    {State, _Times} = lists:foldl(fun(World, {State, Now}) ->
                                          {Next, [{tick_after, 1000}]} = sample(Now, World, State),
                                          {Next, Now + 2000}
                                  end, {fresh(), 0}, Worlds),
    erx_desk_stats_core:model(State).

machine(Name, Model) -> maps:get(Name, maps:get(machine, Model)).
latest(Name, Model) -> maps:get(latest, machine(Name, Model)).
ring(Name, Model) -> maps:get(ring, machine(Name, Model)).
row(Id, Model) -> proplists:get_value(Id, maps:get(domains, Model)).
row(Id, Measure, Model) -> maps:get(Measure, row(Id, Model)).

%%% D2's table of statuses.

-define(STATUSES, [ok, partial, unknown, unsupported, timeout, error]).

reading(ok, Value) -> {ok, Value};
reading(partial, Value) -> {partial, Value};
reading(unknown, _Value) -> unknown;
reading(unsupported, _Value) -> unsupported;
reading(timeout, _Value) -> {timeout, 1000};
reading(error, _Value) -> {error, failed}.

%% The derived number D2's table gives two readings: the worse status, by
%% the order of ?STATUSES, with the value only if it is ok or partial.
expected(A, B) ->
    Worse = lists:nth(max(index(A), index(B)), ?STATUSES),
    case Worse of
        ok -> {ok, 750};
        partial -> {partial, 750};
        _ -> {gap, reading(Worse, none)}
    end.

index(Status) -> length(lists:takewhile(fun(S) -> S =/= Status end, ?STATUSES)) + 1.

derivation_follows_the_status_table_test() ->
    [begin
         Model = run([world([], {reading(A, 4000), reading(B, 1000)}, [])]),
         Expected = expected(A, B),
         ?assertEqual({A, B, Expected}, {A, B, latest(memory, Model)}),
         Point = case Expected of {ok, Share} -> Share; _ -> none end,
         ?assertEqual({A, B, [Point]}, {A, B, ring(memory, Model)})
     end || A <- ?STATUSES, B <- ?STATUSES].

%%% Shares and rates over recorded readings.

shares_and_rates_match_hand_computed_values_test() ->
    Before = world([{0, {ok, 0}, {ok, [1, 0, 2]}}, {1, {ok, 0}, {ok, [0, 1]}}], {{ok, 4000}, {ok, 1000}},
                   [#{id => 4, used => {ok, 1000000000}, capacity => {ok, 250},
                      connections => frames([100, 20])},
                    #{id => 7, used => {ok, 0}, capacity => {ok, 250}}]),
    After = world([{0, {ok, 1200000000}, {ok, [1, 0, 2]}}, {1, {ok, 800000000}, {ok, [0, 1]}}],
                  {{ok, 4000}, {ok, 1000}},
                  [#{id => 4, used => {ok, 1250000000}, capacity => {ok, 250},
                     spending => {ok, 41}, cap => {ok, 100}, connections => frames([900, 120])},
                   #{id => 7, used => {ok, 750000000}, capacity => {ok, 250}}]),
    First = run([Before]),
    ?assertEqual({gap, no_previous}, latest(cpu, First)),
    ?assertEqual({gap, no_previous}, maps:get(latest, row(4, cpu, First))),
    Model = run([Before, After]),
    %% 2 s on each of two CPUs, 2 s of it idle: busy half the time.
    ?assertEqual({ok, 500}, latest(cpu, Model)),
    ?assertEqual([none, 500], ring(cpu, Model)),
    ?assertEqual({ok, 4}, latest(load, Model)),
    ?assertEqual({ok, 750}, latest(memory, Model)),
    ?assertEqual({ok, {3000, 4000}}, machine(memory_bytes, Model)),
    %% 0.25 s used in 2 s of a 0.25 CPU grant: half the grant.
    ?assertEqual(#{latest => {ok, 500}, ring => [none, 500]}, row(4, cpu, Model)),
    ?assertEqual(#{latest => {ok, 410}, ring => [10, 41]}, row(4, memory, Model)),
    ?assertEqual({ok, 100}, row(4, cap, Model)),
    ?assertEqual({ok, 20}, row(4, guarantee, Model)),
    %% 900 frames in 2 s.
    ?assertEqual(#{latest => {ok, 450}, ring => [none, 450]}, row(4, frames, Model)),
    %% 0.75 s in 2 s of a 0.25 CPU grant: 150 percent, drawn at 100.
    ?assertEqual(#{latest => {ok, 1500}, ring => [none, 1000]}, row(7, cpu, Model)).

%%% Gaps and resets.

counter_that_goes_down_is_a_gap_test() ->
    Model = run([world([{0, {ok, 900}, {ok, []}}], {{ok, 1}, {ok, 0}}, [#{id => 4, used => {ok, 2000}}]),
                 world([{0, {ok, 100}, {ok, []}}], {{ok, 1}, {ok, 0}}, [#{id => 4, used => {ok, 1000}}])]),
    ?assertEqual(#{latest => {gap, reset}, ring => [none, none]}, machine(cpu, Model)),
    ?assertEqual(#{latest => {gap, reset}, ring => [none, none]}, row(4, cpu, Model)).

domain_that_leaves_and_returns_starts_afresh_test() ->
    Here = world([], {{ok, 1}, {ok, 0}}, [#{id => 4, used => {ok, 1000}}]),
    Gone = world([], {{ok, 1}, {ok, 0}}, []),
    ?assertEqual(undefined, row(4, run([Here, Gone]))),
    Back = run([Here, Here, Gone, Here]),
    ?assertEqual(#{latest => {gap, no_previous}, ring => [none]}, row(4, cpu, Back)).

timed_out_and_failed_queries_are_gaps_test() ->
    Ok = world([], {{ok, 1}, {ok, 0}}, [#{id => 4, used => {ok, 1000}}]),
    TimedOut = world([], {{ok, 1}, {ok, 0}}, [#{id => 4, used => {timeout, 1000}}]),
    ?assertEqual({gap, {timeout, 1000}}, maps:get(latest, row(4, cpu, run([Ok, TimedOut])))),
    %% erx:inspect/2 answers {error, failed} once its wait has passed.
    PastWait = maps:put([domains, 4, group], {error, failed}, Ok),
    ?assertEqual({gap, {error, failed}}, maps:get(latest, row(4, cpu, run([Ok, PastWait])))),
    %% A worker that ends without answering.
    {State, [{inspect, Tag, []} | Others]} = erx_desk_stats_core:step({tick, 0}, fresh()),
    {Failed, []} = erx_desk_stats_core:step({failed, Tag, killed}, State),
    {Done, _} = answer(Others, Ok, Failed, []),
    ?assertEqual({gap, {error, killed}}, latest(memory, erx_desk_stats_core:model(Done))).

no_number_is_negative_test() ->
    Up = world([{0, {ok, 900}, {ok, [1]}}], {{ok, 10}, {ok, 5}},
               [#{id => 4, used => {ok, 5000}, connections => frames([50])}]),
    Down = world([{0, {ok, 100}, {ok, [1]}}], {{ok, 10}, {ok, 5}},
                 [#{id => 4, used => {ok, 10}, connections => frames([5])}]),
    Model = run([Up, Down, Up, Down]),
    Measures = [machine(cpu, Model), machine(memory, Model), machine(load, Model)
                | [maps:get(M, Row) || {_Id, Row} <- maps:get(domains, Model), M <- [cpu, memory, frames]]],
    [?assert(V >= 0) || #{latest := Latest, ring := Ring} <- Measures,
                        V <- [Value || {S, Value} <- [Latest], S =/= gap] ++ [P || P <- Ring, P =/= none]].

%%% Pacing.

%% The queries in flight after Effects, which answer nothing.
asked(Effects) -> [Tag || {inspect, Tag, _Path} <- Effects].

at_most_one_sample_is_in_flight_test() ->
    {Waiting, Effects} = erx_desk_stats_core:step({tick, 0}, fresh()),
    ?assertEqual(3, length(asked(Effects))),
    %% The inspector answers slowly: ticks meanwhile ask nothing more.
    ?assertEqual({Waiting, []}, erx_desk_stats_core:step({tick, 1000}, Waiting)),
    ?assertEqual({Waiting, []}, erx_desk_stats_core:step({tick, 2000}, Waiting)),
    Empty = world([], {{ok, 1}, {ok, 0}}, []),
    {Done, Rest} = answer(Effects, Empty, Waiting, []),
    ?assertEqual([{tick_after, 1000}], Rest),
    {_Next, Again} = erx_desk_stats_core:step({tick, 3000}, Done),
    ?assertEqual(3, length(asked(Again))).

%%% Answers out of order.

an_answer_of_an_earlier_sample_changes_nothing_test() ->
    World = world([{0, {ok, 0}, {ok, [1]}}], {{ok, 4000}, {ok, 1000}}, [#{id => 4}]),
    {_State0, FirstEffects} = erx_desk_stats_core:step({tick, 0}, fresh()),
    [OldTag | _] = asked(FirstEffects),
    {Sampled, _} = sample(0, World, fresh()),
    {Later, _} = erx_desk_stats_core:step({tick, 2000}, Sampled),
    Late = record([], #{memory_total => {ok, 4000}, memory_free => {ok, 0}}),
    ?assertEqual({Later, []}, erx_desk_stats_core:step({inspected, OldTag, Late}, Later)),
    ?assertEqual({Later, []}, erx_desk_stats_core:step({failed, OldTag, killed}, Later)).

%%% Partial history and zero denominators.

partial_sample_leaves_a_gap_test() ->
    Ok = world([{0, {ok, 0}, {ok, []}}], {{ok, 1000}, {ok, 500}}, []),
    Partial = world([{0, {partial, 1000000000}, {ok, []}}], {{partial, 1000}, {ok, 500}}, []),
    Later = world([{0, {ok, 2000000000}, {ok, []}}], {{ok, 1000}, {ok, 500}}, []),
    ?assertEqual({partial, 500}, latest(memory, run([Ok, Partial]))),
    Model = run([Ok, Partial, Later, Later]),
    ?assertEqual([500, none, 500, 500], ring(memory, Model)),
    %% A rate from a partial reading and an ok one is partial, so a gap too.
    ?assertEqual([none, none, none, 1000], ring(cpu, Model)).

zero_denominators_give_their_facts_test() ->
    Zero = world([], {{ok, 0}, {ok, 0}}, [#{id => 4, capacity => {ok, 0}, cap => {ok, 0}}]),
    Model = run([Zero, Zero]),
    ?assertEqual(#{latest => {gap, no_total}, ring => [none, none]}, machine(memory, Model)),
    ?assertEqual(#{latest => {gap, no_cpus}, ring => [none, none]}, machine(cpu, Model)),
    ?assertEqual(#{latest => {gap, no_grant}, ring => [none, none]}, row(4, cpu, Model)),
    ?assertEqual(#{latest => {gap, no_cap}, ring => [none, none]}, row(4, memory, Model)).

%%% The connections path.

undeclared_connections_keep_their_rows_test() ->
    World = world([], {{ok, 1}, {ok, 0}}, [#{id => 4}, #{id => 9}]),
    Model = run([World, World]),
    ?assertEqual([4, 9], [Id || {Id, _Row} <- maps:get(domains, Model)]),
    [?assertEqual(#{latest => {gap, {error, scope}}, ring => [none, none]}, maps:get(frames, Row))
     || {_Id, Row} <- maps:get(domains, Model)].

unsupported_connections_show_the_token_test() ->
    World = world([], {{ok, 1}, {ok, 0}}, [#{id => 4, connections => {error, unsupported}},
                                           #{id => 9, connections => {error, unsupported}}]),
    Model = run([World, World]),
    [?assertEqual(#{latest => {gap, unsupported}, ring => [none, none]}, maps:get(frames, Row))
     || {_Id, Row} <- maps:get(domains, Model)],
    ?assertEqual([4, 9], [Id || {Id, _Row} <- maps:get(domains, Model)]).

%%% A scoped facet.

%% What design-live's scoped facet answers a principal holding Ids: the
%% machine's `visible any` attributes, a CPU's idle time and ready threads
%% alone, which world/3's CPU records hold, and a listing of the
%% principal's own domains.
scoped(Idle, Ids) ->
    world([{0, {ok, Idle}, {ok, [2, 1]}}, {1, {ok, Idle}, {ok, []}}], {{ok, 8000}, {ok, 2000}},
          [#{id => Id} || Id <- Ids]).

scoped_facet_shows_the_same_machine_test() ->
    One = run([scoped(0, [4]), scoped(500000000, [4])]),
    Two = run([scoped(0, [9, 11]), scoped(500000000, [9, 11])]),
    ?assertEqual({ok, 750}, latest(cpu, One)),
    [?assertEqual(machine(Name, One), machine(Name, Two)) || Name <- [cpu, memory, load, memory_bytes]],
    ?assertEqual([4], [Id || {Id, _} <- maps:get(domains, One)]),
    ?assertEqual([9, 11], [Id || {Id, _} <- maps:get(domains, Two)]),
    ?assertEqual([domains, listing, machine, sampling], lists:sort(maps:keys(One))).

%%% What it refuses.

no_facet_stops_sampling_test() ->
    {Waiting, [{inspect, First, []}, {inspect, Second, _}, {inspect, Third, _}]} =
        erx_desk_stats_core:step({tick, 0}, fresh()),
    {Stopped, Effects} = erx_desk_stats_core:step({inspected, First, {error, no_facet}}, Waiting),
    ?assertEqual([{cancel, Second}, {cancel, Third}], Effects),
    ?assertEqual(#{sampling => false}, erx_desk_stats_core:model(Stopped)),
    ?assertEqual({Stopped, []}, erx_desk_stats_core:step({tick, 1000}, Stopped)),
    ?assertEqual({Stopped, []}, erx_desk_stats_core:step({inspected, Second, {error, no_facet}}, Stopped)).

scope_ends_a_domain_and_is_an_error_for_the_machine_test() ->
    World = world([], {{ok, 1}, {ok, 0}}, [#{id => 4}, #{id => 7}]),
    Ended = maps:merge(World, #{[domains, 4] => {error, scope}, [domains, 7, group] => {error, scope},
                                [] => {error, scope}}),
    Model = run([World, Ended]),
    ?assertEqual([7], [Id || {Id, _} <- maps:get(domains, Model)]),
    ?assertEqual({gap, {error, scope}}, maps:get(latest, row(7, cpu, Model))),
    ?assertEqual({gap, {error, scope}}, latest(memory, Model)).

partial_listing_keeps_its_rows_test() ->
    Both = world([], {{ok, 1}, {ok, 0}}, [#{id => 4, used => {ok, 0}}, #{id => 7, used => {ok, 0}}]),
    Partial = maps:put([domains], {ok, #{schema => 1, path => [domains], kind => listing, id => [domains],
                                         attrs => #{}, children => {partial, [4]}}},
                       world([], {{ok, 1}, {ok, 0}}, [#{id => 4, used => {ok, 0}}])),
    Model = run([Both, Partial]),
    ?assertEqual(partial, maps:get(listing, Model)),
    ?assertEqual([4, 7], [Id || {Id, _} <- maps:get(domains, Model)]),
    ?assertEqual({gap, unknown}, maps:get(latest, row(7, cpu, Model))),
    %% The next full listing measures 7 from its last reading, 4 s before.
    Later = world([], {{ok, 1}, {ok, 0}}, [#{id => 4, used => {ok, 0}}, #{id => 7, used => {ok, 2000000000}}]),
    ?assertEqual({ok, 500}, maps:get(latest, row(7, cpu, run([Both, Partial, Later])))).

%%% Before the first sample, and time that does not advance.

nothing_sampled_is_no_listing_test() ->
    ?assertEqual(#{sampling => true, machine => #{}, listing => {gap, unknown}, domains => []},
                 erx_desk_stats_core:model(fresh())).

an_interval_that_is_not_positive_gives_no_value_test() ->
    World = world([{0, {ok, 0}, {ok, []}}], {{ok, 1}, {ok, 0}}, [#{id => 4}]),
    {First, _} = sample(5000, World, fresh()),
    {Again, _} = sample(5000, World, First),
    Model = erx_desk_stats_core:model(Again),
    ?assertEqual({gap, no_previous}, latest(cpu, Model)),
    ?assertEqual({gap, no_previous}, maps:get(latest, row(4, cpu, Model))).
