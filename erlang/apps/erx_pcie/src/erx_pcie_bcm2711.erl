%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_bcm2711).
-moduledoc """
The BCM2711 bridge driver (docs/design-pcie.md, "The bridge seam";
docs/design-usb.md, "The BCM2711 bridge"), for the Raspberry Pi 4's
host bridge, peripheral `bcm2711_pcie`. Every decision is
erx_pcie_bcm2711_core's; this module is the effect layer around it. It
runs a core machine to its result, making each operation the core asks
for, and keeps what the start decided for `ready`.

* **The start** runs the core's start machine: the keep-or-reset
  decision from the bridge's reset and SerDes power, the link and the
  VL805's firmware register, then the
  keep or the clean turn-off and bring-up. The decision is logged at
  each start; a start that fails answers the core's reason
  (`link_down`, `endpoint_mode`, `dma_ranges`, `ranges`), which the
  enumerator logs, reporting none of the bridge's functions.
* **An access** runs the core's access machine: absent with no
  operation at a place the bridge does not reach, the root port in its
  own configuration space, any other place between two reads of the
  link.
* **`ready`** holds the VL805, PCI `1106:3483`, back until its firmware
  reads present. The first time it is asked, after the enumerator has
  numbered the root port and read the VL805's place present, it runs the
  core's firmware machine: on a bridge whose start cycled PERST#, the
  firmware register read, the notification, 1 ms, and the register read
  again; on a kept
  bridge nothing. The answer is kept for the rest of the start, so the
  notification is asked for at most once per PERST# cycle. Firmware that
  still reads absent after the notification, or a notification that
  fails, is logged as `vl805 firmware not loaded`; after a failed
  notification the register is not read again. A link that falls under
  the firmware read is logged and answered `{error, link_down}`, which
  ends the enumerator as an access's `link_down` does, so the domain's
  restart, whose start decides the keep or the reset again, is the
  recovery. Every other function is ready.
* **Probe B1's lines** (docs/design-usb.md, "The VL805's firmware"): the
  start's line names what the VL805's firmware register read at the
  start, and on a bridge whose start cycled PERST# `ready` logs it again
  just before the notification is sent, so a notification that never
  answers still leaves that line, and 1 ms after it, with the
  notification's status and its round trip in microseconds, timed around
  the seam's `firmware` effect.

The core's operations are made through three effects. Register and
configuration accesses go to the bridge's device in erx_device's shape,
`{Module, Handle}`: `Module:read/2` and `write/3` on the SVD's
registers, `config_read/4` and `config_write/5` on its configuration
spaces `root_port` and `ext_cfg_data`. A wait of some microseconds is
the seam's `sleep`, rounded up to whole milliseconds, and the
notification is the seam's `firmware`. start/3, the target's, reaches
the device through erx_device; open/3 takes any module of that shape,
as the host tests' model of the bridge, which cannot load the device
NIF.
""".

-behaviour(erx_pcie_bridge).

-export([start/3, open/3, access/2, ready/2]).
-export([up/1]).
-export_type([device/0, state/0]).

-doc """
The bridge's registers and configuration spaces in erx_device's shape:
`Module:read(Handle, Register)`, `Module:write(Handle, Register, Word)`,
`Module:config_read(Handle, Space, Offset, Width)` and
`Module:config_write(Handle, Space, Offset, Width, Value)`.
""".
-type device() :: {Module :: module(), Handle :: term()}.

