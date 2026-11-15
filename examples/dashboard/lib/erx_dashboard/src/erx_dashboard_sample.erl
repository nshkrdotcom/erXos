%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dashboard_sample).
-moduledoc """
The dashboard's offline quotes source, the default of the application's
`source` value: a fixed board of illustrative prices that are not
market data, credited as such on the screen, so the dashboard runs with
no network and draws the same panel at every start
(erx_dashboard_source).
""".
-behaviour(erx_dashboard_source).

-export([start_link/1, board/0]).

-doc "Sends `Dashboard` the sample board once and starts no process.".
-spec start_link(pid()) -> ignore.
start_link(Dashboard) ->
    Dashboard ! {erx_dashboard_board, board()},
    ignore.

-doc "The sample board: round, made-up prices, credited as samples.".
-spec board() -> erx_dashboard_source:board().
board() ->
    #{credit => <<"Sample data, not live prices">>,
      quotes => [#{symbol => <<"BTC">>, name => <<"Bitcoin">>,
                   price => 64000.0, change => 1.25, decimals => 2},
                 #{symbol => <<"ETH">>, name => <<"Ether">>,
                   price => 3200.0, change => -0.5, decimals => 2},
                 #{symbol => <<"SPX">>, name => <<"S&P 500">>,
                   price => 5600.0, change => 0.0, decimals => 2}]}.
