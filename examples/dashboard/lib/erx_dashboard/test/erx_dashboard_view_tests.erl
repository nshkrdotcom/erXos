%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dashboard_view_tests).
-moduledoc """
EUnit cases of the dashboard's pure parts: the formatters of
erx_dashboard_view, the tree it builds before and after a board, which
the widget format must accept, and the sample source's one board.
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
     || Model <- [model(none), model(erx_dashboard_sample:board())]].

waiting_panel_test() ->
    Texts = texts(erx_dashboard_view:tree(model(none))),
    ?assert(lists:member(<<"Waiting for quotes">>, Texts)),
    ?assert(lists:member(<<"09:41">>, Texts)),
    ?assert(lists:member(<<"Sunday, 15 November 2026">>, Texts)).

board_panel_test() ->
    Board = erx_dashboard_sample:board(),
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
    Model = model(erx_dashboard_sample:board()),
    ?assertEqual(erx_dashboard_view:tree(Model), erx_dashboard_view:tree(Model)).

sample_sends_its_board_once_test() ->
    ?assertEqual(ignore, erx_dashboard_sample:start_link(self())),
    Board = erx_dashboard_sample:board(),
    receive {erx_dashboard_board, Sent} -> ?assertEqual(Board, Sent)
    after 0 -> ?assert(false)
    end,
    receive Extra -> ?assertEqual(none, Extra) after 0 -> ok end.

model(Board) ->
    #{time => ?TIME, board => Board}.

%% Each label's text, depth first.
texts({label, #{text := Text}, []}) -> [Text];
texts({_Kind, _Props, Children}) -> lists:flatmap(fun texts/1, Children).

%% Each node's key, depth first.
keys({_Kind, Props, Children}) ->
    [Key || #{key := Key} <- [Props]] ++ lists:flatmap(fun keys/1, Children).