%% The VL805's identity (docs/design-pcie.md, "The consumers").
-define(VL805_VENDOR, 16#1106).
-define(VL805_DEVICE, 16#3483).

%% The bridge's record; the core's start machine after its result, from which the
%% firmware machine starts; how the start came up; the device and the seam's effects;
%% and the VL805's firmware once `ready` has asked, `unknown` before.
-record(bridge, {record :: erx_abi_layout:erx_pcie_bridge(),
                 started :: erx_pcie_bcm2711_core:core(),
                 up :: erx_pcie_bcm2711_core:up(),
                 device :: device(),
                 effects :: erx_pcie_bridge:effects(),
                 firmware = unknown :: unknown | present | absent | not_loaded}).

-opaque state() :: #bridge{}.

-doc "The target's start, over the bridge's device.".
-spec start(erx_abi_layout:erx_pcie_bridge(), erx_device:device(), erx_pcie_bridge:effects()) ->
          {ok, state()} | {error, erx_pcie_bcm2711_core:reason()}.
start(Bridge, Device, Effects) ->
    open(Bridge, {erx_device, Device}, Effects).

-doc """
The start over a device of erx_device's shape: the keep-or-reset
decision and what it decides. Logs how the bridge came up; answers the
core's reason when it did not.
""".
-spec open(erx_abi_layout:erx_pcie_bridge(), device(), erx_pcie_bridge:effects()) ->
          {ok, state()} | {error, erx_pcie_bcm2711_core:reason()}.
open(#{index := Index} = Bridge, Device, Effects) ->
    case run(erx_pcie_bcm2711_core:start(Bridge), Index, Device, Effects) of
        {{up, Up}, Started} ->
            logger:notice("pcie: bridge ~b: ~ts", [Index, describe(Up)]),
            {ok, #bridge{record = Bridge, started = Started, up = Up, device = Device, effects = Effects}};
        {{error, _} = Error, _Core} ->
            Error
    end.

-doc "One configuration access through the bridge.".
-spec access(erx_pcie_bridge:access(), state()) -> {erx_pcie_bridge:result(), state()}.
access(Access, #bridge{record = #{index := Index} = Bridge, device = Device, effects = Effects} = State) ->
    {Result, _Core} = run(erx_pcie_bcm2711_core:access(Access, Bridge), Index, Device, Effects),
    {Result, State}.

-doc """
`not_ready` for the VL805 while its firmware does not read present,
asked for once per start, and `{error, link_down}` when the link fell
under the firmware read; `ok` for every other function.
""".
-spec ready(erx_abi_layout:erx_pcie_function(), state()) -> {ok | not_ready, state()} | {error, link_down}.
ready(#{vendor := ?VL805_VENDOR, device_id := ?VL805_DEVICE}, State) ->
    case ask_firmware(State) of
        {ok, #bridge{firmware = present} = Asked} -> {ok, Asked};
        {ok, Asked} -> {not_ready, Asked};
        {error, link_down} = Error -> Error
    end;
ready(_Function, State) ->
    {ok, State}.

-doc "How the start came up: kept or reset, the turn-off's L23 request, and the firmware register's reading.".
-spec up(state()) -> erx_pcie_bcm2711_core:up().
up(#bridge{up = Up}) -> Up.

%% The state with the VL805's firmware, asked of the core's firmware machine the first
%% time and kept after: firmware that is not there is logged, and a link that fell is
%% logged and answered.
ask_firmware(#bridge{firmware = unknown, record = #{index := Index}, started = Started,
                     device = Device, effects = Effects} = State) ->
    case run(erx_pcie_bcm2711_core:firmware(Started), Index, Device, Effects) of
        {{firmware, present, Probe}, _Core} ->
            probed(Index, Probe),
            {ok, State#bridge{firmware = present}};
        {{firmware, Missing, Probe}, _Core} ->
            probed(Index, Probe),
            logger:warning("pcie: bridge ~b: vl805 firmware not loaded", [Index]),
            {ok, State#bridge{firmware = Missing}};
        {{error, link_down, Probe}, _Core} ->
            probed(Index, Probe),
            logger:warning("pcie: bridge ~b: link down under the vl805 firmware read", [Index]),
            {error, link_down}
    end;
ask_firmware(State) ->
    {ok, State}.

%% A core machine of bridge Index run to its result, each operation made as it asks:
%% the result and the core after it.
run({Core, {done, Result}}, _Index, _Device, _Effects) ->
    {Result, Core};
run({Core, Op}, Index, Device, Effects) ->
    run(erx_pcie_bcm2711_core:step(make(Op, Index, Device, Effects), Core), Index, Device, Effects).

%% One operation of the core, and its answer; the notification is logged with the
%% reading before it, probe B1's line after the PERST# cycle, before it is sent.
make({read, Register}, _Index, {Module, Handle}, _Effects) ->
    Module:read(Handle, Register);
make({write, Register, Word}, _Index, {Module, Handle}, _Effects) ->
    Module:write(Handle, Register, Word);
make({cfg_read, Space, Offset, Width}, _Index, {Module, Handle}, _Effects) ->
    Module:config_read(Handle, Space, Offset, Width);
make({cfg_write, Space, Offset, Width, Value}, _Index, {Module, Handle}, _Effects) ->
    Module:config_write(Handle, Space, Offset, Width, Value);
make({wait, Microseconds}, _Index, _Device, #{sleep := Sleep}) ->
    ok = Sleep((Microseconds + 999) div 1000);
make({notify_firmware, AfterPerst}, Index, _Device, #{firmware := Firmware}) ->
    logger:notice("pcie: bridge ~b: vl805 firmware ~ts after PERST#", [Index, reading(AfterPerst)]),
    Sent = erlang:monotonic_time(microsecond),
    Status = Firmware(),
    {notified, Status, erlang:monotonic_time(microsecond) - Sent}.

%% Probe B1's line after the notification; a kept bridge has none.
probed(_Index, none) ->
    ok;
probed(Index, #{status := Status, round_trip_us := RoundTrip, after_notify := AfterNotify}) ->
    logger:notice("pcie: bridge ~b: vl805 firmware ~ts 1 ms after the notification, which answered ~0p in ~b us",
                  [Index, reading(AfterNotify), Status, RoundTrip]).

describe(#{path := Path, turn_off := TurnOff, firmware := AtStart}) ->
    io_lib:format("~p, turn-off ~p, vl805 firmware ~ts at the start", [Path, TurnOff, reading(AtStart)]).

%% A reading of the firmware register as a line shows it.
reading({ok, Word}) -> io_lib:format("0x~8.16.0b", [Word]);
reading({error, Reason}) -> atom_to_list(Reason);
reading(not_read) -> "not read".
