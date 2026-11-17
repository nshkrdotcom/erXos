%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The real-time clock application's start: erx_rtc_sup.
-module(erx_rtc_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Arguments) ->
    erx_rtc_sup:start_link().

stop(_State) ->
    ok.
