%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dashboard_view_tests).
-moduledoc """
EUnit cases of the dashboard's pure parts: the formatters of
erx_dashboard_view, and the tree it builds before and after a board,
which the widget format must accept.
""".

-include_lib("eunit/include/eunit.hrl").

-define(TIME, {{2026, 11, 15}, {9, 41, 7}}).

clock_test() ->
    ?assertEqual(<<"09:41">>, erx_dashboard_view:clock(?TIME)),
    ?assertEqual(<<"00:00">>, erx_dashboard_view:clock({{1970, 1, 1}, {0, 0, 59}})),
    ?assertEqual(<<"23:59">>, erx_dashboard_view:clock({{2026, 1, 1}, {23, 59, 0}})).

minute_test() ->
    ?assertEqual(<<"2026-11-15 09:41">>, erx_dashboard_view:minute({{2026, 11, 15}, {9, 41, 7}})),
    ?assertEqual(<<"1970-01-01 00:00">>, erx_dashboard_view:minute({{1970, 1, 1}, {0, 0, 59}})).

date_test() ->
    ?assertEqual(<<"Sunday, 15 November 2026">>, erx_dashboard_view:date(?TIME)),
    ?assertEqual(<<"Thursday, 1 January 1970">>,
                 erx_dashboard_view:date({{1970, 1, 1}, {0, 0, 0}})).

price_test() ->
    Cases = [{64000.0, 2, <<"64,000.00">>},
             {5600, 2, <<"5,600.00">>},
             {999.995, 2, <<"1,000.00">>},
             {12.5, 0, <<"13">>},
             {0.000123, 6, <<"0.000123">>},
             {1234567.891, 1, <<"1,234,567.9">>},
             {1000000, 0, <<"1,000,000">>},
             {-1234.5, 2, <<"-1,234.50">>},
             {-0.001, 2, <<"0.00">>}],
    [?assertEqual(Text, erx_dashboard_view:price(Price, Decimals))
     || {Price, Decimals, Text} <- Cases].

change_test() ->
    Cases = [{1.25, <<"+1.25%">>},
             {-0.5, <<"-0.50%">>},
             {0, <<"0.00%">>},
             {-0.004, <<"0.00%">>},
             {0.005, <<"+0.01%">>},
             {-12.345, <<"-12.35%">>},
             {1234.5, <<"+1,234.50%">>}],
    [?assertEqual(Text, erx_dashboard_view:change(Percent))
     || {Percent, Text} <- Cases].

%% Every tree the view builds is one the widget format accepts.
tree_is_valid_test() ->
    [?assertEqual(ok, erx_ui_schema:validate(erx_dashboard_view:tree(Model), 1024))
     || Model <- [model(none), model(board())]].

waiting_panel_test() ->
    Texts = texts(erx_dashboard_view:tree(model(none))),
    ?assert(lists:member(<<"Waiting for quotes">>, Texts)),
    ?assert(lists:member(<<"09:41 UTC">>, Texts)),
    ?assert(lists:member(<<"Sunday, 15 November 2026">>, Texts)).

board_panel_test() ->
    Board = board(),
    Tree = erx_dashboard_view:tree(model(Board)),
    Texts = texts(Tree),
    ?assert(lists:member(<<"Sample data, not live prices">>, Texts)),
    ?assertNot(lists:member(<<"Waiting for quotes">>, Texts)),
    [?assert(lists:member(Text, Texts))
     || Text <- [<<"Bitcoin">>, <<"BTC">>, <<"64,000.00">>, <<"+1.25%">>,
                 <<"Ether">>, <<"-0.50%">>, <<"S&P 500">>, <<"0.00%">>]],
    ?assertEqual([<<"BTC">>, <<"ETH">>, <<"SPX">>], keys(Tree)).

%% The view is a function of its model alone.
same_model_same_tree_test() ->
    Model = model(board()),
    ?assertEqual(erx_dashboard_view:tree(Model), erx_dashboard_view:tree(Model)).

%% A board of round, made-up prices.
board() ->
    #{credit => <<"Sample data, not live prices">>,
      quotes => [#{symbol => <<"BTC">>, name => <<"Bitcoin">>,
                   price => 64000.0, change => 1.25, decimals => 2,
                   samples => [63200.0, 63500.0, 63350.0, 63800.0, 64000.0]},
                 #{symbol => <<"ETH">>, name => <<"Ether">>,
                   price => 3200.0, change => -0.5, decimals => 2,
                   samples => [3216.0, 3208.0, 3200.0]},
                 #{symbol => <<"SPX">>, name => <<"S&P 500">>,
                   price => 5600.0, change => 0.0, decimals => 2,
                   samples => []}]}.

model(Board) ->
    #{time => ?TIME, board => Board, dial => erx_dashboard_clock:png(?TIME)}.

%% Each label's text, depth first.
texts({label, #{text := Text}, []}) -> [Text];
texts({_Kind, _Props, Children}) -> lists:flatmap(fun texts/1, Children).

%% Each node's key, depth first.
keys({_Kind, Props, Children}) ->
    [Key || #{key := Key} <- [Props]] ++ lists:flatmap(fun keys/1, Children).

%% Each card's graph spans its prices and the day's opening price, with a
%% tenth of the range free above and below. Seeded failure: scaling
%% without the opening price puts Ether's mark outside the range.
graph_test() ->
    Graphs = graphs(erx_dashboard_view:tree(model(board()))),
    ?assertMatch([#{samples := [100, _, _, _, 900], mark := _},
                  #{samples := [_, _, _], mark := _},
                  #{samples := [], mark := 500}], Graphs),
    [#{mark := BtcOpen}, #{samples := EthSamples, mark := EthOpen}, _] = Graphs,
    ?assertEqual(110, BtcOpen),
    ?assertEqual(900, EthOpen),
    ?assertEqual(lists:reverse(lists:sort(EthSamples)), EthSamples).

%% The clock is a PNG within the widget format's 48 KiB, and changes
%% with the minute. Seeded failure: a dial that ignores the minute
%% fails the last assertion.
clock_picture_test() ->
    Png = erx_dashboard_clock:png(?TIME),
    ?assertMatch(<<137, "PNG", 13, 10, 26, 10, _/binary>>, Png),
    ?assert(byte_size(Png) =< 49152),
    {Date, {Hour, Minute, Second}} = ?TIME,
    ?assertNotEqual(Png, erx_dashboard_clock:png({Date, {Hour, Minute + 1, Second}})).

%% Each graph's properties, depth first.
graphs({graph, Props, []}) -> [Props];
graphs({_Kind, _Props, Children}) -> lists:flatmap(fun graphs/1, Children).
