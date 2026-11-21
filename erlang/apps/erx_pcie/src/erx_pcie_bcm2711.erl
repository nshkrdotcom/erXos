%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_bcm2711).
-moduledoc """
The BCM2711 bridge driver (docs/design-pcie.md, "The bridge seam";
docs/design-usb.md, "The BCM2711 bridge"), for the Raspberry Pi 4's
host bridge, peripheral `bcm2711_pcie`. Every decision is
erx_pcie_bcm2711_core's; this module is the effect layer around it. It
runs a core machine to its result, making each operation the core asks
for through its port, and keeps what the start decided for `ready`.

* **The start** runs the core's start machine: the keep-or-reset
  decision from the link and the VL805's firmware register, then the
  keep or the clean turn-off and bring-up. The decision and the link's
  speed and width are logged at each start; a start that fails answers
  the core's reason (`link_down`, `endpoint_mode`, `dma_ranges`,
  `ranges`), which the enumerator logs, reporting none of the bridge's
  functions.
* **An access** runs the core's access machine: absent with no
  operation at a place the bridge does not reach, the root port's space
  directly, any other place between two reads of the link.
* **`ready`** holds the VL805, PCI `1106:3483`, back until its firmware
  reads present. The first time it is asked, after the enumerator has
  numbered the root port and read the VL805's place present, it runs the
  core's firmware machine: on a bridge whose start cycled PERST#, the
  notification, 1 ms, and the firmware register read again; on a kept
  bridge nothing. The answer is kept for the rest of the start, so the
  notification is asked for at most once per PERST# cycle. Firmware that
  still reads absent after the notification, or a notification that
  fails, is logged as `vl805 firmware not loaded`; after a failed
  notification the register is not read again. A link that falls under
  the firmware read is logged and ends the enumerator with `link_down`,
  as an access that answers `link_down` does, so the domain's restart,
  whose start decides the keep or the reset again, is the recovery.
  Every other function is ready.

A **port** makes the core's operations: `Module:op(Op, Handle)` answers
one `erx_pcie_bcm2711_core:op()` and the handle after it, a register
read or write, a wait of at least that many microseconds, a
configuration access at an offset of the bridge's window, or the
firmware notification. open/3 takes any port, as the host tests' model
of the bridge's registers. start/2, the target's, refuses with
`enotsup`: the bridge's record does not carry the tree's `dma-ranges`,
which bring-up's inbound window needs, the device NIF has no view of
the root port's space or the endpoint's data window, and the driver has
no route to the firmware notification, pci_bus:firmware/1 (TODO.md,
"the BCM2711 bridge's start").
""".

-behaviour(erx_pcie_bridge).

-export([start/2, open/3, access/2, ready/2]).
-export([up/1, effects/1]).
-export_type([effects/0, state/0]).

-doc "A port, the effects a core machine asks for: `Module:op(Op, Handle) -> {erx_pcie_bcm2711_core:answer(), Handle}`.".
-type effects() :: {Module :: module(), Handle :: term()}.

