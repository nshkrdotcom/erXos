%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dashboard_app).
-moduledoc """
The application erx_dashboard, the kiosk dashboard of examples/dashboard:
a clock, the date and a quotes panel on its session's display, drawn by
erx-lvgl (docs/design-display.md, "Kiosks and glasses"). Its `source`
value names the quotes source, erx_dashboard_sample unless the release
sets another (erx_dashboard_source).
""".
-behaviour(application).

-export([start/2, stop/1]).

-doc false.
start(_Type, _Args) ->
    erx_dashboard_sup:start_link().

-doc false.
stop(_State) ->
    ok.
