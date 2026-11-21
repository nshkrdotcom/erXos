%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_bus_sup).
-moduledoc """
One controller's bus group (docs/design-usb.md, "The process tree"): the
controller process, the bus process, erx_usb_bus, and the function
supervisor, restarted together (`one_for_all`), since the three share the
controller's state: a controller reset ends every device, so the
controller's restart restarts the bus, which enumerates every port again,
and every function.

The function supervisor starts one child per function instance the bus
process asks for, each `temporary`: the bus process alone decides whether
an ended function starts again, after resetting its pipes, within its
restarts (erx_usb_bus_core). An instance is killed when stopped: what it
held lives in the controller and the places, which see it end.

The group restarts at most `usb_bus_restarts_max` times in any
`usb_bus_restart_window_ms`; past that it ends with `shutdown`, which
erx_usb_sup does not restart, so a controller that fails at every reset,
a host controller error that comes back after each, is given up rather
than reset forever.
""".
-behaviour(supervisor).

-include("generated/erx_abi.hrl").

-export([start_link/2, start_function/2]).
-export([init/1]).

-doc """
Starts the bus group, under the controller's erx_usb_sup Usb, of the
controller process that Controller, a `{Module, Function, Args}` start,
starts linked; the bus process attaches
to it (erx_usb_bus_link).
""".
-spec start_link(pid(), {module(), atom(), [term()]}) -> {ok, pid()}.
start_link(Usb, Controller) ->
    supervisor:start_link(?MODULE, {group, Usb, Controller}).

-doc "Starts one function instance: its driver's start_link/1 with Args.".
-spec start_function(erx_usb_claim:driver(), erx_usb_bus:start()) -> {ok, pid()} | {error, term()}.
start_function(Driver, Args) ->
    Driver:start_link(Args).

-doc false.
init({group, Usb, Controller}) ->
    Flags = #{strategy => one_for_all, intensity => ?ERX_USB_BUS_RESTARTS_MAX,
              period => ?ERX_USB_BUS_RESTART_WINDOW_MS div 1000},
    {ok, {Flags, [#{id => controller, start => Controller},
                  #{id => bus, start => {erx_usb_bus, start_link, [self(), Usb]}},
                  #{id => functions, start => {supervisor, start_link, [?MODULE, functions]},
                    type => supervisor}]}};
init(functions) ->
    {ok, {#{strategy => simple_one_for_one},
          [#{id => function, start => {?MODULE, start_function, []}, restart => temporary,
            shutdown => brutal_kill}]}}.
