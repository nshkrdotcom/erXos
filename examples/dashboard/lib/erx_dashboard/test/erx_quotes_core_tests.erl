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
%% A wall-clock second on a 15 min boundary: 2026-11-17 01:30 UTC.
-define(WALL, 1794879000).

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
                     {S1, _} = outcome(S, q, {value, float(Price), none, ?WALL}, Now),
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
    {S2, A2} = outcome(S1, q, {value, 2.5, none, ?WALL}, ?T0 + 200),
    ?assertEqual([render], A2),
    ?assertMatch(#{value := {2.5, none, b, ?T0 + 200}, failure := none, next_at := ?T0 + 10200},
                 quote(q, S2)),
    ?assertEqual(<<"delayed \x{B7} live chart"/utf8>>, status(S2, <<"q">>, ?T0 + 1200)),
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
    {S2, _} = outcome(S1, q, {value, 1.0, none, ?WALL}, ?T0),
    Asked = asked(S2, q, ?T0 + 10000, ?T0 + Hour - 1),
    ?assertEqual([b], lists:usort(Asked)),
    ?assert(length(Asked) > 300),
    {_S3, A3} = erx_quotes_core:tick(advance(S2, q, ?T0 + Hour), ?T0 + Hour, 1.0),
    ?assertEqual([{q, a}], fetches(A3)),
    %% While held, the source's reason stands for it in the round.
    {S4, _} = outcome(S2, r, {value, 7.0, none, ?WALL}, ?T0),
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
            {S2, _} = outcome(S1, Quote, {value, 1.0, none, ?WALL}, From),
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
    {S4, _} = outcome(S3, q, {value, 1.0, none, ?WALL}, ?T0 + 20000),
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
    {S1, _} = outcome(S0, q, {value, 64412.5, 0.5, ?WALL}, ?T0),
    ?assertEqual(<<"live chart">>, status(S1, <<"q">>, ?T0 + 30000)),
    ?assertEqual(<<"stale, 30 s \x{B7} live chart"/utf8>>, status(S1, <<"q">>, ?T0 + 30001)),
    {S2, _} = erx_quotes_core:tick(S1, ?T0 + 10000, 1.0),
    {S3, _} = outcome(S2, q, {error, {status, 503}, none}, ?T0 + 10000),
    {S4, _} = outcome(S3, q, {error, timeout, none}, ?T0 + 10000),
    ?assertEqual(<<"live chart \x{B7} HTTP 503"/utf8>>, status(S4, <<"q">>, ?T0 + 15000)),
    ?assertEqual(<<"stale, 2 min \x{B7} live chart \x{B7} HTTP 503"/utf8>>, status(S4, <<"q">>, ?T0 + 120000)),
    ?assertMatch([#{symbol := <<"q">>, price := 64412.5, change := 0.5, decimals := 2} | _],
                 quotes(S4, ?T0 + 15000)),
    {S5, _} = outcome(S0, r, {error, {status, 503}, none}, ?T0),
    {S6, _} = outcome(S5, r, {error, connect, none}, ?T0),
    ?assertEqual(<<"no data: HTTP 503">>, status(S6, <<"r">>, ?T0)),
    ?assertMatch([_, #{price := none, change := none}], quotes(S6, ?T0)).

%% The board credits every source of the table once, in the order the
%% quotes ask them, so the status lines need not. Seeded failure: a
%% credit fixed in the view, not taken from the table, fails the first
%% assertion.
credit_test() ->
    {S0, _} = start(),
    ?assertEqual(<<"A, B, C">>, maps:get(credit, erx_quotes_view:board(S0, ?T0))).

%% The kiosk's own table: a fresh quote's line says what its change is
%% measured from and what its graph spans, and a stale one leads with its
%% age; the board credits Kraken. Seeded failure: a line that still
%% names the credit fails the second assertion.
kiosk_lines_test() ->
    {S0, _} = erx_quotes_core:tick(erx_quotes_core:new(erx_quotes_table:table(), ?T0), ?T0, 1.0),
    {S1, _} = outcome(S0, btc, {value, 64412.5, 0.5, ?WALL}, ?T0),
    {S2, _} = erx_quotes_core:history(S1, btc, on_buckets([64000.0], ?WALL)),
    ?assertEqual(<<"Kraken">>, maps:get(credit, erx_quotes_view:board(S2, ?T0))),
    ?assertEqual(<<"since 00:00 UTC \x{B7} 24 h chart"/utf8>>, status(S2, <<"btc">>, ?T0 + 30000)),
    ?assertEqual(<<"stale, 3 min \x{B7} since 00:00 UTC \x{B7} 24 h chart"/utf8>>,
                 status(S2, <<"btc">>, ?T0 + 180000)).

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
    {S1, _} = outcome(S0, q, {value, 64412.5, 0.5, ?WALL}, ?T0),
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
    {S7, _} = outcome(S0, r, {value, 5000.25, none, ?WALL}, ?T0),
    ?assertMatch([_, {r, <<"r fresh 5,000 b">>}], erx_quotes_view:lines(S7, ?T0)).

clock_unset_test() ->
    {S0, _} = start(),
    {S1, _} = outcome(S0, q, {error, clock_unset, none}, ?T0),
    {S2, _} = outcome(S1, q, {error, clock_unset, none}, ?T0),
    ?assertEqual(<<"no data: clock not set">>, status(S2, <<"q">>, ?T0)).

%% Over generated event sequences, every price the board shows is the
%% price of some successful outcome for that quote, whose source the
%% board credits, and is stale, with the age Now minus that outcome's
%% time, exactly when it is older than three periods. Seeded failure: keeping
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
        1 -> {value, float(rand:uniform(100000)), none, ?WALL};
        2 -> {error, timeout, none};
        3 -> {error, {status, 429}, rand:uniform(60000)}
    end.

record(Seen, Quote, Source, {value, Price, _Change, _Wall}, Now) ->
    Seen#{Quote => [{Price, Source, Now} | maps:get(Quote, Seen, [])]};
record(Seen, _Quote, _Source, _Error, _Now) ->
    Seen.

check(State, Now, Seen) ->
    #{table := #{quotes := Rows, sources := Sources}} = State,
    #{credit := Credits, quotes := Quotes} = erx_quotes_view:board(State, Now),
    [case Q of
         #{price := none} -> ok;
         #{symbol := Symbol, price := Price, status := Status} ->
             Quote = binary_to_atom(Symbol),
             Matching = [{Source, At} || {P, Source, At} <- maps:get(Quote, Seen, []), P =:= Price],
             ?assertNotEqual([], Matching),
             [{Source, At} | _] = Matching,
             #{credit := Credit} = maps:get(Source, Sources),
             ?assertNotEqual(nomatch, binary:match(Credits, Credit)),
             #{period := Period} = proplists:get_value(Quote, Rows),
             check_age(Status, Now - At, Period)
     end || Q <- Quotes].

%% A line leads with the value's age once it is older than three periods,
%% and says nothing of it before.
check_age(Status, Age, Period) when Age > 3 * Period ->
    Stale = <<"stale, ", (erx_quotes_view:age(Age))/binary, " ">>,
    ?assertMatch(<<Stale:(byte_size(Stale))/binary, _/binary>>, Status);
check_age(Status, _Age, _Period) ->
    ?assertNotMatch(<<"stale", _/binary>>, Status).

%% History

-define(B, 900).

%% One quote over one source that names a history.
history_table() ->
    #{quotes => [{h, #{label => <<"H">>, decimals => 2, period => 10000, sources => [k]}}],
      sources => #{k => #{url => <<"https://k.test/ticker">>, address => {127, 0, 0, 1},
                          format => json, price => [<<"p">>], change => none,
                          credit => <<"K">>, note => <<>>,
                          history => #{url => <<"https://k.test/ohlc?interval=15">>,
                                       entries => [<<"result">>, <<"K">>]}}}}.

