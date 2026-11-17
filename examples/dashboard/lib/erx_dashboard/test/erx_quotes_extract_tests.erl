%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_extract_tests).
-moduledoc """
EUnit cases of the body reader (docs/design-quotes.md, "Verification and
testing", the extract test): bodies in the shape of each source of the
table, generated here, give the price and change they carry; a missing
key, a wrong type, a 33-byte decimal, `0` and a negative price give
`bad_data`.
""".

-include_lib("eunit/include/eunit.hrl").

-export([kraken/3]).

-doc "A Kraken ticker answer for `Pair` with last price `Last` and opening price `Open`.".
kraken(Pair, Last, Open) ->
    iolist_to_binary(
      json:encode(#{<<"error">> => [],
                    <<"result">> => #{Pair => #{<<"a">> => [<<"1.0">>, <<"1">>, <<"1.000">>],
                                                <<"c">> => [Last, <<"0.001">>],
                                                <<"o">> => Open}}})).

value(Source, Body) ->
    #{sources := Sources} = erx_quotes_table:table(),
    erx_quotes_extract:value(maps:get(Source, Sources), Body).

%% A source whose answer is `{"price": Price}`.
plain(Price) ->
    erx_quotes_extract:value(#{format => json, price => [<<"price">>], change => none},
                             iolist_to_binary(json:encode(#{<<"price">> => Price}))).

shapes_test() ->
    {ok, Btc, BtcChange} = value(kraken_btc, kraken(<<"XXBTZUSD">>, <<"64412.50">>, <<"64000.00">>)),
    ?assertEqual(64412.5, Btc),
    ?assert(abs(BtcChange - 0.64453125) < 1.0e-9),
    ?assertMatch({ok, 3200.0, _}, value(kraken_eth, kraken(<<"XETHZUSD">>, <<"3200">>, <<"3100.0">>))),
    ?assertMatch({ok, 71.73, _}, value(kraken_sol, kraken(<<"SOLUSD">>, <<"71.73000">>, <<"72.73000">>))),
    ?assertEqual({ok, 64400.01, none}, plain(<<"64400.01">>)).

refusals_test() ->
    Bad = [kraken(<<"XETHZUSD">>, <<"1.0">>, <<"1.0">>),       % missing key
           kraken(<<"XXBTZUSD">>, <<"1.0">>, <<"0">>),         % zero reference
           kraken(<<"XXBTZUSD">>, <<"1.0">>, <<"0.0001">>),    % change past 1000 percent
           %% a fall that rounds to -100 percent, which leaves no opening price
           kraken(<<"XXBTZUSD">>, <<"0.000000000001">>, <<"100000">>),
           <<"{\"result\": 1">>,                               % truncated
           <<"[1, 2]">>,
           binary:copy(<<" ">>, 65537)],
    [?assertEqual({Body, {error, bad_data}}, {Body, value(kraken_btc, Body)}) || Body <- Bad],
    Prices = [true, binary:copy(<<"1">>, 33), <<"1234567890123456">>, <<"1.1234567890123">>,
              <<"0">>, <<"-5.0">>, <<"1e5">>, <<"5.">>, <<"5\n">>, 1.0e15],
    [?assertEqual({Price, {error, bad_data}}, {Price, plain(Price)}) || Price <- Prices],
    %% A JSON number is a price as a decimal string is.
    ?assertMatch({ok, 64412.5, _}, value(kraken_btc, kraken(<<"XXBTZUSD">>, 64412.5, <<"64000.0">>))).

array_index_test() ->
    Source = #{format => json, price => [<<"p">>, 2], change => none},
    ?assertEqual({ok, 3.0, none}, erx_quotes_extract:value(Source, <<"{\"p\": [1, 2, 3]}">>)),
    ?assertEqual({error, bad_data}, erx_quotes_extract:value(Source, <<"{\"p\": [1, 2]}">>)),
    ?assertEqual({error, bad_data}, erx_quotes_extract:value(Source, <<"{\"p\": {\"2\": 3}}">>)).

%% A computed change past its bound, or a reference so small it would
%% overflow the division, is bad_data, never a crash or a huge change.
computed_change_test() ->
    Source = #{format => json, price => [<<"p">>], change => {from, [<<"o">>]}},
    [?assertEqual({error, bad_data}, erx_quotes_extract:value(Source, Body))
     || Body <- [<<"{\"p\": 1e10, \"o\": 1e-300}">>, <<"{\"p\": 64000, \"o\": 5e-324}">>,
                 <<"{\"p\": 64000, \"o\": 1e-301}">>, <<"{\"p\": 1e-300, \"o\": 1}">>,
                 <<"{\"p\": 12, \"o\": 1}">>]],
    ?assertEqual({ok, 2.0, -50.0}, erx_quotes_extract:value(Source, <<"{\"p\": 2, \"o\": 4}">>)).

hostile_test() ->
    Source = #{format => json, price => [<<"p">>], change => none},
    Deep = iolist_to_binary([lists:duplicate(10000, $[), lists:duplicate(10000, $])]),
    [?assertEqual({error, bad_data}, erx_quotes_extract:value(Source, Body))
     || Body <- [Deep, <<"{\"p\": 1e400}">>, <<"{\"p\": 1.0e300}">>,
                 <<"{\"p\": ", (binary:copy(<<"9">>, 400))/binary, "}">>,
                 <<255, 254, 0>>, <<"{\"p\": 1} trailing">>]].
