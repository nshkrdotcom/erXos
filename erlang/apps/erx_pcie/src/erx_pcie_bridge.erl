%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_bridge).
-moduledoc """
The bridge seam (docs/design-pcie.md, "The bridge seam"): what a host
bridge driver gives the enumerator. `start` brings the bridge up;
`access` is one configuration access at a place; `ready` lets a bridge
hold back a function its board must start first. The walk, sizing,
placement and the planner reach configuration space through `access`
alone, so a third bridge is one more module.

`access` answers `{error, absent}`, without touching the hardware, for
a place its bridge must not be asked about. Which places those are is
one decision over the bridge's record, reaches/2, which every driver
asks before it touches anything: an open bridge reaches every place on
its bus range; a closed one reaches only its root port, at device 0,
function 0 of its first bus, and the places below it that its platform
record lists, since any other access on the BCM2711's bus locks up the
memory controller (docs/design-pcie.md, "The closed bus"). Neither
reaches a place whose device is past 31 or function past 7.
""".

-export([reaches/2, read_answer/3]).
-export_type([access/0, result/0]).

-doc """
One configuration access at a place: a read or a write of Width bytes at
Offset in its configuration space, aligned to Width.
""".
-type access() :: {read, erx_pcie:place(), Offset :: 0..255, Width :: 1 | 2 | 4}
                | {write, erx_pcie:place(), Offset :: 0..255, Width :: 1 | 2 | 4,
                   Value :: 0..16#ffffffff}.

-doc """
A read's value, a write's `ok`, or `absent` for a place the bridge does
not reach or a function that is not there, or `link_down` when the
bridge's link was down around the access, whose answer is then not taken.
""".
-type result() :: {ok, 0..16#ffffffff} | ok | {error, absent | link_down}.

-callback start(Facts :: erx_abi_layout:erx_pcie_bridge(), Device :: erx_device:device()) ->
    {ok, State :: term()} | {error, Reason :: atom()}.
-callback access(Access :: access(), State :: term()) -> {result(), State :: term()}.
-callback ready(Function :: erx_abi_layout:erx_pcie_function(), State :: term()) ->
    {ok | not_ready, State :: term()}.

-doc """
Whether a driver of the bridge may make an access at the place: for an
open bridge, any place whose bus lies in its range; for a closed one,
only its root port and the places its record lists. A place whose
device is past 31 or function past 7 is none, since its routing ID
would name another function's.
""".
-spec reaches(erx_abi_layout:erx_pcie_bridge(), erx_pcie:place()) -> boolean().
reaches(Bridge, {_Bus, Device, Function} = Place)
  when is_integer(Device), Device >= 0, Device =< 31, is_integer(Function), Function >= 0, Function =< 7 ->
    reaches(erx_pcie:closed(Bridge), Bridge, Place);
reaches(_Bridge, _Place) ->
    false.

reaches(false, #{bus_first := First, bus_last := Last}, {Bus, _Device, _Function}) ->
    First =< Bus andalso Bus =< Last;
reaches(true, #{bus_first := First}, {First, Device, Function}) ->
    Device =:= 0 andalso Function =:= 0;
reaches(true, Bridge, Place) ->
    lists:member(Place, erx_pcie:places(Bridge)).

-doc """
A configuration read's answer from the value read: all ones at offset 0,
a vendor no function has, is `{error, absent}`, since nothing is at the
place; any other value is the read's.
""".
-spec read_answer(0..255, 1 | 2 | 4, 0..16#ffffffff) -> {ok, 0..16#ffffffff} | {error, absent}.
read_answer(0, Width, Value) when Value =:= 1 bsl (8 * Width) - 1 -> {error, absent};
read_answer(_Offset, _Width, Value) -> {ok, Value}.
