%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_desk_app).
-moduledoc "The erx_desk application: starts erx_desk_sup.".
-behaviour(application).

-export([start/2, stop/1]).

-doc false.
start(_Type, _Args) ->
    erx_desk_sup:start_link().

-doc false.
stop(_State) ->
    ok.
