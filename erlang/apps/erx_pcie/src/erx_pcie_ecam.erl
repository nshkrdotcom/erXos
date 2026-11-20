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

The window is the device's configuration space `function`
(hw/svd/pci_ecam/pci_ecam.svd): one block of 4 KiB for each routing ID,
`(bus - bus_first) << 8 | device << 3 | function`, so the block's
offset in the window is the layout above, and the device NIF makes each
access inside its block. A place whose block lies past the window, a
bus the tree's `bus-range` names but its `reg` does not cover, answers
`{error, absent}` too, before the device NIF is asked.

start/2 reaches the window through erx_device; open/2 takes any module
of that shape (elements/2, config_read/4 and config_write/5), as the
model of configuration space the host tests use, which cannot load the
device NIF.
""".

-behaviour(erx_pcie_bridge).

-export([start/2, open/2, access/2, ready/2]).
-export_type([space/0, state/0]).

-doc """
A configuration window in erx_device's shape: `Module:elements(Handle,
function)` is how many blocks of the window's `function` space it
holds, `Module:config_read(Handle, {function, Routing}, Offset, Width)`
the value of Width bytes at Offset of a block, and
`Module:config_write(Handle, {function, Routing}, Offset, Width, Value)`
stores them, each one access of that width.
""".
-type space() :: {Module :: module(), Handle :: term()}.

%% The bridge's record, its window, and how many blocks of the window's space it holds.
-opaque state() :: {ecam, erx_abi_layout:erx_pcie_bridge(), space(), Blocks :: non_neg_integer()}.

-doc "The bridge's state over its device's configuration window. Bring-up does nothing.".
-spec start(erx_abi_layout:erx_pcie_bridge(), erx_device:device()) -> {ok, state()}.
start(Bridge, Device) ->
    open(Bridge, {erx_device, Device}).

-doc "The bridge's state over a configuration window reached as a `space()`.".
-spec open(erx_abi_layout:erx_pcie_bridge(), space()) -> {ok, state()}.
open(Bridge, {Module, Handle} = Space) when is_atom(Module) ->
    {ok, {ecam, Bridge, Space, Module:elements(Handle, function)}}.

-doc """
One configuration access, or `{error, absent}` for a bus outside the
bridge's range or past its window, or a read of all ones at offset 0.
""".
-spec access(erx_pcie_bridge:access(), state()) -> {erx_pcie_bridge:result(), state()}.
access(Access, {ecam, Bridge, Space, Blocks} = State) ->
    {make(Access, block(Bridge, Blocks, element(2, Access)), Space), State}.

-doc "Always `ok`: an ECAM bridge holds no function back.".
-spec ready(erx_abi_layout:erx_pcie_function(), state()) -> {ok, state()}.
ready(_Function, State) ->
    {ok, State}.

make(_Access, unreached, _Space) ->
    {error, absent};
make({read, _Place, Offset, Width}, Block, {Module, Handle}) when Offset rem Width =:= 0 ->
    erx_pcie_bridge:read_answer(Offset, Width, Module:config_read(Handle, Block, Offset, Width));
make({write, _Place, Offset, Width, Value}, Block, {Module, Handle}) when Offset rem Width =:= 0 ->
    ok = Module:config_write(Handle, Block, Offset, Width, Value).

%% The place's block of the window's space, its routing ID from the bridge's first bus,
%% or `unreached` for a place the bridge does not reach or the window does not hold.
block(#{bus_first := First} = Bridge, Blocks, {Bus, Device, Function} = Place) ->
    Routing = ((Bus - First) bsl 8) bor (Device bsl 3) bor Function,
    case erx_pcie_bridge:reaches(Bridge, Place) andalso Routing < Blocks of
        true -> {function, Routing};
        false -> unreached
    end.
