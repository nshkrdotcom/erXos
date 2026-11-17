%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_extract_tests).
-moduledoc """
EUnit cases of the body reader (docs/design-quotes.md, "Verification and
testing", the extract test): bodies in the shape of each source of the
table, generated here, give the price and change they carry; a missing
key, a wrong type, a 33-byte decimal, `0` and a negative price give
`bad_data`. The history reader takes a generated day of Kraken OHLC
entries and refuses each seeded fault of its answer with `bad_data`.
""".

-include_lib("eunit/include/eunit.hrl").

-export([kraken/3, ohlc/2, day/1]).

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

%% History

%% A wall-clock second on a 15 min boundary: 2026-11-17 01:30 UTC.
-define(WALL, 1794879000).
-define(PAIR, <<"XXBTZUSD">>).

-doc "A Kraken OHLC answer for `Pair` with one entry of 8 items per `{Time, Close}`.".
ohlc(Pair, Entries) ->
    raw(Pair, [entry(Time, Close) || {Time, Close} <- Entries]).

raw(Pair, Entries) ->
    iolist_to_binary(json:encode(#{<<"error">> => [],
                                   <<"result">> => #{Pair => Entries, <<"last">> => ?WALL}})).

entry(Time, Close) ->
    [Time, <<"64000.0">>, <<"64100.5">>, <<"63900.1">>, Close, <<"64010.3">>, <<"12.5">>, 431].

-doc """
A day of `{Time, Close}` up to the bucket of `Wall`, as the request of
erx_quotes_table:history_url/2 is answered: 97 entries on 15 min steps,
the closes 64000.5, 64001.5 and so on as decimal strings.
""".
day(Wall) ->
    [{Wall - 86400 + I * 900, <<(integer_to_binary(64000 + I))/binary, ".5">>}
     || I <- lists:seq(0, 96)].

history(Body) ->
    #{sources := #{kraken_btc := Btc}} = erx_quotes_table:table(),
    erx_quotes_extract:history(Btc, Body, ?WALL).

history_test() ->
    {ok, Entries} = history(ohlc(?PAIR, day(?WALL))),
    ?assertEqual(97, length(Entries)),
    ?assertEqual({?WALL - 86400, 64000.5}, hd(Entries)),
    ?assertEqual({?WALL, 64096.5}, lists:last(Entries)),
    %% The bounds: every bucket from two days before the clock to the one
    %% after its own, 194 entries, and every other item a string or an integer.
    Most = [{?WALL - 172800 + I * 900, <<"1.0">>} || I <- lists:seq(0, 193)],
    ?assertMatch({ok, [_ | _]}, history(ohlc(?PAIR, Most))),
    ?assertMatch({ok, [{?WALL - 172800, 1.0}, {?WALL + 900, 2.0}]},
                 history(ohlc(?PAIR, [{?WALL - 172800, <<"1.0">>}, {?WALL + 900, <<"2.0">>}]))),
    ?assertMatch({ok, [{?WALL, 1.0}]},
                 history(raw(?PAIR, [[?WALL, 1, 2, 3, <<"1.0">>, 4, <<"5">>, 6]]))).

%% Each body is one seeded fault of a good answer, and each is refused.
history_refusals_test() ->
    Good = ohlc(?PAIR, day(?WALL)),
    One = fun(Close) -> ohlc(?PAIR, [{?WALL, Close}]) end,
    Item = fun(At, Value) -> raw(?PAIR, [setelement_list(At, entry(?WALL, <<"1.0">>), Value)]) end,
    Bad = [{oversize, <<Good/binary, (binary:copy(<<" ">>, 65537 - byte_size(Good)))/binary>>},
           {seven_items, raw(?PAIR, [lists:droplast(entry(?WALL, <<"1.0">>))])},
           {nine_items, raw(?PAIR, [entry(?WALL, <<"1.0">>) ++ [1]])},
           {negative, One(<<"-5.0">>)},
           {nan, One(<<"NaN">>)},
           {infinity, One(<<"Infinity">>)},
           {exponent, One(<<"1e5">>)},
           {zero, One(<<"0">>)},
           {too_large, One(<<"1000000000000000">>)},
           {number_close, One(64000.5)},
           {out_of_order, ohlc(?PAIR, [{?WALL, <<"1.0">>}, {?WALL - 900, <<"1.0">>}])},
           {repeated, ohlc(?PAIR, [{?WALL, <<"1.0">>}, {?WALL, <<"1.0">>}])},
           {off_step, ohlc(?PAIR, [{?WALL + 60, <<"1.0">>}])},
           {too_old, ohlc(?PAIR, [{?WALL - 172800 - 900, <<"1.0">>}])},
           {future, ohlc(?PAIR, [{?WALL + 1800, <<"1.0">>}])},
           {too_new, ohlc(?PAIR, [{?WALL + 172800 + 900, <<"1.0">>}])},
           {no_entries, ohlc(?PAIR, [])},
           {too_many, ohlc(?PAIR, [{?WALL - 90000 + I * 900, <<"1.0">>} || I <- lists:seq(0, 200)])},
           {wrong_pair, ohlc(<<"XETHZUSD">>, day(?WALL))},
           {not_a_list, raw(?PAIR, #{<<"0">> => entry(?WALL, <<"1.0">>)})},
           {string_time, Item(1, integer_to_binary(?WALL))},
           {float_count, Item(8, 1.5)},
           {null_open, Item(2, null)},
           {error_set, iolist_to_binary(
                         json:encode(#{<<"error">> => [<<"EGeneral:Too many requests">>],
                                       <<"result">> => #{?PAIR => [entry(?WALL, <<"1.0">>)]}}))},
           {truncated, binary:part(Good, 0, byte_size(Good) - 1)}],
    [?assertEqual({Fault, {error, bad_data}}, {Fault, history(Body)}) || {Fault, Body} <- Bad].

%% `List` with its `At`th item, from 1, replaced by `Value`.
setelement_list(At, List, Value) ->
    {Before, [_ | After]} = lists:split(At - 1, List),
    Before ++ [Value | After].
