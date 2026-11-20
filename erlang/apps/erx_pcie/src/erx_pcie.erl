%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie).
-moduledoc """
The PCIe domain's records as Erlang terms (docs/design-pcie.md,
"Records"): a host bridge as the device service hands it, `bridge()`, and
a function's layout as the domain reports it, `layout()`. Each map has
the fields of its record in `abi/formats/pcie.txt`, under the same names,
with an unused window or place left out rather than zeroed, a flags byte
as booleans and an enum as its atom. A place is a function's bus, device
and function; its requester id is derived, never stored.
""".

-export_type([bridge/0, window/0, closed_place/0, place/0, layout/0, bar/0]).

-doc "A function's bus, device and function.".
-type place() :: {Bus :: 0..255, Device :: 0..31, Function :: 0..7}.

-doc """
One memory or I/O window of a host bridge, from the tree's `ranges`: its
PCI and CPU addresses and its size, never 0.
""".
-type window() :: #{pci := 0..16#ffffffffffffffff,
                    cpu := 0..16#ffffffffffffffff,
                    size := 1..16#ffffffffffffffff,
                    addr64 := boolean(),
                    prefetchable := boolean(),
                    io := boolean()}.

-doc "A place below a closed bridge's root port that its platform record lists, with its pin.".
-type closed_place() :: #{place := place(), pin := 0..4}.

-doc """
A host bridge: its manifest device row, its bus range (the tree's
`bus-range`, or 0 to 255 without one), whether it is closed, its windows
and, for a closed bridge, the places below its root port it reaches.
""".
-type bridge() :: #{index := non_neg_integer(),
                    bus_first := 0..255,
                    bus_last := 0..255,
                    closed := boolean(),
                    windows := [window()],
                    places := [closed_place()]}.

-doc """
One BAR of a layout: its kind, whether it is 64-bit, prefetchable and
placed, its hardware size as a power of two and its PCI address, 0 when
not placed.
""".
-type bar() :: #{kind := erx_abi_enums:pcie_bar_kind(),
                 addr64 := boolean(),
                 prefetchable := boolean(),
                 placed := boolean(),
                 size_log2 := byte(),
                 address := 0..16#ffffffffffffffff}.

-doc """
A function's layout, `erx_pcie_function`: its host bridge's row, its
place, its state, its identity, its header type without the
multifunction bit (any value, since an unsupported type is reported too),
its pin, its six BARs and its capabilities, `none` where absent.
""".
-type layout() :: #{bridge := non_neg_integer(),
                      place := place(),
                      state := erx_abi_enums:pcie_state(),
                      vendor := 0..16#ffff,
                      device_id := 0..16#ffff,
                      class_code := 0..16#ffffff,
                      revision := byte(),
                      header := 0..16#7f,
                      subsystem_vendor := 0..16#ffff,
                      subsystem := 0..16#ffff,
                      pin := 0..4,
                      bars := [bar()],
                      msi := none | #{offset := byte(),
                                      addr64 := boolean(),
                                      vector_mask := boolean(),
                                      vectors_log2 := 0..7},
                      msix := none | #{offset := byte(),
                                       table_size := 1..2048,
                                       table_bar := 0..5,
                                       table_offset := 0..16#fffffff8},
                      express := none | erx_pcie_cfg:express()}.
