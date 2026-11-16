%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_sup).
-moduledoc """
The top of `erx_bt` (docs/design-bluetooth.md, "Concurrency"): `rest_for_one`, the store
first, then the controller group. The store holds the identity address the controller
group reads at each of its starts, so a store's restart restarts the group after it, and
a group's restart leaves the store and its address alone.
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => rest_for_one},
          [#{id => erx_bt_store, start => {erx_bt_store, start_link, []}},
           #{id => erx_bt_host_sup, start => {erx_bt_host_sup, start_link, []}, type => supervisor}]}}.
