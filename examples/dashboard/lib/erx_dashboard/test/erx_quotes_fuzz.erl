%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_fuzz).
-moduledoc """
The fuzz target of the live quotes' readers of untrusted input
(docs/design-quotes.md, "The fuzz target"), run by tools/fuzz/erx_quotes.rb:

* erx_quotes_extract:value/2 takes bodies of up to 64 KiB for each source
  of the table (erx_quotes_table): random bytes; generated answers of
  each source's shape with a field mutated, truncated or moved to a
  bound; nesting 10,000 deep; numbers of 400 digits, `e400` and
  `1.0e300`; lines of bare newlines. Nothing raises; every accepted price is a
  float above 0 and below 10^15 and every change none or a float; an
  unmutated answer gives the price it was built with.
* erx_quotes_http:classify/4 takes httpc-shaped results with random
  status codes, header names and byte values, and random error terms.
  Nothing raises, the answer is a class, and a followed URL keeps the
  origin asked.
* erx_quotes_extract:history/3 takes bodies for Bitcoin's history read
  at a clock near a random bucket: random bytes and the hostile bodies
  above; generated days of OHLC entries with a field mutated, truncated
  or moved to a bound. Nothing raises; every accepted list holds 1 to
  200 entries on bucket steps, strictly increasing, within two days of
  the clock, each close a float above 0 and below 10^15; an unmutated
  day gives the entries it was built with. Each accepted list becomes
  Bitcoin's series (erx_quotes_core:history/3) and is joined with live
  prices read at random wall-clock seconds around it: the series stays
  1 to 96 points on bucket steps, strictly increasing, and holds no
  close that was neither an entry's nor a live price.

None of them may make an atom. The seed comes from make check-fuzz.
""".

-export([run/1]).

-define(ROUNDS, 4000).
-define(URL, <<"https://quotes.test/api">>).
%% A wall-clock second on a bucket, 2026-11-17 01:30 UTC, and how far an
%% entry's time may lie from the clock.
-define(WALL, 1794879000).
-define(SKEW, 172800).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Every row of the table computes a change, whose bound alone refuses
    %% most prices past 10^15; `price_only`, Bitcoin's row without its
    %% change, reaches the price's own bound.
    #{sources := #{kraken_btc := Btc} = Table} = Quotes = erx_quotes_table:table(),
    Sources = Table#{price_only => Btc#{change := none}},
    Rounds = fun(N) ->
                     A = length([ok || _ <- lists:seq(1, N), extract_round(Sources) =:= accepted]),
                     H = length([ok || _ <- lists:seq(1, N), history_round(Quotes) =:= accepted]),
                     [http_round() || _ <- lists:seq(1, N)],
                     {A, H}
             end,
    %% A first call of a reader may load modules, which makes atoms, so the
    %% atom table is compared across the rounds after a first quarter: an
    %% input that made atoms would make new ones from the inputs that follow.
    _ = Rounds(?ROUNDS div 4),
    Atoms = erlang:system_info(atom_count),
    {Accepted, Histories} = Rounds(?ROUNDS),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, erlang:system_info(atom_count) - Atoms}),
    io:format("fuzz: ~p rounds ok, ~p bodies accepted, ~p histories accepted~n",
              [?ROUNDS, Accepted, Histories]).

no_raise(Fun, Input) ->
    try Fun() catch Class:Reason:Stack -> error({raised, Class, Reason, Input, Stack}) end.

%% extract

extract_round(Sources) ->
    Name = pick(maps:keys(Sources)),
    Source = maps:get(Name, Sources),
    {Body, Price} = case rand:uniform(4) of
                        1 -> {answer(Name, built), built};
                        2 -> {mutate(answer(Name, built)), any};
                        3 -> {answer(Name, pick(bounds())), any};
                        4 -> {hostile(), any}
                    end,
    case no_raise(fun() -> erx_quotes_extract:value(Source, Body) end, Body) of
        {ok, P, C} when is_float(P), P >= 1.0e-12, P < 1.0e15,
                        (C =:= none orelse (is_float(C) andalso C >= -100 andalso C =< 1000)) ->
            Price =:= any orelse P =:= 12345.5 orelse error({wrong_price, Name, Body, P}),
            accepted;
        {ok, P, C} ->
            error({out_of_bounds, Name, Body, P, C});
        {error, bad_data} ->
            Price =:= any orelse error({refused_built, Name, Body}),
            refused
    end.

%% An answer in `Name`'s shape whose price is `Price`; `built` is 12345.5.
answer(Name, built) ->
    answer(Name, <<"12345.50">>);
answer(Name, Price) ->
    Key = case Name of
              kraken_btc -> <<"XXBTZUSD">>;
              price_only -> <<"XXBTZUSD">>;
              kraken_eth -> <<"XETHZUSD">>;
              kraken_sol -> <<"SOLUSD">>
          end,
    erx_quotes_extract_tests:kraken(Key, Price, <<"12000.0">>).

