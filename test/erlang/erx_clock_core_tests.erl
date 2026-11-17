%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The clock service's decisions (docs/design-time.md, "Steps", "What it changes" and
%% "Verification and testing", decide and restart): every row of the Steps table over
%% Cold, the floor, the distance bands at their edges and the three excess values; the
%% set clause over the same pages; and what applied/3 records of a step the setter
%% applies or refuses.
-module(erx_clock_core_tests).
-include_lib("eunit/include/eunit.hrl").

-define(S, 1000000000).
-define(MS, 1000000).
-define(SOURCE, 7).
-define(OTHER, 9).
%% A floor, a build date of 2026-11-16 00:00:00 UTC, and a page offset well above it.
-define(FLOOR, (1794787200 * ?S)).
-define(C, (?FLOOR + 86400 * ?S)).
-define(M, (5 * ?S)).

page(Cold) -> #{offset => ?C, cold => Cold, monotonic => ?M}.

sample(W) -> {sample, W, 20 * ?MS, 2, {192, 0, 2, 1}}.

record(Excess) -> (erx_clock_core:new(?M, ?FLOOR))#{excess := Excess}.

%% The offsets either side of each band's edge, signed, and one of 56 years ahead, as a
%% clock that boots at 1970-01-01 meets its first sample.
offsets() ->
    lists:append([[D, -D] || D <- [0, 1, 128 * ?MS, 128 * ?MS + 1, 1000 * ?S - 1, 1000 * ?S]]) ++ [56 * 365 * 86400 * ?S].

%% The Steps table, row by row, for a sample whose time is above the floor: what the
%% sample answers and the excess it leaves.
expected(true, _D, _Excess) -> {step, none};
expected(false, D, _Excess) when abs(D) =< 128 * ?MS -> {held, none};
expected(false, D, Excess) when abs(D) < 1000 * ?S ->
    Sign = if D > 0 -> positive; true -> negative end,
    case Excess =:= Sign of
        true -> {step, none};
        false -> {held, Sign}
    end;
expected(false, _D, _Excess) -> {{refused, panic}, none}.

every_row_of_the_steps_table_test_() ->
    [{lists:flatten(io_lib:format("cold ~p, D ~b, excess ~p", [Cold, D, Excess])),
      fun() -> row_case(Cold, D, Excess) end}
     || Cold <- [true, false], D <- offsets(), Excess <- [none, positive, negative]].

