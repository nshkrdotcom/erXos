%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The UART application's start: erx_uart_sup, the line groups of the system domain's
%% UARTs that the console does not drive.
-module(erx_uart_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Arguments) ->
    erx_uart_sup:start_link().

stop(_State) ->
    ok.
