%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie).
-moduledoc """
The PCIe domain's records (docs/design-pcie.md, "Records") are the maps
erx_abi_layout decodes from `abi/formats/pcie.txt`'s layouts, field for
field under the declared names: a host bridge as the device service hands
it, `erx_abi_layout:erx_pcie_bridge()`, a function as the domain reports
it, `erx_pcie_function()`, and its setting, `erx_pcie_setting()`. A
record keeps its flags and its unused slots as the layout declares them;
this module reads what a bridge's mean. A place is a function's bus,
device and function; its requester id is derived, never stored.
""".

-export([closed/1, windows/1, inbound/1, places/1]).
-export_type([place/0]).

-doc "A function's bus, device and function.".
-type place() :: {Bus :: 0..255, Device :: 0..31, Function :: 0..7}.

-doc "Whether a host bridge is closed: its driver reaches only its root port and its places.".
-spec closed(erx_abi_layout:erx_pcie_bridge()) -> boolean().
closed(#{flags := Flags}) ->
    lists:member(closed, Flags).

-doc "A host bridge's windows in use; a slot of size 0 is unused.".
-spec windows(erx_abi_layout:erx_pcie_bridge()) -> [erx_abi_layout:erx_pcie_window()].
windows(#{windows := Windows}) ->
    used(Windows).

-doc """
A host bridge's inbound windows in use, from the tree's `dma-ranges`: how
its functions' bus addresses reach memory. A slot of size 0 is unused.
""".
-spec inbound(erx_abi_layout:erx_pcie_bridge()) -> [erx_abi_layout:erx_pcie_window()].
inbound(#{inbound := Inbound}) ->
    used(Inbound).

-doc """
The places below a closed bridge's root port that its record lists; a
slot on bus 0, which lies above every root port, is unused.
""".
-spec places(erx_abi_layout:erx_pcie_bridge()) -> [place()].
places(#{places := Places}) ->
    [{Bus, Device, Function} || #{bus := Bus, device := Device, function := Function} <- Places, Bus =/= 0].

used(Windows) ->
    [Window || #{size := Size} = Window <- Windows, Size > 0].
