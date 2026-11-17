%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_core_tests).
-moduledoc """
EUnit cases of the live quotes' core and view (docs/design-quotes.md,
"Verification and testing"): rounds, held-back sources, backoff,
staleness and ages, and the no-fabrication property over generated
event sequences. Each case names the seeded failure it catches.
""".

-include_lib("eunit/include/eunit.hrl").

-define(T0, -5000000).   % monotonic time may be negative

%% Two quotes over two sources each; `b` is shared, so a hold on it holds
%% it back for both.
table() ->
    Source = fun(Credit, Note) ->
                     #{url => <<"https://", Credit/binary, ".test/q">>, address => {127, 0, 0, 1},
                       format => json, price => [<<"p">>], change => none, credit => Credit,
                       note => Note}
             end,
    #{quotes => [{q, #{label => <<"Q">>, decimals => 2, period => 10000, sources => [a, b]}},
                 {r, #{label => <<"R">>, decimals => 0, period => 60000, sources => [b, c]}}],
      sources => #{a => Source(<<"A">>, <<>>), b => Source(<<"B">>, <<"delayed">>),
                   c => Source(<<"C">>, <<"daily">>)}}.

start() ->
    erx_quotes_core:tick(erx_quotes_core:new(table(), ?T0), ?T0, 1.0).

fetches(Actions) ->
    [{Quote, Source} || {fetch, Quote, Source, _Url} <- Actions].