history_start() ->
    erx_quotes_core:tick(erx_quotes_core:new(history_table(), ?T0), ?T0, 1.0).

histories(Actions) ->
    [{Quote, Source} || {history, Quote, Source} <- Actions].

series(State) ->
    maps:get(series, quote(h, State)).

%% `Closes` on consecutive buckets, the last at the wall second `Last`.
on_buckets(Closes, Last) ->
    N = length(Closes),
    lists:zip([Last - (N - I) * ?B || I <- lists:seq(1, N)], Closes).

%% A live price `Price` for `h` read at the wall second `Wall`: a round
%% started at the monotonic `Now` and answered with it.
live(State, Price, Wall, Now) ->
    {S1, _} = erx_quotes_core:tick(State, Now, 1.0),
    {S2, _} = outcome(S1, h, {value, Price, none, Wall}, Now),
    S2.

%% A quote whose source names a history asks for it at start and then
%% once an hour, answered or not; a table without one asks for none.
%% Seeded failure: scheduling the next request from an answer never asks
%% again after one that failed.
history_hourly_test() ->
    {S0, A0} = history_start(),
    ?assertEqual([{h, k}], histories(A0)),
    {S1, A1} = erx_quotes_core:tick(S0, ?T0 + 3599000, 1.0),
    ?assertEqual([], histories(A1)),
    {_S2, A2} = erx_quotes_core:tick(S1, ?T0 + 3600000, 1.0),
    ?assertEqual([{h, k}], histories(A2)),
    {_, Plain} = start(),
    ?assertEqual([], histories(Plain)).

