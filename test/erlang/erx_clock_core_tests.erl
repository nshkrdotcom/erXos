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
%% The core's floor, 2026-11-16 00:00:00 UTC, and a page offset well above it.
-define(FLOOR, (1794787200 * ?S)).
-define(C, (?FLOOR + 86400 * ?S)).
-define(M, (5 * ?S)).

page(Cold) -> #{offset => ?C, cold => Cold, monotonic => ?M}.

sample(W) -> {sample, W, 20 * ?MS, 2, {192, 0, 2, 1}}.

record(Excess) -> (erx_clock_core:new(?M))#{excess := Excess}.

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
                 erx_clock_core:decide(sample(?C + 2000 * ?S), ?SOURCE, page(false), erx_clock_core:new(0))).

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
    ?assertEqual(#{record_since => 5, excess => none, sample_at => none, offset_ns => none, distance_ns => none,
                   stratum => none, server => none, source => none, step_at => none, step_ns => none,
                   step_source => none, step_error => none, steps => 0, refused => 0},
                 erx_clock_core:new(?M + 1)).