quote(Name, #{quotes := Quotes}) ->
    maps:get(Name, Quotes).

outcome(State, Quote, Outcome, Now) ->
    erx_quotes_core:outcome(State, Quote, Outcome, Now, 1.0).

first_tick_test() ->
    {S, Actions} = start(),
    ?assertEqual([{q, a}, {r, b}], fetches(Actions)),
    ?assertEqual(render, lists:last(Actions)),
    ?assertMatch([{fetch, q, a, <<"https://A.test/q">>} | _], Actions),
    %% A round in flight is not started again.
    {_S2, Again} = erx_quotes_core:tick(S, ?T0 + 60000, 1.0),
    ?assertEqual([render], Again).

%% A quote keeps the prices it received, oldest first, the last
%% erx_quotes_core:samples() of them; a failed round adds none, and the
%% board hands them to the view. Seeded failure: a ring that keeps the
%% first prices instead of the last fails the second assertion.
samples_test() ->
    {S0, _} = start(),
    Max = erx_quotes_core:samples(),
    Answer = fun(Price, {S, Now}) ->
                     {S1, _} = outcome(S, q, {value, float(Price), none}, Now),
                     {S2, _} = erx_quotes_core:tick(S1, Now + 10000, 1.0),
                     {S2, Now + 10000}
             end,
    {S3, Now3} = lists:foldl(Answer, {S0, ?T0}, [1, 2, 3]),
    ?assertMatch(#{samples := [1.0, 2.0, 3.0]}, quote(q, S3)),
    {S4, Now4} = lists:foldl(Answer, {S3, Now3}, lists:seq(4, Max + 5)),
    ?assertEqual([float(N) || N <- lists:seq(6, Max + 5)], maps:get(samples, quote(q, S4))),
    {S5, _} = outcome(S4, q, {error, timeout, none}, Now4),
    ?assertEqual(maps:get(samples, quote(q, S4)), maps:get(samples, quote(q, S5))),
    #{quotes := [Q | _]} = erx_quotes_view:board(S5, Now4),
    ?assertEqual(maps:get(samples, quote(q, S5)), maps:get(samples, Q)).

%% Seeded failure: starting the next round at the source that last
%% answered fails the third case.
rounds_test() ->
    {S0, _} = start(),
    {S1, A1} = outcome(S0, q, {error, timeout, none}, ?T0 + 100),
    ?assertEqual([{q, b}], fetches(A1)),
    {S2, A2} = outcome(S1, q, {value, 2.5, none}, ?T0 + 200),
    ?assertEqual([render], A2),
    ?assertMatch(#{value := {2.5, none, b, ?T0 + 200}, failure := none, next_at := ?T0 + 10200},
                 quote(q, S2)),
    ?assertEqual(<<"B, delayed - 1 s">>, status(S2, <<"q">>, ?T0 + 1200)),
    {_S3, A3} = erx_quotes_core:tick(S2, ?T0 + 10200, 1.0),
    ?assertEqual([{q, a}], fetches(A3)),
    {S4, _} = outcome(S0, q, {error, timeout, none}, ?T0 + 100),
    {S5, A5} = outcome(S4, q, {error, {status, 500}, none}, ?T0 + 300),
    ?assertEqual([render], A5),
    ?assertMatch(#{value := none, failure := {timeout, ?T0 + 300}, failed_rounds := 1},
                 quote(q, S5)).

%% Seeded failure: keeping not_before per quote instead of per source asks
%% the first source ten seconds later.
held_back_test() ->
    Hour = 3600000,
    {S0, _} = start(),
    {S1, A1} = outcome(S0, q, {error, {status, 429}, Hour}, ?T0),
    ?assertEqual([{q, b}], fetches(A1)),
    {S2, _} = outcome(S1, q, {value, 1.0, none}, ?T0),
    Asked = asked(S2, q, ?T0 + 10000, ?T0 + Hour - 1),
    ?assertEqual([b], lists:usort(Asked)),
    ?assert(length(Asked) > 300),
    {_S3, A3} = erx_quotes_core:tick(advance(S2, q, ?T0 + Hour), ?T0 + Hour, 1.0),
    ?assertEqual([{q, a}], fetches(A3)),
    %% While held, the source's reason stands for it in the round.
    {S4, _} = outcome(S2, r, {value, 7.0, none}, ?T0),
    {S5, A5} = erx_quotes_core:tick(S4, ?T0 + 60000, 1.0),
    ?assertEqual([{q, b}, {r, b}], fetches(A5)),
    {S6, _} = outcome(S5, r, {error, {status, 503}, 2 * Hour}, ?T0 + 60000),
    {S7, A7} = outcome(S6, r, {error, timeout, none}, ?T0 + 60000),
    ?assertEqual([render], A7),
    ?assertMatch(#{failure := {{status, 503}, _}}, quote(r, S7)),
    %% q's both sources held back: no request until the earlier not_before.
    {S8, A8} = outcome(S7, q, {error, timeout, none}, ?T0 + 60000),
    ?assertEqual([render], A8),
    #{next_at := NextAt, failure := {{status, 429}, _}} = quote(q, S8),
    ?assertEqual(?T0 + Hour, NextAt).

%% Every request the core makes for `Quote` from `From` to `To`, answering
%% each with a value at once, a tick every second.
asked(_State, _Quote, From, To) when From > To ->
    [];
asked(State, Quote, From, To) ->
    {S1, Actions} = erx_quotes_core:tick(State, From, 1.0),
    case [Source || {Q, Source} <- fetches(Actions), Q =:= Quote] of
        [] -> asked(S1, Quote, From + 1000, To);
        [Source] ->
            {S2, _} = outcome(S1, Quote, {value, 1.0, none}, From),
            [Source | asked(S2, Quote, From + 1000, To)]
    end.

advance(State, Quote, Now) ->
    #{quotes := Quotes} = State,
    State#{quotes := Quotes#{Quote := (maps:get(Quote, Quotes))#{next_at := Now}}}.

%% Seeded failure: dropping the cap gives 2,560,000 at the eighth round.
backoff_test() ->
    Waits = fun(Quote) ->
                    {S0, _} = start(),
                    fail_rounds(S0, Quote, 8, ?T0)
            end,
    ?assertEqual([20000, 40000, 80000, 160000, 320000, 640000, 900000, 900000], Waits(q)),
    ?assertEqual([120000, 240000, 480000, 900000, 900000, 900000, 900000, 900000], Waits(r)),
    {S0, _} = start(),
    {S1, _} = outcome(S0, q, {error, timeout, none}, ?T0),
    {S2, _} = outcome(S1, q, {error, timeout, none}, ?T0),
    {S3, _} = erx_quotes_core:tick(S2, ?T0 + 20000, 1.0),
    {S4, _} = outcome(S3, q, {value, 1.0, none}, ?T0 + 20000),
    ?assertMatch(#{failed_rounds := 0, next_at := ?T0 + 30000}, quote(q, S4)),
    {S5, _} = erx_quotes_core:outcome(S1, q, {error, timeout, none}, ?T0, 0.8),
    ?assertMatch(#{next_at := ?T0 + 16000}, quote(q, S5)).

%% The wait after each of `N` failed rounds of `Quote`, every source
%% failing at once.
fail_rounds(_State, _Quote, 0, _Now) ->
    [];
fail_rounds(State, Quote, N, Now) ->
    {S1, _} = erx_quotes_core:tick(State, Now, 1.0),
    {S2, _} = outcome(S1, Quote, {error, timeout, none}, Now),
    {S3, _} = outcome(S2, Quote, {error, timeout, none}, Now),
    #{next_at := NextAt} = quote(Quote, S3),
    [NextAt - Now | fail_rounds(S3, Quote, N - 1, NextAt)].

quotes(State, Now) ->
    maps:get(quotes, erx_quotes_view:board(State, Now)).

status(State, Symbol, Now) ->
    [Status] = [S || #{symbol := Sym, status := S} <- quotes(State, Now), Sym =:= Symbol],
    Status.

%% Seeded failure: comparing `>=` instead of `>` shows the value stale at
%% exactly 3 * period.
staleness_test() ->
    {S0, _} = start(),
    ?assertEqual(<<"waiting">>, status(S0, <<"q">>, ?T0)),
    {S1, _} = outcome(S0, q, {value, 64412.5, 0.5}, ?T0),
    ?assertEqual(<<"A - 30 s">>, status(S1, <<"q">>, ?T0 + 30000)),
    ?assertEqual(<<"stale, 30 s - A">>, status(S1, <<"q">>, ?T0 + 30001)),
    {S2, _} = erx_quotes_core:tick(S1, ?T0 + 10000, 1.0),
    {S3, _} = outcome(S2, q, {error, {status, 503}, none}, ?T0 + 10000),
    {S4, _} = outcome(S3, q, {error, timeout, none}, ?T0 + 10000),
    ?assertEqual(<<"A - 15 s: HTTP 503">>, status(S4, <<"q">>, ?T0 + 15000)),
    ?assertEqual(<<"stale, 2 min - A: HTTP 503">>, status(S4, <<"q">>, ?T0 + 120000)),
    ?assertMatch([#{symbol := <<"q">>, price := 64412.5, change := 0.5, decimals := 2} | _],
                 quotes(S4, ?T0 + 15000)),
    {S5, _} = outcome(S0, r, {error, {status, 503}, none}, ?T0),
    {S6, _} = outcome(S5, r, {error, connect, none}, ?T0),
    ?assertEqual(<<"no data: HTTP 503">>, status(S6, <<"r">>, ?T0)),
    ?assertMatch([_, #{price := none, change := none}], quotes(S6, ?T0)).

ages_test() ->
    Cases = [{119000, <<"119 s">>}, {120000, <<"2 min">>}, {7199000, <<"119 min">>},
             {7200000, <<"2 h">>}, {172799000, <<"47 h">>}, {172800000, <<"2 d">>},
             {999, <<"0 s">>}, {-5, <<"0 s">>}],
    [?assertEqual(Text, erx_quotes_view:age(Ms)) || {Ms, Text} <- Cases].

%% The log lines the QEMU cell reads, one per quote. Seeded failure:
%% naming the source rather than the reason of a failed round turns the
%% stale line's `{status,503}` into `a`.
lines_test() ->
    {S0, _} = start(),
    ?assertEqual([{q, <<"q waiting -- none">>}, {r, <<"r waiting -- none">>}],
                 erx_quotes_view:lines(S0, ?T0)),
    {S1, _} = outcome(S0, q, {value, 64412.5, 0.5}, ?T0),
    ?assertMatch([{q, <<"q fresh 64,412.50 a">>} | _], erx_quotes_view:lines(S1, ?T0 + 30000)),
    ?assertMatch([{q, <<"q stale 64,412.50 a">>} | _], erx_quotes_view:lines(S1, ?T0 + 30001)),
    {S2, _} = erx_quotes_core:tick(S1, ?T0 + 10000, 1.0),
    {S3, _} = outcome(S2, q, {error, {status, 503}, none}, ?T0 + 10000),
    {S4, _} = outcome(S3, q, {error, timeout, none}, ?T0 + 10000),
    ?assertMatch([{q, <<"q fresh 64,412.50 {status,503}">>} | _],
                 erx_quotes_view:lines(S4, ?T0 + 15000)),
    ?assertMatch([{q, <<"q stale 64,412.50 {status,503}">>} | _],
                 erx_quotes_view:lines(S4, ?T0 + 120000)),
    {S5, _} = outcome(S0, r, {error, clock_unset, none}, ?T0),
    {S6, _} = outcome(S5, r, {error, clock_unset, none}, ?T0),
    ?assertMatch([_, {r, <<"r no_data -- clock_unset">>}], erx_quotes_view:lines(S6, ?T0)),
    {S7, _} = outcome(S0, r, {value, 5000.25, none}, ?T0),
    ?assertMatch([_, {r, <<"r fresh 5,000 b">>}], erx_quotes_view:lines(S7, ?T0)).

clock_unset_test() ->
    {S0, _} = start(),
    {S1, _} = outcome(S0, q, {error, clock_unset, none}, ?T0),
    {S2, _} = outcome(S1, q, {error, clock_unset, none}, ?T0),
    ?assertEqual(<<"no data: clock not set">>, status(S2, <<"q">>, ?T0)).

%% Over generated event sequences, every price the board shows is the
%% price of some successful outcome for that quote, with that outcome's
%% credit and an age equal to Now minus its time. Seeded failure: keeping
%% the previous price on a failed round with a new FetchedAt breaks the
%% age property.
no_fabrication_test() ->
    rand:seed(exsss, {1, 2, 3}),
    [run_sequence() || _ <- lists:seq(1, 200)].

run_sequence() ->
    {S0, A0} = start(),
    step(S0, A0, ?T0, #{}, 60).

step(_State, _Actions, _Now, _Seen, 0) ->
    ok;
step(State, Actions, Now, Seen, N) ->
    Now1 = Now + rand:uniform(20000),
    {S1, A1, Seen1} =
        case fetches(Actions) of
            [] ->
                {S, A} = erx_quotes_core:tick(State, Now1, 0.8 + 0.4 * rand:uniform()),
                {S, A, Seen};
            [{Quote, Source} | _] ->
                Outcome = random_outcome(),
                {S, A} = erx_quotes_core:outcome(State, Quote, Outcome, Now1, 1.0),
                {S, A ++ tl_fetches(Actions), record(Seen, Quote, Source, Outcome, Now1)}
        end,
    check(S1, Now1, Seen1),
    step(S1, A1, Now1, Seen1, N - 1).

tl_fetches(Actions) ->
    tl([A || {fetch, _, _, _} = A <- Actions]).

random_outcome() ->
    case rand:uniform(3) of
        1 -> {value, float(rand:uniform(100000)), none};
        2 -> {error, timeout, none};
        3 -> {error, {status, 429}, rand:uniform(60000)}
    end.

record(Seen, Quote, Source, {value, Price, _Change}, Now) ->
    Seen#{Quote => [{Price, Source, Now} | maps:get(Quote, Seen, [])]};
record(Seen, _Quote, _Source, _Error, _Now) ->
    Seen.

check(State, Now, Seen) ->
    #{table := #{sources := Sources}} = State,
    [case Q of
         #{price := none} -> ok;
         #{symbol := Symbol, price := Price, status := Status} ->
             Quote = binary_to_atom(Symbol),
             Matching = [{Source, At} || {P, Source, At} <- maps:get(Quote, Seen, []), P =:= Price],
             ?assertNotEqual([], Matching),
             [{Source, At} | _] = Matching,
             #{credit := Credit} = maps:get(Source, Sources),
             ?assertNotEqual(nomatch, binary:match(Status, Credit)),
             ?assertNotEqual(nomatch, binary:match(Status, erx_quotes_view:age(Now - At)))
     end || Q <- quotes(State, Now)].