%% A history asks its source as a round does (Q-R4): it waits while a
%% round's Retry-After holds the source back, and one answered with a
%% Retry-After holds the source back from the rounds. Seeded failure:
%% asking for a history without looking at the source's hold asks for it
%% at the hour.
history_held_back_test() ->
    {S0, _} = history_start(),
    {S1, _} = outcome(S0, h, {error, {status, 429}, 3600000}, ?T0 + 1000),
    {S2, A2} = erx_quotes_core:tick(S1, ?T0 + 3600000, 1.0),
    ?assertEqual([], histories(A2)),
    %% A shorter Retry-After never ends the longer hold.
    {S2b, []} = erx_quotes_core:history_failed(S2, h, {status, 503}, 1000, ?T0 + 3599000),
    {_, A2b} = erx_quotes_core:tick(S2b, ?T0 + 3600999, 1.0),
    ?assertEqual([], histories(A2b)),
    {_S3, A3} = erx_quotes_core:tick(S2, ?T0 + 3601000, 1.0),
    ?assertEqual([{h, k}], histories(A3)),
    {H0, _} = history_start(),
    {H1, _} = outcome(H0, h, {value, 1.0, none, ?WALL}, ?T0),
    {H2, []} = erx_quotes_core:history_failed(H1, h, {status, 429}, 60000, ?T0),
    {H3, A4} = erx_quotes_core:tick(H2, ?T0 + 10000, 1.0),
    ?assertEqual([], fetches(A4)),
    ?assertMatch(#{failure := {{status, 429}, _}}, quote(h, H3)),
    {_H4, A5} = erx_quotes_core:tick(H3, ?T0 + 60000, 1.0),
    ?assertEqual([{h, k}], fetches(A5)),
    %% A failure without one changes nothing.
    ?assertEqual({H1, []}, erx_quotes_core:history_failed(H1, h, timeout, none, ?T0)).

%% The request asks for the day before the clock from the start of its
%% bucket, as docs/design-quotes.md, "Asking for a history", writes it.
history_url_test() ->
    #{sources := #{kraken_btc := Btc}} = erx_quotes_table:table(),
    ?assertEqual(<<"https://api.kraken.com/0/public/OHLC?pair=XBTUSD&interval=15&since=1794792600">>,
                 erx_quotes_core:history_url(Btc, ?WALL + 899)),
    ?assertEqual(?WALL - 86400, 1794792600).

%% Seeded failures: appending a later bucket without the skipped ones
%% fails the third case; appending an earlier one fails the fourth.
join_test() ->
    {S0, _} = history_start(),
    {S1, R1} = erx_quotes_core:history(S0, h, on_buckets([1.0, 2.0, 3.0], ?WALL)),
    ?assertEqual([render], R1),
    ?assertEqual(on_buckets([1.0, 2.0, 3.0], ?WALL), series(S1)),
    %% A price in the series' last bucket replaces its close.
    S2 = live(S1, 4.0, ?WALL + ?B - 1, ?T0),
    ?assertEqual(on_buckets([1.0, 2.0, 4.0], ?WALL), series(S2)),
    %% One in the next bucket appends a point.
    S3 = live(S2, 5.0, ?WALL + ?B, ?T0 + 10000),
    ?assertEqual(on_buckets([1.0, 2.0, 4.0, 5.0], ?WALL + ?B), series(S3)),
    %% Past skipped buckets, each skipped one repeats the last close.
    S4 = live(S3, 6.0, ?WALL + 4 * ?B + 1, ?T0 + 20000),
    ?assertEqual(on_buckets([1.0, 2.0, 4.0, 5.0, 5.0, 5.0, 6.0], ?WALL + 4 * ?B), series(S4)),
    %% A price of an earlier bucket, as from a clock behind the source's,
    %% replaces the last close: the series keeps the source's times.
    S5 = live(S4, 0.5, ?WALL + 2 * ?B, ?T0 + 30000),
    ?assertEqual(on_buckets([1.0, 2.0, 4.0, 5.0, 5.0, 5.0, 0.5], ?WALL + 4 * ?B), series(S5)),
    %% The next answer replaces the series whole, its own gaps filled.
    {S6, _} = erx_quotes_core:history(S5, h, [{?WALL - 2 * ?B, 9.0}, {?WALL, 8.0}]),
    ?assertEqual(on_buckets([9.0, 9.0, 8.0], ?WALL), series(S6)).

%% A kiosk whose wall clock lags the source's by a day: the history,
%% whose entries all lie after the clock, is drawn as `24 h`, and each
%% live price, read in a bucket before the series' last, moves the last
%% close, so the line ends at the live price. Seeded failure: leaving
%% out a price of an earlier bucket keeps the history's last close.
lagging_clock_test() ->
    {S0, _} = history_start(),
    Day = on_buckets([float(N) || N <- lists:seq(1, 96)], ?WALL + 86400),
    {S1, _} = erx_quotes_core:history(S0, h, Day),
    S2 = live(S1, 7.5, ?WALL, ?T0),
    ?assertEqual(lists:droplast(Day) ++ [{?WALL + 86400, 7.5}], series(S2)),
    ?assertMatch([#{status := <<"24 h chart">>}], quotes(S2, ?T0)),
    S3 = live(S2, 8.5, ?WALL + ?B, ?T0 + 10000),
    ?assertEqual(lists:droplast(Day) ++ [{?WALL + 86400, 8.5}], series(S3)).

%% The series keeps the last erx_quotes_core:buckets() points, a day of
%% 15 min buckets, and a history's own gaps are filled whatever their
%% length. Seeded failure: dropping the trim of a join keeps all 97
%% entries of the day.
trim_test() ->
    Max = erx_quotes_core:buckets(),
    ?assertEqual(96, Max),
    ?assertEqual(900, erx_quotes_core:bucket()),
    {S0, _} = history_start(),
    Day = on_buckets([float(N) || N <- lists:seq(0, Max)], ?WALL),
    {S1, _} = erx_quotes_core:history(S0, h, Day),
    ?assertEqual(tl(Day), series(S1)),
    S2 = live(S1, 7.0, ?WALL + ?B, ?T0),
    ?assertEqual(tl(tl(Day)) ++ [{?WALL + ?B, 7.0}], series(S2)),
    %% A history's own gaps are filled whatever their length.
    {S3, _} = erx_quotes_core:history(S2, h, [{?WALL - 10 * ?B, 9.0}, {?WALL, 8.0}]),
    ?assertEqual(on_buckets(lists:duplicate(10, 9.0) ++ [8.0], ?WALL), series(S3)).

%% A gap on our side of up to 4 buckets, an hour, repeats the last close
%% and keeps `24 h`; a longer one drops the series back to `live` until
%% the next history, so no hour the source did not give is drawn as
%% flat. Seeded failure: filling every gap shows `24 h` across five
%% invented buckets.
gap_test() ->
    {S0, _} = history_start(),
    {S1, _} = erx_quotes_core:history(S0, h, on_buckets([1.0, 2.0], ?WALL)),
    S2 = live(S1, 3.0, ?WALL + 5 * ?B, ?T0),
    ?assertEqual(on_buckets([1.0, 2.0, 2.0, 2.0, 2.0, 2.0, 3.0], ?WALL + 5 * ?B), series(S2)),
    ?assertMatch([#{status := <<"24 h chart">>}], quotes(S2, ?T0)),
    S3 = live(S2, 4.0, ?WALL + 11 * ?B, ?T0 + 10000),
    ?assertEqual(none, series(S3)),
    ?assertMatch([#{status := <<"live chart">>}], quotes(S3, ?T0 + 10000)),
    S4 = live(S3, 5.0, ?WALL + 12 * ?B, ?T0 + 20000),
    ?assertEqual(none, series(S4)),
    {S5, _} = erx_quotes_core:history(S4, h, on_buckets([6.0], ?WALL + 12 * ?B)),
    ?assertMatch([#{status := <<"24 h chart">>}], quotes(S5, ?T0 + 20000)).

%% Without a history the card's graph is its live samples and its status
%% says `live`; with one, the graph is the series' closes and the status
%% says `24 h`. A quote of a table without history keeps no series.
%% Seeded failure: a series started from a live price shows `24 h`
%% before any history arrived.
fallback_test() ->
    {S0, _} = history_start(),
    S1 = live(S0, 3.0, ?WALL, ?T0),
    ?assertEqual(none, series(S1)),
    ?assertMatch([#{samples := [3.0], status := <<"live chart">>}], quotes(S1, ?T0)),
    {S2, _} = erx_quotes_core:history(S1, h, on_buckets([1.0, 2.0], ?WALL)),
    ?assertMatch([#{samples := [1.0, 2.0], status := <<"24 h chart">>}], quotes(S2, ?T0)),
    S3 = live(S2, 4.0, ?WALL + ?B, ?T0 + 10000),
    ?assertMatch([#{samples := [1.0, 2.0, 4.0]}], quotes(S3, ?T0 + 10000)),
    {S4, _} = outcome(element(1, start()), q, {value, 1.0, none, ?WALL}, ?T0),
    ?assertEqual(none, maps:get(series, quote(q, S4))).