bounds() ->
    [<<"0">>, <<"-1">>, <<"999999999999999">>, <<"1000000000000000">>,
     <<"0.000000000001">>, <<"1.0000000000001">>, binary:copy(<<"9">>, 33),
     1.0e300, -1.0e300, 0, 0.0, -0.0, 1.0e15, 999999999999999.9, <<".">>, <<>>,
     <<"1e5">>, <<" 1">>, <<"1 ">>, <<"+1">>, <<"0x10">>].

mutate(Body) ->
    case rand:uniform(5) of
        5 -> binary:replace(Body, <<"\"12000.0\"">>, pick([<<"1e-300">>, <<"5e-324">>, <<"1e-12">>,
                                                          <<"1e14">>, <<"0.001">>, <<"-1">>]));
        4 -> binary:replace(Body, <<"12345.50">>, pick([<<"1e400">>, <<"1.0e300">>,
                                                       binary:copy(<<"7">>, 400), <<"[]">>,
                                                       <<"{}">>, <<"null">>, <<"\"\"">>]));
        _ -> mutate_bytes(Body)
    end.

%% `Body` truncated, with a byte changed, or with bytes appended.
mutate_bytes(Body) ->
    case rand:uniform(3) of
        1 -> binary:part(Body, 0, rand:uniform(byte_size(Body)) - 1);
        2 -> flip(Body);
        3 -> <<Body/binary, (random_bytes(rand:uniform(16)))/binary>>
    end.

flip(Body) ->
    At = rand:uniform(byte_size(Body)) - 1,
    <<Before:At/binary, _:8, After/binary>> = Body,
    <<Before/binary, (rand:uniform(256) - 1):8, After/binary>>.

hostile() ->
    case rand:uniform(8) of
        1 -> random_bytes(rand:uniform(65536));
        2 -> iolist_to_binary([lists:duplicate(10000, $[), lists:duplicate(10000, $])]);
        3 -> iolist_to_binary([lists:duplicate(10000, <<"{\"a\":">>), "1",
                               lists:duplicate(10000, $})]);
        4 -> <<"{\"price\": ", (binary:copy(<<"9">>, 400))/binary, "}">>;
        5 -> <<"{\"price\": 1e400}">>;
        6 -> <<"{\"result\": {}}">>;
        7 -> <<"{\"result\": {\"XXBTZUSD\": {\"c\": [], \"o\": \"1\"}}}">>;
        8 -> binary:copy(<<"\n">>, 65536)
    end.

random_bytes(N) ->
    rand:bytes(N).

%% history

