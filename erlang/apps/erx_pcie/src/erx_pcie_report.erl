%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_report).
-moduledoc """
The record the PCIe domain reports for each function its walk found
(docs/design-pcie.md, "Records"), an `erx_pcie_function` map of
erx_abi_layout, built from what the walk read. Pure.

A function the walk read whole gets its identity, class, subsystem, pin,
BARs and capabilities from its read value. Each memory BAR that sized
carries its true size, and at a placing walk its address and the
`placed` flag where placement gave it one; a memory BAR that did not size
is one the function does not implement, absent in the record, as an
unimplemented BAR register reads; an I/O BAR is never placed. A function
whose snapshot was refused, or that the walk does not take, carries its
identity alone, its header type as it reads and every BAR absent.

The state is the walk's: `ready` for a function every memory BAR of which
is placed, `unplaced` for one with a BAR that did not fit or too large to
place, `malformed` and `unsupported` as the walk found them; the
enumerator lowers `ready` to `not_ready` where its bridge holds the
function back.
""".

-export([placed/3, read/3, identity/3]).

-include("generated/erx_abi.hrl").

-doc """
The record of a function a placing walk read, with the hardware sizes of
its memory BARs by index and the addresses placement gave them.
""".
-spec placed(non_neg_integer(), erx_pcie_walk:found(), erx_pcie_place:addresses()) ->
          erx_abi_layout:erx_pcie_function().
placed(Bridge, #{place := Place, outcome := {read, Read, Sizes}}, Addresses) ->
    Placed = maps:get(Place, Addresses, #{}),
    Bars = [bar(B, maps:get(I, Sizes, none), maps:get(I, Placed, unplaced)) || #{index := I} = B <- bars(Read)],
    State = case lists:all(fun placed_or_not_memory/1, Bars) of
                true -> ready;
                false -> unplaced
            end,
    record(Bridge, Place, State, Read, Bars).

-doc """
The record of a function read whole but not placed by this walk, in
State: one with a BAR too large to place, with its sizes, or one a later
walk found where its bridge's layouts have none, which no sizing reached.
""".
-spec read(non_neg_integer(), erx_pcie_walk:found(), erx_abi_enums:pcie_state()) ->
          erx_abi_layout:erx_pcie_function().
read(Bridge, #{place := Place, outcome := Outcome}, State) ->
    {Read, Sizes, Unsized} = case Outcome of
                                 {read, R, S} -> {R, S, unsized};
                                 {unplaced, R, S} -> {R, S, none}
                             end,
    Bars = [bar(B, maps:get(I, Sizes, Unsized), unplaced) || #{index := I} = B <- bars(Read)],
    record(Bridge, Place, State, Read, Bars).

-doc "The record of a function the walk refused or does not take, from its identity alone.".
-spec identity(non_neg_integer(), erx_pcie_walk:found(), malformed | unsupported) ->
          erx_abi_layout:erx_pcie_function().
identity(Bridge, #{place := {Bus, Device, Function}, identity := Identity}, State) ->
    #{vendor := Vendor, device_id := DeviceId, class_code := Class, revision := Revision,
      header_type := Header} = Identity,
    (empty(Bridge, {Bus, Device, Function}, State))#{vendor := Vendor, device_id := DeviceId,
                                                    class_code := Class, revision := Revision,
                                                    header := Header}.

%% A BAR of the read value as the record carries it: Size the hardware
%% size as a power of two, none for a memory BAR that did not size, unsized
%% for one a walk that does not size found; Address placement's.
bar(#{kind := absent}, _Size, _Address) ->
    absent_bar();
bar(#{kind := io}, _Size, _Address) ->
    #{kind => io, flags => [], size_log2 => 0, address => 0};
bar(#{kind := memory}, none, _Address) ->
    absent_bar();
bar(#{kind := memory, addr64 := Wide, prefetchable := Prefetch}, Size, Address) ->
    Flags = [addr64 || Wide] ++ [prefetchable || Prefetch],
    Log2 = case Size of
               unsized -> 0;
               _ -> Size
           end,
    case Address of
        {placed, At} -> #{kind => memory, flags => Flags ++ [placed], size_log2 => Log2, address => At};
        unplaced -> #{kind => memory, flags => Flags, size_log2 => Log2, address => 0}
    end.

absent_bar() -> #{kind => absent, flags => [], size_log2 => 0, address => 0}.

placed_or_not_memory(#{kind := memory, flags := Flags}) -> lists:member(placed, Flags);
placed_or_not_memory(_Bar) -> true.

bars(#{bars := Bars}) -> Bars.

record(Bridge, Place, State, Read, Bars) ->
    #{vendor := Vendor, device_id := DeviceId, class_code := Class, revision := Revision, header := Header,
      subsystem_vendor := SubVendor, subsystem := Subsystem, pin := Pin,
      msi := Msi, msix := Msix, express := Express} = Read,
    Record = (empty(Bridge, Place, State))#{vendor := Vendor, device_id := DeviceId, class_code := Class,
                                            revision := Revision, header := header_number(Header),
                                            subsystem_vendor := SubVendor, subsystem := Subsystem,
                                            pin := Pin, bars := Bars},
    express(Express, msix(Msix, msi(Msi, Record))).

msi(none, Record) ->
    Record;
msi(#{offset := At, addr64 := Wide, vector_mask := Mask, vectors_log2 := Vectors}, Record) ->
    Record#{msi_offset := At, msi_flags := [addr64 || Wide] ++ [vector_mask || Mask], msi_vectors := Vectors}.

msix(none, Record) ->
    Record;
msix(#{offset := At, table_size := Size, table_bar := Bar, table_offset := Offset}, Record) ->
    Record#{msix_offset := At, msix_table_size := Size, msix_table_bar := Bar, msix_table_offset := Offset}.

express(none, Record) ->
    Record;
express(#{offset := At, type := Type, flr := Flr}, Record) ->
    Record#{express_offset := At, express_type := Type, express_flags := [flr || Flr]}.

header_number(Header) ->
    {Header, Number} = lists:keyfind(Header, 1, ?ERX_PCIE_HEADER_MEMBERS),
    Number.

empty(Bridge, {Bus, Device, Function}, State) ->
    #{bridge => Bridge, bus => Bus, device => Device, function => Function, state => State,
      vendor => 0, device_id => 0, class_code => 0, revision => 0, header => 0,
      subsystem_vendor => 0, subsystem => 0, pin => 0,
      bars => lists:duplicate(?ERX_PCIE_NORMAL_BARS, absent_bar()),
      msi_offset => 0, msi_flags => [], msi_vectors => 0,
      msix_offset => 0, msix_table_size => 0, msix_table_bar => 0, msix_table_offset => 0,
      express_offset => 0, express_type => 0, express_flags => []}.
