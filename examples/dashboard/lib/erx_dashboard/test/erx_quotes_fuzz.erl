%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_fuzz).
-moduledoc """
The fuzz target of the live quotes' three readers of untrusted input
(docs/design-quotes.md, "The fuzz target"), run by tools/fuzz/erx_quotes.rb
beside the shipped table as `quotes.config`:

* erx_quotes_extract:value/2 takes bodies of up to 64 KiB for each source
  of the table: random bytes; generated answers of each shape with a
  field mutated, truncated or moved to a bound; nesting 10,000 deep;
  numbers of 400 digits, `e400` and `1.0e300`; CSV with no newline, only
  a header and `\r` alone. Nothing raises; every accepted price is a
  float above 0 and below 10^15 and every change none or a float; an
  unmutated answer gives the price it was built with.
* erx_quotes_http:classify/4 takes httpc-shaped results with random
  status codes, header names and byte values, and random error terms.
  Nothing raises, the answer is a class, and a followed URL keeps the
  origin asked.
* erx_quotes_config:validate/1 takes the shipped table with a field
  replaced, dropped or added, a row duplicated or the terms shuffled.
  Nothing raises, and the answer is a table or a refusal.

None of them may make an atom. The seed comes from make check-fuzz.
""".

-export([run/1]).

-define(ROUNDS, 4000).
-define(URL, <<"https://quotes.test/api">>).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    {ok, Terms} = file:consult("quotes.config"),
    {ok, #{sources := Sources}} = erx_quotes_config:validate(Terms),
    Rounds = fun(N) ->
                     A = length([ok || _ <- lists:seq(1, N), extract_round(Sources) =:= accepted]),
                     [http_round() || _ <- lists:seq(1, N)],
                     [config_round(Terms) || _ <- lists:seq(1, N div 4)],
                     A
             end,
    %% A first call of a reader may load modules, which makes atoms, so the
    %% atom table is compared across the rounds after a first quarter: an
    %% input that made atoms would make new ones from the inputs that follow.
    _ = Rounds(?ROUNDS div 4),
    Atoms = erlang:system_info(atom_count),
    Accepted = Rounds(?ROUNDS),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, erlang:system_info(atom_count) - Atoms}),
    io:format("fuzz: ~p rounds ok, ~p bodies accepted~n", [?ROUNDS, Accepted]).

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

%% An answer in `Name`'s shape whose price is `Value`; `built` is 12345.5.
answer(Name, built) ->
    answer(Name, {<<"12345.50">>, 12345.5});
answer(Name, Value) when not is_tuple(Value) ->
    answer(Name, {Value, Value});
answer(Name, {Text, Number}) ->
    case Name of
        kraken_btc -> erx_quotes_extract_tests:kraken(<<"XXBTZUSD">>, Text, <<"12000.0">>);
        kraken_eth -> erx_quotes_extract_tests:kraken(<<"XETHZUSD">>, Text, <<"12000.0">>);
        coinbase_btc -> erx_quotes_extract_tests:coinbase(Text);
        coinbase_eth -> erx_quotes_extract_tests:coinbase(Text);
        cboe_spx -> erx_quotes_extract_tests:cboe(Number, 0.5);
        fred_spx -> erx_quotes_extract_tests:fred([{"2026-11-13", csv_text(Text)}])
    end.

csv_text(Text) when is_binary(Text) -> Text;
csv_text(Number) -> io_lib:format("~p", [Number]).

bounds() ->
    [<<"0">>, <<"-1">>, <<"999999999999999">>, <<"1000000000000000">>,
     <<"0.000000000001">>, <<"1.0000000000001">>, binary:copy(<<"9">>, 33),
     1.0e300, -1.0e300, 0, 0.0, -0.0, 1.0e15, 999999999999999.9, <<".">>, <<>>,
     <<"1e5">>, <<" 1">>, <<"1 ">>, <<"+1">>, <<"0x10">>].

mutate(Body) ->
    case rand:uniform(5) of
        5 -> binary:replace(Body, <<"\"12000.0\"">>, pick([<<"1e-300">>, <<"5e-324">>, <<"1e-12">>,
                                                          <<"1e14">>, <<"0.001">>, <<"-1">>]));
        1 -> binary:part(Body, 0, rand:uniform(byte_size(Body)) - 1);
        2 -> flip(Body);
        3 -> <<Body/binary, (random_bytes(rand:uniform(16)))/binary>>;
        4 -> binary:replace(Body, <<"12345.50">>, pick([<<"1e400">>, <<"1.0e300">>,
                                                       binary:copy(<<"7">>, 400), <<"[]">>,
                                                       <<"{}">>, <<"null">>, <<"\"\"">>]))
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
        6 -> <<"observation_date,SP500">>;
        7 -> <<"observation_date,SP500\r2026-11-13,5.0\r">>;
        8 -> binary:copy(<<"\n">>, 65536)
    end.

random_bytes(N) ->
    rand:bytes(N).

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

%% config

config_round(Terms) ->
    Mutated = mutate_table(Terms),
    case no_raise(fun() -> erx_quotes_config:validate(Mutated) end, Mutated) of
        {ok, #{quotes := Quotes, sources := Sources}}
          when length(Quotes) =< 8, map_size(Sources) =< 16 -> ok;
        {error, {refused, _Row, Field, Why}} when is_atom(Field), is_atom(Why) -> ok;
        Other -> error({not_a_table, Mutated, Other})
    end.

mutate_table(Terms) ->
    Index = rand:uniform(length(Terms)),
    {Kind, Name, Map} = lists:nth(Index, Terms),
    Field = pick(maps:keys(Map) ++ [note, extra]),
    Row = case rand:uniform(3) of
              1 -> {Kind, Name, Map#{Field => pick(values())}};
              2 -> {Kind, Name, maps:remove(Field, Map)};
              3 -> pick([{Kind, Name}, {Kind, <<"name">>, Map}, {Kind, Name, [Map]}, Map])
          end,
    Replaced = lists:sublist(Terms, Index - 1) ++ [Row] ++ lists:nthtail(Index, Terms),
    case rand:uniform(4) of
        1 -> Replaced ++ [Row];
        2 -> lists:reverse(Replaced);
        _ -> Replaced
    end.

values() ->
    [0, 4, 5, 86400, 86401, -1, 1 bsl 80, 1.5, <<>>, <<"x">>, binary:copy(<<"x">>, 600),
     <<"https://a.test/">>, <<"http://a.test/">>, <<"https://">>, <<255, 0>>, "https://a.test/",
     [], [<<"k">>], [-1], lists:duplicate(9, 0), [[<<"k">>]], json, {csv, 0}, {csv, 2}, {csv, 17},
     none, {from, [<<"o">>]}, {percent, []}, {from, x}, [btc], [nowhere], [kraken_btc, kraken_btc],
     #{}, {}, self(), make_ref()].

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