history_round(#{sources := #{kraken_btc := Btc}} = Table) ->
    Wall = ?WALL + (rand:uniform(2001) - 1001) * erx_quotes_core:bucket(),
    Day = erx_quotes_extract_tests:day(Wall),
    {Body, Read, Expect} =
        case rand:uniform(4) of
            1 -> {ohlc(Day), Wall + rand:uniform(erx_quotes_core:bucket()) - 1, built};
            2 -> {mutate_history(ohlc(Day)), Wall + rand:uniform(2 * ?SKEW) - ?SKEW, any};
            3 -> {ohlc(moved(Day)), Wall, any};
            4 -> {hostile(), Wall, any}
        end,
    case no_raise(fun() -> erx_quotes_extract:history(Btc, Body, Read) end, Body) of
        {ok, Entries} ->
            entries_ok(Entries, Read) orelse error({bad_entries, Body, Read, Entries}),
            Expect =:= any orelse Entries =:= [{Time, binary_to_float(Close)} || {Time, Close} <- Day]
                orelse error({wrong_entries, Body, Entries}),
            join_round(Table, Entries, Read),
            accepted;
        {error, bad_data} ->
            Expect =:= any orelse error({refused_built, Body}),
            refused
    end.

ohlc(Entries) ->
    erx_quotes_extract_tests:ohlc(<<"XXBTZUSD">>, Entries).

%% A day with one entry's close or time moved to a bound.
moved(Day) ->
    {Before, [{Time, Close} | After]} = lists:split(rand:uniform(length(Day)) - 1, Day),
    Moved = case rand:uniform(2) of
                1 -> {Time, pick(bounds())};
                2 -> {pick([Time + 1, Time - 900, Time + 900, Time + ?SKEW + 900, -Time, 0,
                            1 bsl 70, float(Time), integer_to_binary(Time)]), Close}
            end,
    Before ++ [Moved | After].

mutate_history(Body) ->
    case rand:uniform(5) of
        5 -> binary:replace(Body, <<"431">>, pick([<<"1.5">>, <<"null">>, <<"[]">>, <<"-1">>]),
                            [global]);
        4 -> binary:replace(Body, <<"\"64010.5\"">>, pick([<<"64010.5">>, <<"\"NaN\"">>, <<"\"-1\"">>,
                                                           <<"\"1e400\"">>, <<"[]">>, <<"null">>]));
        _ -> mutate_bytes(Body)
    end.

entries_ok(Entries, Read) ->
    Entries =/= [] andalso length(Entries) =< 200
        andalso lists:all(fun({Time, Close}) ->
                                  is_integer(Time) andalso Time rem erx_quotes_core:bucket() =:= 0
                                      andalso abs(Time - Read) =< ?SKEW andalso price_ok(Close)
                          end, Entries)
        andalso increasing([Time || {Time, _Close} <- Entries]).

price_ok(Price) ->
    is_float(Price) andalso Price >= 1.0e-12 andalso Price < 1.0e15.

increasing([A, B | Rest]) -> A < B andalso increasing([B | Rest]);
increasing(_Short) -> true.

%% `Entries` made Bitcoin's series, then joined with up to four live
%% prices read at random seconds within four days of `Read`, a round
%% each, an hour apart; the series is checked after every step.
join_round(Table, Entries, Read) ->
    {S0, _} = erx_quotes_core:tick(erx_quotes_core:new(Table, 0), 0, 1.0),
    {S1, _} = erx_quotes_core:history(S0, btc, Entries),
    Lives = [{rand:uniform(100000) / 4, Read + rand:uniform(4 * ?SKEW) - 2 * ?SKEW}
             || _ <- lists:seq(1, rand:uniform(4))],
    Closes = [Close || {_Start, Close} <- Entries] ++ [Price || {Price, _Wall} <- Lives],
    Check = fun(State) ->
                    series_ok(State, Closes) orelse error({bad_series, Entries, Lives, State})
            end,
    Check(S1),
    lists:foldl(fun({Price, Wall}, {State, Now}) ->
                        {S2, _} = erx_quotes_core:tick(State, Now, 1.0),
                        {S3, _} = erx_quotes_core:outcome(S2, btc, {value, Price, none, Wall}, Now, 1.0),
                        Check(S3),
                        {S3, Now + 3600000}
                end, {S1, 0}, Lives).

series_ok(#{quotes := #{btc := #{series := [_ | _] = Series}}}, Closes) ->
    length(Series) =< erx_quotes_core:buckets()
        andalso lists:all(fun({Start, Close}) ->
                                  Start rem erx_quotes_core:bucket() =:= 0 andalso lists:member(Close, Closes)
                          end, Series)
        andalso increasing([Start || {Start, _Close} <- Series]);
series_ok(_State, _Closes) ->
    false.

%% http

http_round() ->
    Result = http_result(),
    Hops = rand:uniform(5) - 1,
    Wall = pick([0, 300, 946684799, 946684800, 1794700800]),
    case no_raise(fun() -> erx_quotes_http:classify(Result, ?URL, Hops, Wall) end, Result) of
        {body, Body} when is_binary(Body) -> ok;
        {follow, Next} when is_binary(Next) ->
            #{scheme := <<"https">>, host := <<"quotes.test">>} = Parsed = uri_string:parse(string:lowercase(Next)),
            443 = maps:get(port, Parsed, 443),
            ok;
        {error, _Reason, none} -> ok;
        {error, _Reason, Ms} when is_integer(Ms), Ms >= 1000, Ms =< 3600000 -> ok;
        Other -> error({not_a_class, Result, Other})
    end.

http_result() ->
    case rand:uniform(3) of
        1 -> {{"HTTP/1.1", pick([200, 301, 302, 303, 307, 308, 429, 503, 404, 0, 99,
                                 1000, -1, 1 bsl 70, ok]),
               "Phrase"}, headers(), pick([<<"body">>, "list", 1])};
        2 -> {error, pick([timeout, body_too_big, {header_too_long, {max, 10240}},
                           {failed_connect, [{to_address, {"h", 443}},
                                             {inet, [inet], pick(connect_reasons())}]},
                           {failed_connect, []}, socket_closed_remotely, "string"])};
        3 -> pick([ok, [], {}, {1, 2, 3}, <<"x">>, {error}, {{1}, [], <<>>}])
    end.

connect_reasons() ->
    [eacces, nxdomain, econnrefused, timeout, {tls_alert, {certificate_expired, "d"}},
     {tls_alert, {unknown_ca, "d"}}, {tls_alert, {decode_error, "d"}}, {tls_alert, x},
     {options, x}].

headers() ->
    [{pick(["location", "retry-after", "content-length", "Location"]), header_value()}
     || _ <- lists:seq(1, rand:uniform(4) - 1)].

header_value() ->
    case rand:uniform(6) of
        1 -> binary_to_list(random_bytes(rand:uniform(64)));
        2 -> pick(["/x", "https://quotes.test/y", "https://quotes.test:443/z",
                   "https://other.test/", "http://quotes.test/", "//other.test/a",
                   "https://quotes.test:8443/", "https://[::1]/", "https://quotes.test@other.test/",
                   "/%zz", "\r\n", ""]);
        3 -> pick(["0", "1", "3600", "99999999999", " 5 ", "-1", "Wed, 21 Oct 2026 07:28:00 GMT"]);
        4 -> [16#110000, $a];
        5 -> integer_to_list(rand:uniform(1 bsl 40));
        6 -> lists:duplicate(10240, $9)
    end.

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
