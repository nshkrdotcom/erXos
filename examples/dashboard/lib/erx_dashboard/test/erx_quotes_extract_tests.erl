%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_extract_tests).
-moduledoc """
EUnit cases of the body reader (docs/design-quotes.md, "Verification and
testing", the extract test): bodies in the shape of each source of the
shipped table, generated here, give the price and change they carry;
a missing key, a wrong type, a 33-byte decimal, `0`, a negative price
and a CSV whose last line has `.` give `bad_data` or the previous line
as the rule says. Seeded failure: taking the CSV's last line whatever
its field turns the `.` case into `bad_data`.
""".

-include_lib("eunit/include/eunit.hrl").

-export([sources/0, kraken/3, coinbase/1, cboe/2, fred/1]).

-doc "The shipped table's source rows, read from `quotes.config` beside the test.".
sources() ->
    {ok, #{sources := Sources}} = erx_quotes_config:read("quotes.config"),
    Sources.

-doc "A Kraken ticker answer for `Pair` with last price `Last` and opening price `Open`.".
kraken(Pair, Last, Open) ->
    iolist_to_binary(
      json:encode(#{<<"error">> => [],
                    <<"result">> => #{Pair => #{<<"a">> => [<<"1.0">>, <<"1">>, <<"1.000">>],
                                                <<"c">> => [Last, <<"0.001">>],
                                                <<"o">> => Open}}})).

-doc "A Coinbase Exchange ticker answer with price `Price`.".
coinbase(Price) ->
    iolist_to_binary(json:encode(#{<<"trade_id">> => 1, <<"price">> => Price,
                                   <<"size">> => <<"0.01">>, <<"time">> => <<"2026-11-15T00:00:00Z">>})).

-doc "A Cboe delayed quote with current price `Price` and percent change `Change`.".
cboe(Price, Change) ->
    iolist_to_binary(json:encode(#{<<"timestamp">> => <<"2026-11-15 10:00:00">>,
                                   <<"data">> => #{<<"symbol">> => <<"_SPX">>,
                                                   <<"current_price">> => Price,
                                                   <<"price_change_percent">> => Change}})).

-doc "A FRED graph CSV of `Rows`, each `{Date, Value}`.".
fred(Rows) ->
    iolist_to_binary(["observation_date,SP500\n" | [[Date, ",", Value, "\n"] || {Date, Value} <- Rows]]).

value(Source, Body) ->
    erx_quotes_extract:value(maps:get(Source, sources()), Body).

shapes_test() ->
    {ok, Btc, BtcChange} = value(kraken_btc, kraken(<<"XXBTZUSD">>, <<"64412.50">>, <<"64000.00">>)),
    ?assertEqual(64412.5, Btc),
    ?assert(abs(BtcChange - 0.64453125) < 1.0e-9),
    ?assertMatch({ok, 3200.0, _}, value(kraken_eth, kraken(<<"XETHZUSD">>, <<"3200">>, <<"3100.0">>))),
    ?assertEqual({ok, 64400.01, none}, value(coinbase_btc, coinbase(<<"64400.01">>))),
    ?assertEqual({ok, 5631.22, -0.25}, value(cboe_spx, cboe(5631.22, -0.25))),
    ?assertEqual({ok, 5600.0, 1.0}, value(cboe_spx, cboe(5600, 1))),
    ?assertEqual({ok, 5631.22, none},
                 value(fred_spx, fred([{"2026-11-12", "5600.10"}, {"2026-11-13", "5631.22"}]))).

refusals_test() ->
    Bad = [{kraken_btc, kraken(<<"XETHZUSD">>, <<"1.0">>, <<"1.0">>)},     % missing key
           {coinbase_btc, coinbase(true)},                               % wrong type
           {coinbase_btc, coinbase(binary:copy(<<"1">>, 33))},           % 33 bytes
           {coinbase_btc, coinbase(<<"1234567890123456">>)},             % 16 digits
           {coinbase_btc, coinbase(<<"1.1234567890123">>)},              % 13 decimals
           {coinbase_btc, coinbase(<<"0">>)},
           {coinbase_btc, coinbase(<<"-5.0">>)},
           {coinbase_btc, coinbase(<<"1e5">>)},
           {coinbase_btc, coinbase(<<"5.">>)},
           {coinbase_btc, coinbase(<<"5\n">>)},
           {coinbase_btc, coinbase(1.0e15)},
           {cboe_spx, cboe(5600, -100.5)},
           {cboe_spx, cboe(5600, 1000.5)},
           {kraken_btc, kraken(<<"XXBTZUSD">>, <<"1.0">>, <<"0">>)},       % zero reference
           {coinbase_btc, <<"{\"price\": \"1.0\"">>},                     % truncated
           {coinbase_btc, <<"[1, 2]">>},
           {coinbase_btc, binary:copy(<<" ">>, 65537)},
           {fred_spx, <<"observation_date,SP500">>},
           {fred_spx, <<>>}],
    [?assertEqual({Source, {error, bad_data}}, {Source, value(Source, Body)})
     || {Source, Body} <- Bad],
    %% A JSON number is a price as a decimal string is.
    ?assertMatch({ok, 64412.5, _}, value(kraken_btc, kraken(<<"XXBTZUSD">>, 64412.5, <<"64000.0">>))).

csv_test() ->
    ?assertEqual({ok, 5600.1, none},
                 value(fred_spx, fred([{"2026-11-12", "5600.10"}, {"2026-11-13", "."}]))),
    ?assertEqual({ok, 5600.1, none},
                 value(fred_spx, <<"observation_date,SP500\r\n2026-11-12,5600.10\r\n2026-11-13,\r\n">>)),
    ?assertEqual({error, bad_data}, value(fred_spx, fred([{"2026-11-13", "."}]))),
    ?assertEqual({error, bad_data}, value(fred_spx, fred([{"2026-11-13", "-1.0"}]))).

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
