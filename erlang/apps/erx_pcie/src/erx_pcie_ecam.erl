%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_ecam).
-moduledoc """
The ECAM bridge driver (docs/design-pcie.md, "The bridge seam"), for a
host bridge whose configuration space is one memory window, peripheral
`pci_ecam`. Its bring-up does nothing. An access at a place the bridge
does not reach, a bus outside its bus range, answers `{error, absent}`
without touching the window; any other is made at

    (bus - bus_first) << 20 | device << 15 | function << 12 | offset

in the window, as FreeBSD's generic_pcie_read_config lays it out, and a
read of all ones at offset 0, which no present function's vendor reads,
answers `{error, absent}`. Its `ready` is always `ok`; an ECAM bridge
holds no function back.

The window is reached through a `space()`: a module with `read/3` and
`write/4` at a byte offset of the window and a handle it takes. The
device NIF reaches a device only by register name, from its
peripheral's SVD source, and has no access at a computed offset, so
start/2 answers `{error, unsupported}` and open/2 makes the driver's
state over any `space()`, such as the model of configuration space its
tests use (TODO.md).
""".

-behaviour(erx_pcie_bridge).

-export([start/2, open/2, access/2, ready/2]).
-export_type([space/0, state/0]).

-doc """
A configuration window: `Module:read(Handle, Offset, Width)` answers the
value of Width bytes at Offset of the window, and
`Module:write(Handle, Offset, Width, Value)` stores them, each one
volatile access of that width.
""".
-type space() :: {Module :: module(), Handle :: term()}.

-opaque state() :: {ecam, erx_abi_layout:erx_pcie_bridge(), space()}.

-doc """
The bridge's state over its device's configuration window: unsupported,
since the device NIF has no access at a computed offset.
""".
-spec start(erx_abi_layout:erx_pcie_bridge(), erx_device:device()) -> {error, unsupported}.
start(_Bridge, _Device) ->
    {error, unsupported}.

-doc "The bridge's state over a configuration window reached as a `space()`.".
-spec open(erx_abi_layout:erx_pcie_bridge(), space()) -> {ok, state()}.
open(Bridge, {Module, _Handle} = Space) when is_atom(Module) ->
    {ok, {ecam, Bridge, Space}}.

-doc """
One configuration access, or `{error, absent}` for a bus outside the
bridge's range or a read of all ones at offset 0.
""".
-spec access(erx_pcie_bridge:access(), state()) -> {erx_pcie_bridge:result(), state()}.
access(Access, {ecam, Bridge, Space} = State) ->
    {make(Access, Bridge, Space), State}.

-doc "Always `ok`: an ECAM bridge holds no function back.".
-spec ready(erx_abi_layout:erx_pcie_function(), state()) -> {ok, state()}.
ready(_Function, State) ->
    {ok, State}.

make({read, Place, Offset, Width}, Bridge, {Module, Handle}) when Offset rem Width =:= 0 ->
    case function_base(Bridge, Place) of
        unreached -> {error, absent};
        Base -> read_answer(Offset, Width, Module:read(Handle, Base + Offset, Width))
    end;
make({write, Place, Offset, Width, Value}, Bridge, {Module, Handle}) when Offset rem Width =:= 0 ->
    case function_base(Bridge, Place) of
        unreached -> {error, absent};
        Base -> ok = Module:write(Handle, Base + Offset, Width, Value)
    end.

%% A read of all ones at offset 0 is a vendor no function has: nothing is
%% at the place.
read_answer(0, Width, Value) when Value =:= 1 bsl (8 * Width) - 1 -> {error, absent};
read_answer(_Offset, _Width, Value) -> {ok, Value}.

%% Where the place's 4 KiB of configuration space starts in the window, or
%% `unreached` for a place the bridge does not reach.
function_base(#{bus_first := First} = Bridge, {Bus, Device, Function} = Place) ->
    case erx_pcie_bridge:reaches(Bridge, Place) of
        true -> ((Bus - First) bsl 20) bor (Device bsl 15) bor (Function bsl 12);
        false -> unreached
    end.
