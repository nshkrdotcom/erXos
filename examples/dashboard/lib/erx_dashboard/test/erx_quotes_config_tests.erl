%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_quotes_config_tests).
-moduledoc """
EUnit cases of the live quotes' table check (docs/design-quotes.md,
"Verification and testing", the table test): the shipped table, which
the test runs beside as `quotes.config`, validates; each bound, at its
edge, is accepted and one past it refused with the row and field named;
an `http` URL, an unknown field, a missing field, a duplicate and an
unused source are refused. Seeded failure: accepting `period` 4 makes
the one-past-the-edge case pass.
""".

-include_lib("eunit/include/eunit.hrl").

-export([table/0, quote/1, source/1]).

-doc "A small valid table: one quote of one JSON source.".
table() ->
    [{quote, btc, quote(#{})}, {source, src, source(#{})}].

-doc "The quote row of table/0 with `Changes` applied.".
quote(Changes) ->
    maps:merge(#{label => <<"BTC">>, decimals => 2, period => 10, sources => [src]}, Changes).

-doc "The source row of table/0 with `Changes` applied.".
source(Changes) ->
    maps:merge(#{url => <<"https://example.test/btc">>, format => json,
                 price => [<<"price">>], change => none, credit => <<"Test">>},
               Changes).

shipped_table_test() ->
    {ok, #{quotes := Quotes, sources := Sources}} = erx_quotes_config:read("quotes.config"),
    ?assertEqual([btc, eth, spx], [Name || {Name, _} <- Quotes]),
    ?assertEqual(6, map_size(Sources)),
    {spx, #{period := 60000, sources := [cboe_spx, fred_spx]}} = lists:keyfind(spx, 1, Quotes),
    ?assertMatch(#{fred_spx := #{format := {csv, 2}, price := none, note := <<"daily close">>}},
                 Sources).

small_table_test() ->
    ?assertMatch({ok, #{quotes := [{btc, #{period := 10000, label := <<"BTC">>}}],
                        sources := #{src := #{note := <<>>}}}},
                 erx_quotes_config:validate(table())).

%% Each bound at its edge is accepted, and one past it refused naming the
%% row and the field.
quote_bounds_test() ->
    Edges = [{period, 5, 4}, {period, 86400, 86401},
             {decimals, 0, -1}, {decimals, 8, 9},
             {label, <<"x">>, <<>>}, {label, binary:copy(<<"x">>, 32), binary:copy(<<"x">>, 33)},
             {label, <<"~">>, <<"\t">>}],
    [begin
         ?assertMatch({ok, _}, validate_quote(#{Field => Edge})),
         ?assertMatch({error, {refused, {quote, btc}, Field, _}}, validate_quote(#{Field => Past}))
     end || {Field, Edge, Past} <- Edges].

source_bounds_test() ->
    Long = <<"https://example.test/", (binary:copy(<<"a">>, 491))/binary>>,
    ?assertEqual(512, byte_size(Long)),
    Edges = [{url, Long, <<Long/binary, "a">>},
             {price, lists:duplicate(8, <<"k">>), lists:duplicate(9, <<"k">>)},
             {price, [0], []},
             {price, [<<"k">>, 0], [<<"k">>, -1]},
             {credit, binary:copy(<<"c">>, 32), binary:copy(<<"c">>, 33)},
             {note, binary:copy(<<"n">>, 48), binary:copy(<<"n">>, 49)},
             {format, json, xml},
             {change, {percent, [<<"p">>]}, {ratio, [<<"p">>]}}],
    [begin
         ?assertMatch({ok, _}, validate_source(#{Field => Edge})),
         ?assertMatch({error, {refused, {source, src}, Field, _}}, validate_source(#{Field => Past}))
     end || {Field, Edge, Past} <- Edges].

csv_test() ->
    Csv = maps:remove(price, source(#{format => {csv, 16}})),
    ?assertMatch({ok, _}, erx_quotes_config:validate([{quote, btc, quote(#{})}, {source, src, Csv}])),
    ?assertMatch({error, {refused, {source, src}, format, _}},
                 erx_quotes_config:validate([{quote, btc, quote(#{})},
                                             {source, src, Csv#{format := {csv, 17}}}])),
    ?assertMatch({error, {refused, {source, src}, price, unknown_field}},
                 validate_source(#{format => {csv, 2}})),
    ?assertMatch({error, {refused, {source, src}, change, _}},
                 erx_quotes_config:validate([{quote, btc, quote(#{})},
                                             {source, src, Csv#{change := {from, [<<"o">>]}}}])).

url_test() ->
    [?assertMatch({error, {refused, {source, src}, url, _}}, validate_source(#{url => Url}))
     || Url <- [<<"https://example.test/", 16#80>>, <<255, 0>>, <<"http://example.test/btc">>, <<"https:///nohost">>, <<"/relative">>,
                <<"ftp://example.test/">>, "https://example.test/"]].

shape_test() ->
    ?assertMatch({error, {refused, {quote, btc}, colour, unknown_field}},
                 validate_quote(#{colour => red})),
    ?assertMatch({error, {refused, {quote, btc}, period, missing}},
                 erx_quotes_config:validate([{quote, btc, maps:remove(period, quote(#{}))},
                                             {source, src, source(#{})}])),
    ?assertMatch({error, {refused, {term, 2}, row, _}},
                 erx_quotes_config:validate([{quote, btc, quote(#{})}, {sauce, src, #{}}])),
    ?assertMatch({error, {refused, table, terms, _}}, erx_quotes_config:validate(not_a_list)),
    ?assertMatch({error, {refused, {quote, btc}, name, duplicate}},
                 erx_quotes_config:validate(table() ++ [{quote, btc, quote(#{})}])),
    ?assertMatch({error, {refused, {source, spare}, sources, unused}},
                 erx_quotes_config:validate(table() ++ [{source, spare, source(#{})}])),
    ?assertMatch({error, {refused, {quote, btc}, sources, unknown_source}},
                 validate_quote(#{sources => [src, nowhere]})),
    ?assertMatch({error, {refused, {quote, btc}, sources, duplicate}},
                 validate_quote(#{sources => [src, src]})),
    ?assertMatch({error, {refused, {quote, btc}, sources, bound}},
                 validate_quote(#{sources => []})),
    ?assertMatch({error, {refused, {quote, btc}, sources, not_a_list}},
                 validate_quote(#{sources => [src | x]})),
    ?assertMatch({error, {refused, {source, src}, price, not_a_list}},
                 validate_source(#{price => [<<"p">> | x]})),
    ?assertMatch({error, {refused, {term, 1}, name, _}},
                 erx_quotes_config:validate([{quote, list_to_atom(lists:duplicate(33, $q)), quote(#{})},
                                             {source, src, source(#{})}])).

count_test() ->
    Quotes = fun(N) -> [{quote, list_to_atom("q" ++ integer_to_list(I)), quote(#{})}
                        || I <- lists:seq(1, N)] end,
    ?assertMatch({ok, _}, erx_quotes_config:validate(Quotes(8) ++ [{source, src, source(#{})}])),
    ?assertMatch({error, {refused, table, quotes, count}},
                 erx_quotes_config:validate(Quotes(9) ++ [{source, src, source(#{})}])),
    ?assertMatch({error, {refused, table, quotes, count}},
                 erx_quotes_config:validate([{source, src, source(#{})}])).

read_refusals_test() ->
    ?assertMatch({error, enoent}, erx_quotes_config:read("no-such-table.config")),
    ok = file:write_file("big.config", binary:copy(<<" ">>, 65537)),
    ?assertEqual({error, too_big}, erx_quotes_config:read("big.config")),
    ok = file:write_file("broken.config", <<"{quote, btc">>),
    ?assertMatch({error, {_Line, _Module, _Description}}, erx_quotes_config:read("broken.config")).

validate_quote(Changes) ->
    erx_quotes_config:validate([{quote, btc, quote(Changes)}, {source, src, source(#{})}]).

validate_source(Changes) ->
    erx_quotes_config:validate([{quote, btc, quote(#{})}, {source, src, source(Changes)}]).