row_case(Cold, D, Excess) ->
    W = ?C + D,
    Record = record(Excess),
    {Result, Left} = expected(Cold, D, Excess),
    Decision = erx_clock_core:decide(sample(W), ?SOURCE, page(Cold), Record),
    Sampled = #{sample_at => ?M + ?C, offset_ns => D, distance_ns => 20 * ?MS, stratum => 2,
                server => {192, 0, 2, 1}, source => ?SOURCE, excess => Left},
    case {Result, Decision} of
        {step, {step, Step, Record1}} ->
            ?assertEqual(#{offset => W, step_ns => D, at => ?M + W, source => ?SOURCE}, Step),
            ?assertEqual(maps:merge(Record, Sampled), Record1);
        {held, {answer, {ok, held}, Record1}} ->
            ?assertEqual(maps:merge(Record, Sampled), Record1);
        {{refused, panic}, {answer, {ok, {refused, panic}}, Record1}} ->
            ?assertEqual(maps:merge(Record, Sampled#{refused => 1}), Record1)
    end.

%% A sample before the floor is refused, cold or not and whatever its offset, and a
%% sample at the floor is not.
the_floor_test() ->
    [begin
         Page = #{offset => 0, cold => Cold, monotonic => ?M},
         {answer, {ok, {refused, floor}}, Record1} =
             erx_clock_core:decide(sample(?FLOOR - ?M - 1), ?SOURCE, Page, record(Excess)),
         ?assertMatch(#{excess := none, refused := 1, source := ?SOURCE, offset_ns := ?FLOOR - ?M - 1}, Record1)
     end || Cold <- [true, false], Excess <- [none, positive, negative]],
    ?assertMatch({step, #{offset := ?FLOOR - ?M}, _},
                 erx_clock_core:decide(sample(?FLOOR - ?M), ?SOURCE, #{offset => 0, cold => true, monotonic => ?M},
                                       record(none))).

%% A restarted service's record, with the page no longer cold, refuses a sample 2000 s
%% off: the page, not the record, says whether the clock was set this boot.
restart_test() ->
    ?assertMatch({answer, {ok, {refused, panic}}, _},
                 erx_clock_core:decide(sample(?C + 2000 * ?S), ?SOURCE, page(false), erx_clock_core:new(0, ?FLOOR))).

%% A set steps to W over every page and excess, below the floor too, clears the excess
%% and leaves the sample attributes as they were.
the_set_test_() ->
    [fun() ->
             Record = (record(Excess))#{offset_ns := 3, source := ?OTHER},
             {step, Step, Record1} = erx_clock_core:decide({set, W}, ?SOURCE, page(Cold), Record),
             ?assertEqual(#{offset => W, step_ns => W - ?C, at => ?M + W, source => ?SOURCE}, Step),
             ?assertEqual(Record#{excess := none}, Record1)
     end || Cold <- [true, false], Excess <- [none, positive, negative],
            W <- [0, ?FLOOR - ?M - 1, ?C, ?C + 1, ?C + 2000 * ?S, 4611686018427387903]].

%% A set clears a held excess, so the next sample of the same sign holds again instead
%% of stepping on it.
a_set_clears_the_excess_test() ->
    {answer, {ok, held}, Held} = erx_clock_core:decide(sample(?C + 200 * ?MS), ?SOURCE, page(false), record(none)),
    {step, _Step, Set} = erx_clock_core:decide({set, ?C}, ?SOURCE, page(false), Held),
    ?assertMatch({answer, {ok, held}, _}, erx_clock_core:decide(sample(?C + 200 * ?MS), ?SOURCE, page(false), Set)).

%% An applied step is recorded with its source and counted; a refused one is the last
%% step error and leaves the step attributes and the count alone.
applied_test() ->
    Record = record(none),
    {step, Step, Record1} = erx_clock_core:decide({set, ?C + 60 * ?S}, ?SOURCE, page(true), Record),
    {Answer, Applied} = erx_clock_core:applied(ok, Step, Record1),
    ?assertEqual({ok, {stepped, 60 * ?S}}, Answer),
    ?assertEqual(Record1#{step_at := ?M + ?C + 60 * ?S, step_ns := 60 * ?S, step_source := ?SOURCE, steps := 1},
                 Applied),
    {_, Twice} = erx_clock_core:applied(ok, Step, Applied),
    ?assertMatch(#{steps := 2}, Twice),
    [?assertEqual({{error, Status}, Applied#{step_error := Status}}, erx_clock_core:applied({error, Status}, Step, Applied))
     || Status <- [badarg, limit, unsupported]].

%% A new record has nothing sampled or stepped and counts from its start, in seconds.
new_test() ->
    ?assertEqual(#{floor => ?FLOOR, record_since => 5, excess => none, sample_at => none, offset_ns => none, distance_ns => none,
                   stratum => none, server => none, source => none, step_at => none, step_ns => none,
                   step_source => none, step_error => none, steps => 0, refused => 0},
                 erx_clock_core:new(?M + 1, ?FLOOR)).

%% The floor is the build facts' date in nanoseconds, and 0 where the build did not
%% record it or has no facts.
floor_test() ->
    Facts = #{revision => <<"abc">>, date => 1794787200, configuration => unknown, kernel => unknown},
    ?assertEqual(?FLOOR, erx_clock_core:build_floor({ok, Facts})),
    ?assertEqual(0, erx_clock_core:build_floor({ok, Facts#{date := unknown}})),
    ?assertEqual(0, erx_clock_core:build_floor({error, {no_facts, "none"}})).

%% The state of each page: the boot's two, the start's at the floor, and any other
%% change; with no floor recorded, no page is approximate.
state_test() ->
    ?assertEqual(unset, erx_clock_core:state(#{offset => 0, cold => true, monotonic => ?M}, ?FLOOR)),
    ?assertEqual(boot, erx_clock_core:state(#{offset => ?C, cold => true, monotonic => ?M}, ?FLOOR)),
    ?assertEqual(boot, erx_clock_core:state(#{offset => ?FLOOR, cold => true, monotonic => ?M}, ?FLOOR)),
    ?assertEqual(approximate, erx_clock_core:state(#{offset => ?FLOOR, cold => false, monotonic => ?M}, ?FLOOR)),
    [?assertEqual(set, erx_clock_core:state(#{offset => C, cold => false, monotonic => ?M}, ?FLOOR))
     || C <- [0, ?FLOOR - 1, ?FLOOR + 1, ?C]],
    ?assertEqual(set, erx_clock_core:state(#{offset => 0, cold => false, monotonic => ?M}, 0)).

%% The service starts a clock the boot left before the floor at the floor, whether the
%% boot left it at 1970 or at a real-time clock's earlier reading; it leaves a clock
%% at or past the floor, one changed this boot (set below the floor by hand, or already
%% approximate, as a restarted service finds it), and every clock when no floor is
%% recorded. The start never moves a clock backward.
start_test() ->
    Page = fun(Cold, C) -> #{offset => C, cold => Cold, monotonic => ?M} end,
    ?assertEqual({step, ?FLOOR}, erx_clock_core:start(Page(true, 0), ?FLOOR)),
    ?assertEqual({step, ?FLOOR}, erx_clock_core:start(Page(true, ?FLOOR - ?M - 1), ?FLOOR)),
    [?assertEqual(none, erx_clock_core:start(Page(true, C), ?FLOOR)) || C <- [?FLOOR - ?M, ?C]],
    [?assertEqual(none, erx_clock_core:start(Page(false, C), ?FLOOR)) || C <- [0, ?FLOOR, ?C]],
    ?assertEqual(none, erx_clock_core:start(Page(true, 0), 0)).

%% An approximate clock meets a sample as a cold one does: one 56 years or one 2000 s
%% from it steps, where a clock set this boot refuses it as panic; one before the floor
%% is still refused.
an_approximate_clock_is_cold_test() ->
    Approximate = #{offset => ?FLOOR, cold => false, monotonic => ?M},
    [?assertMatch({step, #{offset := W}, _},
                  erx_clock_core:decide(sample(W), ?SOURCE, Approximate, record(none)))
     || W <- [?FLOOR + 2000 * ?S, ?FLOOR + 56 * 365 * 86400 * ?S]],
    ?assertMatch({answer, {ok, {refused, panic}}, _},
                 erx_clock_core:decide(sample(?FLOOR + 2000 * ?S), ?SOURCE, Approximate#{offset := ?FLOOR + 1},
                                       record(none))),
    ?assertMatch({answer, {ok, {refused, floor}}, _},
                 erx_clock_core:decide(sample(?FLOOR - ?M - 1), ?SOURCE, Approximate, record(none))).

%% The floor is the record's, as the service started with it: a later floor refuses a
%% sample an earlier one admits.
the_floor_is_the_records_test() ->
    Page = #{offset => 0, cold => true, monotonic => ?M},
    W = ?FLOOR + 60 * ?S,
    ?assertMatch({step, _, _}, erx_clock_core:decide(sample(W), ?SOURCE, Page, erx_clock_core:new(?M, ?FLOOR))),
    ?assertMatch({answer, {ok, {refused, floor}}, _},
                 erx_clock_core:decide(sample(W), ?SOURCE, Page, erx_clock_core:new(?M, ?FLOOR + 3600 * ?S))).
