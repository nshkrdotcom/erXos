%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_devices_pci_core).
-moduledoc """
The decisions of the device service's PCIe process (docs/design-pcie.md,
"Facets", "The catalogue and gives", "Concurrency"), pure functions over
what the domain library answers: every host bridge's catalogue,
erx_domain_lib:pci_bridges/0, and the device catalogue,
erx_domain_lib:devices/0, whose `pci` rows carry their place and setting.

**`targets`** answers each bridge's `erx_pcie_bridge` record, the records
of its layouts and every `pci` row's setting by its place, read from the
library alone, so the PCIe domain starts from what the library holds.

**The answer to `report`** hands each bridge the report's records whose
`bridge` is its row (reports/2), so a record naming a bridge the library
does not hold reaches no intake, and lowers to `off` every `pci` row whose
function the catalogue, as the intake left it, does not keep, and every
one the start turned off (lowered/3). The first rule reads the library's
catalogue alone: one with no layout, one its latest report did not list
with its layout (`confirmed`), and one that report did not find `ready`,
so a report the intake refused whole, which leaves every layout of its
bridge unconfirmed, and a function the walk left unreported past
`pcie_functions_max` are lowered whatever the start says it kept. The
second keeps the library's setting the function's own when the start
found it disturbed and turned it off with its record unchanged. A
setting above `off` stays only on a function the library could give now
and the start left at it.
""".

-export([targets/2, reports/2, unlisted/2, lowered/3, settings/1]).
-export_type([place/0]).

-doc "A function by its host bridge's device row and its place, as erx_domain_lib:pci_place() spells it.".
-type place() :: erx_domain_lib:pci_place().

%% A function as the PCIe domain's start reports it, its record and whether
%% the start kept it at its setting; the enumerator owns the type.
-type reported() :: erx_pcie_enumerator:reported().

-doc """
The answer to `targets`: each bridge's record and its layouts' records, in
the library's order, and every `pci` row's setting by its place.
""".
-spec targets([erx_domain_lib:pci_catalogue()], [erx_domain_lib:device()]) ->
          {ok, [erx_abi_layout:erx_pcie_bridge()], [erx_abi_layout:erx_pcie_function()],
           #{place() => erx_abi_layout:erx_pcie_setting()}}.
targets(Catalogues, Devices) ->
    {ok, [Bridge || #{bridge := Bridge} <- Catalogues],
     [Record || #{layouts := Layouts} <- Catalogues, #{record := Record} <- Layouts],
     settings(Devices)}.

-doc """
The report split for the library's intake: each held bridge's row with the
report's records whose `bridge` is that row, in report order, a bridge the
report has none for included, since an empty report leaves its layouts
unconfirmed; and the records naming a bridge the library does not hold,
which no intake takes.
""".
-spec reports([reported()], [erx_domain_lib:pci_catalogue()]) ->
          {[{non_neg_integer(), [erx_abi_layout:erx_pcie_function()]}], Unheld :: [erx_abi_layout:erx_pcie_function()]}.
reports(Reported, Catalogues) ->
    Held = [Index || #{bridge := #{index := Index}} <- Catalogues],
    Records = [Record || #{record := Record} <- Reported],
    {[{Index, [R || #{bridge := B} = R <- Records, B =:= Index]} || Index <- Held],
     [R || #{bridge := B} = R <- Records, not lists:member(B, Held)]}.

-doc "The report's records at a place no `pci` row names, which stay off.".
-spec unlisted([reported()], [erx_domain_lib:device()]) -> [erx_abi_layout:erx_pcie_function()].
unlisted(Reported, Devices) ->
    Places = settings(Devices),
    [Record || #{record := Record} <- Reported, not is_map_key(place(Record), Places)].

-doc """
Every `pci` row to lower, by device row: one whose function the
catalogues do not keep, with no layout at its place, on a bridge marked
`firmware_lost`, or with a layout the latest report did not confirm or did
not find `ready`; and one whose function the start reports it did not keep
at its setting, which it left off.
""".
-spec lowered([erx_domain_lib:pci_catalogue()], [erx_domain_lib:device()], [reported()]) -> [non_neg_integer()].
lowered(Catalogues, Devices, Reported) ->
    Kept = #{place(Record) => kept
             || #{layouts := Layouts, firmware_lost := false} <- Catalogues,
                #{record := Record, confirmed := true, state := ready} <- Layouts},
    Off = #{place(Record) => off || #{record := Record, kept := false} <- Reported},
    [Index || #{index := Index, place := Place} <- Devices, Place =/= none,
              not is_map_key(Place, Kept) orelse is_map_key(Place, Off)].

-doc "Every `pci` row's setting by its place.".
-spec settings([erx_domain_lib:device()]) -> #{place() => erx_abi_layout:erx_pcie_setting()}.
settings(Devices) ->
    #{Place => Setting || #{place := Place, setting := Setting} <- Devices, Place =/= none}.

place(#{bridge := Bridge, bus := Bus, device := Device, function := Function}) ->
    {Bridge, Bus, Device, Function}.
