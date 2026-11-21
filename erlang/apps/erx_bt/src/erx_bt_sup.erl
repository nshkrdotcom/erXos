%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_sup).
-moduledoc """
The top of `erx_bt` (docs/design-bluetooth.md, "Concurrency"): `rest_for_one`, the store
first, then the registry, then the file service `erx_bt_fs` with the pairing window, then
the controller group. The store holds the identity address the controller group reads at
each of its starts, and the window takes the store's state at its own start, so a store's
restart restarts everything after it; the registry holds the handlers and the links'
`Conn` map, and a window's restart ends every link it would have to answer, so a restart
of either restarts the group after it; a group's restart, the one a radio peer's traffic
can cause beyond its own link, leaves the store, its address, the handlers' attachments
and the pairing wait alone.
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
           #{id => erx_gatt_srv, start => {erx_gatt_srv, start_link, [served()]}},
           #{id => erx_bt_fs, start => {erx_bt_fs, start_link, []}},
           #{id => erx_bt_host_sup, start => {erx_bt_host_sup, start_link, []}, type => supervisor}]}}.

%% The services the registry serves: every service abi/gatt declares, until the manifest's
%% `ble` rows reach the domain (TODO.md, Bluetooth).
served() ->
    [erx_gatt_decl:service(Name) || Name <- erx_gatt_decl:names()].
