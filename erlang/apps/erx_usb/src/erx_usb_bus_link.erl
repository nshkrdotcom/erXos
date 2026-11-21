%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_bus_link).
-moduledoc """
The messages between a controller process and its bus process
(docs/design-usb.md, "The controller process" and "Ports, hubs and
devices: the bus core"): the one module that spells them, used by the bus
process, erx_usb_bus, and by the controller process on the other side, so
a change of shape is a change here alone.

The bus process attaches itself with attach/1 once it starts; the
controller answers `{root_ports, N}` when its start reaches the bus (the
design's start, step 4), and from then on sends the bus process its root
ports' events and the answers to its requests, each an event of
erx_usb_bus_core as the core names it. The bus process sends every request
with request/2: the bus core's root-hub operations, enumeration requests,
pipe resets and detaches as the core makes them, and an external hub's
port operations as `{control, Hub, {port, Target, Op}, Setup, Data}`, a
control request on the hub's EP0 whose tag takes the place of an
enumeration step. The controller echoes a request's reference and tag in
its answer and never reads either from a device's data.

Every message carries the module's tag, so the bus process takes from its
mailbox only what came this way.
""".

-export([attach/1, request/2, answer/2, from_controller/1]).

-export_type([request/0, answer/0]).

-doc "What the bus process asks of its controller.".
-type request() :: attach
                 | {port, root, erx_usb_bus_core:target(), erx_usb_bus_core:op()}
                 | {control, erx_usb_bus_core:ref(), term(), <<_:64>>, none | {in, pos_integer()}}
                 | {enable_slot, erx_usb_bus_core:ref(), erx_usb_bus_core:step()}
                 | {address, erx_usb_bus_core:ref(), erx_usb_bus_core:step(), map()}
                 | {evaluate_context, erx_usb_bus_core:ref(), erx_usb_bus_core:step(), map()}
                 | {configure_endpoints, erx_usb_bus_core:ref(), erx_usb_bus_core:step(), map()}
                 | {reset_pipe, erx_usb_bus_core:ref(), byte(), byte()}
                 | {detach, erx_usb_bus_core:ref()}.

-doc "What the controller sends its bus process: the root hub's port count, then core events.".
-type answer() :: {root_ports, 1..255} | erx_usb_bus_core:event().

-doc "Attaches the calling bus process to Controller.".
-spec attach(pid()) -> ok.
attach(Controller) ->
    request(Controller, attach).

-doc "Sends Request to Controller from the calling bus process.".
-spec request(pid(), request()) -> ok.
request(Controller, Request) ->
    Controller ! {?MODULE, self(), Request},
    ok.

-doc "Sends Answer to Bus, from the controller side.".
-spec answer(pid(), answer()) -> ok.
answer(Bus, Answer) ->
    Bus ! {?MODULE, Answer},
    ok.

-doc "The answer a message to the bus process carries, or `none` for a message that did not come this way.".
-spec from_controller(term()) -> {ok, answer()} | none.
from_controller({?MODULE, Answer}) -> {ok, Answer};
from_controller(_Other) -> none.
