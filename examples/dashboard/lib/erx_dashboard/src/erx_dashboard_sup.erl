%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dashboard_sup).
-moduledoc """
The dashboard's supervisor: it starts the dashboard's process and starts
it again, with a new window, when its UI ends, up to ?INTENSITY times in
?PERIOD_S seconds, after which the application ends and the session's
keeper decides (docs/design-display.md, "Kiosks and glasses").
""".
-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(INTENSITY, 5).
-define(PERIOD_S, 60).

-doc "Starts the supervisor, registered as erx_dashboard_sup.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc false.
init([]) ->
    {ok, {#{strategy => one_for_one, intensity => ?INTENSITY,
            period => ?PERIOD_S},
          [#{id => erx_dashboard, start => {erx_dashboard, start_link, []}}]}}.
