%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_storage_sup).
-moduledoc """
The storage domain's supervisor (docs/design-stopgap.md, "littlefs in the storage domain").
Its children, all permanent under a restart intensity of 0, so the end of
any ends this supervisor and erx_storage, a permanent application, and so
the node and the storage domain:

* the mint of storage_ctl, the driver-control facet through which the system
  domain stops, starts or restarts the block driver under erx_blk's supervisor
  (erx_driver_ctl). The domain service holds the mint until the domain ends;
* `/data`, littlefs on the block driver's data window (erx_lfs_sup), which
  erx_storage's application starts once erx_blk's has started, so the block
  service holds the windows by then. The domain service's restart mounts
  `/data` afresh;
* the `system` tree, the booted slot's system partition, mounted once on
  the block service's `system` window and served as `system_service` by its
  mint (erx_storage_system:start_mint/0; docs/design-storage.md, "The
  `system` tree"). A boot whose block service names no `system` window
  starts no mint. The domain service's restart mounts the tree afresh.
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc false.
init([]) ->
    %% The units this domain holds, by their manifest names, and their driver processes.
    Units = #{block => {erx_blk_sup, erx_blk}},
    Control = #{id => storage_ctl,
                start => {erx_driver_ctl, start_mint, [storage_ctl, Units]},
                restart => permanent,
                shutdown => brutal_kill,
                type => worker,
                modules => [erx_driver_ctl]},
    Data = #{id => erx_lfs_sup,
             start => {erx_lfs_sup, start_link, []},
             restart => permanent,
             shutdown => infinity,
             type => supervisor,
             modules => [erx_lfs_sup]},
    System = #{id => system,
               start => {erx_storage_system, start_mint, []},
               restart => permanent,
               shutdown => brutal_kill,
               type => worker,
               modules => [erx_storage_mint, erx_storage_system]},
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, [Control, Data, System]}}.
