%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_host_sup).
-moduledoc """
The controller group (docs/design-bluetooth.md, "The controller process's effects" and
"Concurrency"): `one_for_all`, at most 5 restarts in 60 s, of the link supervisor, the
line's reader and writer, each registered, and the controller process last, so the
controller process finds its siblings by name when it starts. Any child's end ends the
whole group, which starts again in the same order, so the four always belong to one run of
the core, and a restart resets the line and the controller. It stops in the reverse order,
the controller process first.

The reader and the writer open the line's files with `Open`, `file:open/2` in the domain,
where `erx_ns` has mounted the `line` grant at `/line`; a host test hands a model.
""".
-behaviour(supervisor).

-export([start_link/0, start_link/1]).
-export([init/1]).
-export_type([open/0]).

-type open() :: fun((binary(), [atom()]) -> {ok, pid()} | {error, term()}).

-doc "Starts the group over the line mounted at `/line`.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    start_link(fun file:open/2).

-doc "Starts the group, its reader and writer opening the line's files with `Open`.".
-spec start_link(open()) -> supervisor:startlink_ret().
start_link(Open) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Open).

init(Open) ->
    {ok, {#{strategy => one_for_all, intensity => 5, period => 60},
          [#{id => erx_bt_link_sup, start => {erx_bt_link_sup, start_link, []}, type => supervisor},
           #{id => erx_bt_line_rx, start => {erx_bt_line_rx, start_link, [Open]}},
           #{id => erx_bt_line_tx, start => {erx_bt_line_tx, start_link, [Open]}},
           #{id => erx_bt_hci, start => {erx_bt_hci, start_link, []}}]}}.
