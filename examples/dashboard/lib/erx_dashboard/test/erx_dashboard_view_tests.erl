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
    ?assertEqual(<<"Sunday, 15 November">>, erx_dashboard_view:date(?TIME)),
    ?assertEqual(<<"Thursday, 1 January">>,
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
    Cases = [{1.25, <<16#2191/utf8, " 1.25%">>},
             {-0.5, <<16#2193/utf8, " 0.50%">>},
             {0, <<"0.00%">>},
             {-0.004, <<"0.00%">>},
             {0.005, <<16#2191/utf8, " 0.01%">>},
             {-12.345, <<16#2193/utf8, " 12.35%">>},
             {1234.5, <<16#2191/utf8, " 1,234.50%">>}],
    [?assertEqual(Text, erx_dashboard_view:change(Percent))
     || {Percent, Text} <- Cases].

%% Every tree the view builds is one the widget format accepts.
tree_is_valid_test() ->
    [?assertEqual(ok, erx_ui_schema:validate(erx_dashboard_view:tree(Model), 1024))
     || Model <- [model(none), model(board())]].

%% The dashboard's first tree, before either picture is drawn: one the
%% widget format accepts, with no picture, the panel waiting and the
%% dial's square kept empty, so the layout stays when the pictures come.
first_tree_test() ->
    Tree = erx_dashboard_view:tree((model(none))#{dial := none, ground := none}),
    Size = erx_dashboard_clock:size(),
    ?assertEqual(ok, erx_ui_schema:validate(Tree, 1024)),
    ?assertEqual([], [Image || {image, _Props, _Children} = Image <- descendants(Tree)]),
    ?assert(lists:member(<<"Waiting for quotes">>, texts(Tree))),
    ?assert(lists:member({spacer, #{width => Size, height => Size}, []}, descendants(Tree))).

waiting_panel_test() ->
    Texts = texts(erx_dashboard_view:tree(model(none))),
    ?assert(lists:member(<<"Waiting for quotes">>, Texts)),
    ?assert(lists:member(<<"09:41 UTC">>, Texts)),
    ?assert(lists:member(<<"Sunday, 15 November">>, Texts)).

board_panel_test() ->
    Board = board(),
    Tree = erx_dashboard_view:tree(model(Board)),
    Texts = texts(Tree),
    ?assert(lists:member(<<"Sample data, not live prices">>, Texts)),
    ?assertNot(lists:member(<<"Waiting for quotes">>, Texts)),
    [?assert(lists:member(Text, Texts))
     || Text <- [<<"Bitcoin">>, <<"BTC">>, <<"64,000.00">>, <<16#2191/utf8, " 1.25%">>,
                 <<"Ether">>, <<16#2193/utf8, " 0.50%">>, <<"S&P 500">>, <<"0.00%">>]],
    ?assertEqual([<<"BTC">>, <<"ETH">>, <<"SPX">>], keys(Tree)),
    ?assertEqual([up, down, flat], [Trend || {label, #{trend := Trend}, []} <- descendants(Tree)]).

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
    #{time => ?TIME, board => Board, dial => erx_dashboard_clock:png(dark, ?TIME), ground => <<"ground">>}.

%% Each label's text, depth first.
texts({label, #{text := Text}, []}) -> [Text];
texts({_Kind, _Props, Children}) -> lists:flatmap(fun texts/1, Children).

%% Each node's key, depth first.
keys({_Kind, Props, Children}) ->
    [Key || #{key := Key} <- [Props]] ++ lists:flatmap(fun keys/1, Children).

%% Each card's graph spans its prices, with a tenth of the range free
%% above and below, and marks the day's opening price only within that
%% range. Seeded failure: marking an opening price outside the prices'
%% range puts Ether's mark outside the graph, which the schema refuses.
graph_test() ->
    Graphs = graphs(erx_dashboard_view:tree(model(board()))),
    ?assertMatch([#{samples := [100, _, _, _, 900], mark := 110},
                  #{samples := [900, 500, 100]},
                  #{samples := [], mark := 500}], Graphs),
    ?assertNot(maps:is_key(mark, lists:nth(2, Graphs))).

%% The clock is a PNG within the widget format's 48 KiB, and changes
%% with the minute. Seeded failure: a dial that ignores the minute
%% fails the last assertion.
clock_picture_test() ->
    Png = erx_dashboard_clock:png(dark, ?TIME),
    ?assertMatch(<<137, "PNG", 13, 10, 26, 10, _/binary>>, Png),
    ?assert(byte_size(Png) =< 49152),
    {Date, {Hour, Minute, Second}} = ?TIME,
    ?assertNotEqual(Png, erx_dashboard_clock:png(dark, {Date, {Hour, Minute + 1, Second}})).

%% The ground is an indexed PNG within the widget format's 48 KiB, which a
%% truecolour picture of it is not. Seeded failure: a glow that adds a
%% second colour instead of pulling along the path overflows the palette.
ground_picture_test() ->
    Png = erx_dashboard_pictures:ground(erx_dashboard_view:clock_offset()),
    ?assertMatch(<<137, "PNG", 13, 10, 26, 10, 13:32, "IHDR", 1920:32, 1080:32, 8, 3, _/binary>>, Png),
    ?assert(byte_size(Png) =< 49152),
    ?assertEqual({-284, -42}, erx_dashboard_view:clock_offset()).

%% Every node, depth first.
descendants({_Kind, _Props, Children} = Node) -> [Node | lists:flatmap(fun descendants/1, Children)].

%% Each graph's properties, depth first.
graphs({graph, Props, []}) -> [Props];
graphs({_Kind, _Props, Children}) -> lists:flatmap(fun graphs/1, Children).
