%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_sup).
-moduledoc """
One controller's supervisor (docs/design-usb.md, "The process tree"):
its places, erx_usb_places_sup, then its bus group, erx_usb_bus_sup,
`rest_for_one`. The places hold no device state, so a failure of the bus
group leaves them running, and a reader outside the domain never sees its
file end while the domain lives; a failure of the places restarts the bus
group after them, since its functions occupy places that are gone.

The bus group is `transient`: one that ends past its own restarts ends
with `shutdown`, which is not restarted here, so the controller is given
up while the places stay. Both supervisors restart at most
`usb_bus_restarts_max` times in any `usb_bus_restart_window_ms`.
""".
-behaviour(supervisor).

-include("generated/erx_abi.hrl").

-export([start_link/1]).
-export([init/1]).

-doc "Starts the supervisor of the controller whose process Controller, a `{Module, Function, Args}` start, starts.".
-spec start_link({module(), atom(), [term()]}) -> {ok, pid()}.
start_link(Controller) ->
    supervisor:start_link(?MODULE, Controller).

-doc false.
init(Controller) ->
    Flags = #{strategy => rest_for_one, intensity => ?ERX_USB_BUS_RESTARTS_MAX,
              period => ?ERX_USB_BUS_RESTART_WINDOW_MS div 1000},
    {ok, {Flags, [#{id => places, start => {erx_usb_places_sup, start_link, []}, type => supervisor},
                  #{id => bus, start => {erx_usb_bus_sup, start_link, [Controller]}, type => supervisor,
                    restart => transient}]}}.