%% The VL805's identity (docs/design-pcie.md, "The consumers").
-define(VL805_VENDOR, 16#1106).
-define(VL805_DEVICE, 16#3483).

%% The bridge's record; the core's start machine after its result, from which the
%% firmware machine starts; how the start came up; the port; and the VL805's firmware
%% once `ready` has asked, `unknown` before.
-record(bridge, {record :: erx_abi_layout:erx_pcie_bridge(),
                 started :: erx_pcie_bcm2711_core:core(),
                 up :: erx_pcie_bcm2711_core:up(),
                 port :: effects(),
                 firmware = unknown :: unknown | present | absent | not_loaded}).

-opaque state() :: #bridge{}.

-doc """
The target's start: refused with `enotsup` until the PCIe domain is
given the tree's inbound range, a view of the bridge's configuration
window and a route to the firmware notification (see the module's
documentation).
""".
-spec start(erx_abi_layout:erx_pcie_bridge(), erx_device:device()) -> {error, enotsup}.
start(_Bridge, _Device) ->
    {error, enotsup}.

-doc """
The start over a port: the keep-or-reset decision and what it decides,
with Inbound the tree's `dma-ranges` window. Logs how the bridge came
up; answers the core's reason when it did not.
""".
-spec open(erx_abi_layout:erx_pcie_bridge(), erx_abi_layout:erx_pcie_window(), effects()) ->
          {ok, state()} | {error, erx_pcie_bcm2711_core:reason()}.
open(#{index := Index} = Bridge, Inbound, Port) ->
    case run(erx_pcie_bcm2711_core:start(Bridge, Inbound), Port) of
        {{up, Up}, Started, Next} ->
            logger:notice("pcie: bridge ~b: ~ts", [Index, describe(Up)]),
            {ok, #bridge{record = Bridge, started = Started, up = Up, port = Next}};
        {{error, _} = Error, _Core, _Next} ->
            Error
    end.

-doc "One configuration access through the bridge.".
-spec access(erx_pcie_bridge:access(), state()) -> {erx_pcie_bridge:result(), state()}.
access(Access, #bridge{record = Bridge, port = Port} = State) ->
    {Result, _Core, Next} = run(erx_pcie_bcm2711_core:access(Access, Bridge), Port),
    {Result, State#bridge{port = Next}}.

-doc """
`not_ready` for the VL805 while its firmware does not read present,
asked for once per start; `ok` for every other function.
""".
-spec ready(erx_abi_layout:erx_pcie_function(), state()) -> {ok | not_ready, state()}.
ready(#{vendor := ?VL805_VENDOR, device_id := ?VL805_DEVICE}, State) ->
    Asked = ask_firmware(State),
    case Asked#bridge.firmware of
        present -> {ok, Asked};
        absent -> {not_ready, Asked};
        not_loaded -> {not_ready, Asked}
    end;
ready(_Function, State) ->
    {ok, State}.

-doc "How the start came up: kept or reset, the turn-off's L23 request, the link's speed and width.".
-spec up(state()) -> erx_pcie_bcm2711_core:up().
up(#bridge{up = Up}) -> Up.

-doc "The port as the last operation left it, which the host tests read.".
-spec effects(state()) -> effects().
effects(#bridge{port = Port}) -> Port.

%% The state with the VL805's firmware, asked of the core's firmware machine the first
%% time and kept after: firmware that is not there is logged, and a link that fell
%% is logged and ends the enumerator.
ask_firmware(#bridge{firmware = unknown, record = #{index := Index}, started = Started, port = Port} = State) ->
    case run(erx_pcie_bcm2711_core:firmware(Started), Port) of
        {{firmware, present}, _Core, Next} ->
            State#bridge{firmware = present, port = Next};
        {{firmware, Missing}, _Core, Next} ->
            logger:warning("pcie: bridge ~b: vl805 firmware not loaded", [Index]),
            State#bridge{firmware = Missing, port = Next};
        {{error, link_down}, _Core, _Next} ->
            logger:warning("pcie: bridge ~b: link down under the vl805 firmware read", [Index]),
            exit(link_down)
    end;
ask_firmware(State) ->
    State.

%% A core machine run to its result, each operation made through the port: the
%% result, the core after it and the port after its last operation.
run({Core, {done, Result}}, Port) ->
    {Result, Core, Port};
run({Core, Op}, {Module, Handle}) ->
    {Answer, Next} = Module:op(Op, Handle),
    run(erx_pcie_bcm2711_core:step(Answer, Core), {Module, Next}).

describe(#{path := Path, turn_off := TurnOff, speed := Speed, width := Width}) ->
    io_lib:format("~p, turn-off ~p, link speed ~b, width x~b", [Path, TurnOff, Speed, Width]).
