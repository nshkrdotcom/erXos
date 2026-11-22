%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_app).
-moduledoc """
The Bluetooth application (docs/design-bluetooth.md, "The controller's line"). Its start
mounts each facet the domain holds or the manifest grants it that has a place in the
namespace (erx_ns:mount_facets/1), as a session's does. The Bluetooth domain's row starts
it with `-eval`, which init runs once it holds the ready answer's facets, and every
release only loads it, so no boot script starts it earlier. The `line` grant, which the
domain service hands over in that answer, has the place `/line` that erx_ns:place/1 gives
it. Then it starts `erx_bt_sup`, whose controller
group opens `/line/data` and `/line/ctl`.
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    ok = erx_ns:mount_facets(lists:usort(erx:granted() ++ maps:keys(erx:caps()))),
    erx_bt_sup:start_link().

stop(_State) ->
    ok.
