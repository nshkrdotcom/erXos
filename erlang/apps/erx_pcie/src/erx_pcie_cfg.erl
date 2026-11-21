%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_cfg).
-moduledoc """
The PCIe enumerator's configuration-space parser (docs/design-pcie.md,
"The walk" and "Sizing"): turns a function's 256-byte configuration
space, a snapshot, into its read value, and decodes the answer a BAR
gives to sizing into the BAR's hardware size. Both are pure; the walk
reads the bytes and writes the sizing sequence.

A device writes its configuration space, so a snapshot is untrusted.
Every field is read through one function, read/4, whose binary match
cannot reach past the snapshot's bytes; a field that does not fit
refuses the snapshot naming the field, so a capability whose fields, by
its own control word, extend past offset 255 is refused naming the
capability. The capability list is followed from offset 0x34 only when
the status register's capability bit is set, each pointer with its low
two bits cleared, and the walk refuses a pointer below 0x40 and a list
longer than `pcie_caps_max`, which only a loop makes. It also refuses: a
header type above 1; an interrupt pin above 4; a 64-bit BAR in the last
BAR register; an MSI-X table whose BAR indicator is above 5 or names a
BAR that is not memory (absent, I/O or the upper half of a 64-bit BAR);
an MSI-X table whose offset plus 16 bytes per entry passes 2^32; and a
second MSI, MSI-X or PCI Express capability, where FreeBSD keeps the last
one it reads (sys/dev/pci/pci.c:962-970, :1003, release/15.1.0), so no
value depends on which of two a reader picks. Every refusal leaves
through one throw caught at the public entry.

Each capability's whole structure, as its control word lays it out, must
lie inside the snapshot, through its last register `pcireg.h` gives
(MSI's data or pending bits, MSI-X's pending-bit array, PCI Express's
device status), so every register a later stage reads or writes at its
offset lies inside configuration space's first 256 bytes.

Sizing follows FreeBSD's pci_read_bar and pci_mapsize (pci.c:3154-3228,
:601-614): the size is the lowest set bit of the answer's base bits. It
refuses a memory answer whose base bits are not contiguous from the top,
and a 64-bit BAR whose size needs the high word, which the 32-bit windows
cannot place. An I/O BAR is never placed, so its answer is sized as
FreeBSD sizes every answer, from the lowest set bit alone: one that
decodes 16 address bits, its upper half reading back zero, is sized from
its low 16. An answer with no base bit set is a BAR the function does
not implement. Where FreeBSD differs: it checks no memory BAR's
contiguity; it gives
a memory BAR of type 2 (below 1 MiB) or the reserved type 6 a range of
its own (pci_maprange, pci.c:648-666), where this reads both as 32-bit;
and it ignores an I/O answer with reserved bit 1 set (pci.c:3402), where
this masks the bit off.

Every offset, bit and bound comes from `abi/formats/pcie.txt`.
""".

-export([parse/1, identity/1, size/2, bridge_registers/0]).
-export_type([read/0, identity/0, bar/0, msi/0, msix/0, express/0, bridge/0,
              reason/0, size_reason/0]).

-include("generated/erx_abi.hrl").

-doc """
A BAR register in register order: its kind, whether it is 64-bit or
prefetchable, and its address bits; the upper half of a 64-bit BAR, and a
type-1 header's registers past its second, are `absent`.
""".
-type bar() :: #{index := 0..5,
                 kind := erx_abi_enums:pcie_bar_kind(),
                 addr64 := boolean(),
                 prefetchable := boolean(),
                 address := 0..16#ffffffffffffffff}.

-doc """
An MSI capability: its offset, its control word as it reads, and from it
whether its address is 64-bit and it can mask per vector, the vectors it
can take as a power of two, its enable bit and multiple message enable;
its address and data, and its mask register where `pcireg.h` gives one
(a 64-bit capability with per-vector masking), else `none`.
""".
-type msi() :: #{offset := byte(),
                 control := 0..16#ffff,
                 addr64 := boolean(),
                 vector_mask := boolean(),
                 vectors_log2 := 0..7,
                 enabled := boolean(),
                 mme := 0..7,
                 address := 0..16#ffffffffffffffff,
                 data := 0..16#ffff,
                 mask := none | 0..16#ffffffff}.

-doc """
An MSI-X capability: its offset, its control word as it reads, its
table's entries, BAR and offset in that BAR, and its enable and
function-mask bits.
""".
-type msix() :: #{offset := byte(),
                  control := 0..16#ffff,
                  table_size := 1..2048,
                  table_bar := 0..5,
                  table_offset := 0..16#fffffff8,
                  enabled := boolean(),
                  function_mask := boolean()}.

-doc """
A PCI Express capability: its offset, device type and whether the
function has function-level reset.
""".
-type express() :: #{offset := byte(), type := 0..15, flr := boolean()}.

-doc "A type-1 header's bus numbers, windows and bridge control, each as its register reads.".
-type bridge() :: #{primary_bus := byte(),
                    secondary_bus := byte(),
                    subordinate_bus := byte(),
                    io_base := byte(),
                    io_limit := byte(),
                    memory_base := 0..16#ffff,
                    memory_limit := 0..16#ffff,
                    prefetch_base := 0..16#ffff,
                    prefetch_limit := 0..16#ffff,
                    prefetch_base_upper := 0..16#ffffffff,
                    prefetch_limit_upper := 0..16#ffffffff,
                    io_base_upper := 0..16#ffff,
                    io_limit_upper := 0..16#ffff,
                    bridge_control := 0..16#ffff}.

-doc """
A function's read value: its identity, its command register, its class
code (base class, subclass and programming interface, bits 23 to 0), its
header type and multifunction bit, its interrupt pin, its six BARs, its
capabilities and, for a type-1 header, its bridge registers. A type-1
header has no subsystem identity in its header; both read 0.
""".
-type read() :: #{vendor := 0..16#ffff,
                  device_id := 0..16#ffff,
                  command := 0..16#ffff,
                  class_code := 0..16#ffffff,
                  revision := byte(),
                  header := erx_abi_enums:pcie_header(),
                  multifunction := boolean(),
                  subsystem_vendor := 0..16#ffff,
                  subsystem := 0..16#ffff,
                  pin := 0..4,
                  bars := [bar()],
                  msi := none | msi(),
                  msix := none | msix(),
                  express := none | express(),
                  bridge := none | bridge()}.

-doc """
What every header type holds at the same offsets: the identity, the class
code, the header type without the multifunction bit, and that bit. The
walk reads it before parse/1, which takes only types 0 and 1.
""".
-type identity() :: #{vendor := 0..16#ffff,
                      device_id := 0..16#ffff,
                      class_code := 0..16#ffffff,
                      revision := byte(),
                      header_type := 0..16#7f,
                      multifunction := boolean()}.

-type capability() :: erx_abi_enums:pcie_cap().

-doc "The field a snapshot was refused for.".
-type reason() :: snapshot | header_type | pin | capability_pointer
                | capability_list | capability() | {duplicate, capability()}
                | {bar, 0..5} | msix_table_bar | msix_table_offset.

-doc """
Why a sizing answer was refused: `bar_mask`, base bits not contiguous
from the top, for which the function is reported `malformed`.
""".
-type size_reason() :: {bar_mask, 0..5}.

-doc "The read value of a 256-byte snapshot, or the field it was refused for.".
-spec parse(binary()) -> {ok, read()} | {error, reason()}.
parse(Snapshot) when is_binary(Snapshot) ->
    decoded(fun() -> decode_function(Snapshot) end).

-doc """
The identity of a 256-byte snapshot of any header type, or `snapshot` for
bytes of another length.
""".
-spec identity(binary()) -> {ok, identity()} | {error, snapshot}.
identity(Snapshot) when is_binary(Snapshot) ->
    decoded(fun() -> decode_identity(Snapshot) end).

-doc """
The hardware size, as a power of two, of a BAR of the read value from its
sizing answer: what the BAR register reads after all ones were written,
with a 64-bit BAR's upper register in bits 63 to 32: its true size, up
to `pcie_bar_size_log2_wide`, which may lie past what a window places
(`pcie_bar_size_log2_max`). `absent` for an absent BAR, and for an
answer with no base bit set, a BAR the function does not implement.
""".
-spec size(bar(), 0..16#ffffffffffffffff) ->
          {ok, 2..?ERX_PCIE_BAR_SIZE_LOG2_WIDE} | absent | {error, size_reason()}.
size(#{kind := absent}, _Answer) ->
    absent;
size(#{index := Index, kind := Kind, addr64 := Wide}, Answer) ->
    {Mask, Width} = base(Kind, Wide),
    sized(Index, Answer band Mask, Width).

%% The bits of a BAR register that hold its address, and the register's
%% width in bits for the contiguity check, which an I/O BAR is spared.
base(io, _Wide) -> {?ERX_PCIE_BAR_IO_BASE, spared};
base(memory, false) -> {?ERX_PCIE_BAR_MEM_BASE band 16#ffffffff, 32};
base(memory, true) -> {?ERX_PCIE_BAR_MEM_BASE, 64}.

sized(_Index, 0, _Width) ->
    absent;
sized(Index, Bits, Width) ->
    Lowest = Bits band -Bits,
    Log2 = log2(Lowest),
    case contiguous(Bits, Lowest, Width) of
        false -> {error, {bar_mask, Index}};
        true -> {ok, Log2}
    end.

%% Bits are contiguous from the register's top bit down to Lowest, their
%% lowest set bit, exactly when adding Lowest carries out of the register:
%% Bits + Lowest = 2^Width.
contiguous(_Bits, _Lowest, spared) -> true;
contiguous(Bits, Lowest, Width) -> Bits + Lowest =:= 1 bsl Width.

%% The exponent of a power of two: its digits in base 2, less one.
log2(Power) -> length(integer_to_list(Power, 2)) - 1.

decode_identity(Snapshot) ->
    check(byte_size(Snapshot) =:= ?ERX_PCIE_CONFIG_SIZE, snapshot),
    HeaderType = u8(Snapshot, ?ERX_PCIE_CFG_HEADER),
    #{vendor => u16(Snapshot, ?ERX_PCIE_CFG_VENDOR),
      device_id => u16(Snapshot, ?ERX_PCIE_CFG_DEVICE),
      class_code => read(Snapshot, ?ERX_PCIE_CFG_CLASS_CODE, 3, snapshot),
      revision => u8(Snapshot, ?ERX_PCIE_CFG_REVISION),
      header_type => HeaderType band ?ERX_PCIE_HEADER_TYPE_MASK,
      multifunction => set(HeaderType, ?ERX_PCIE_HEADER_MULTIFUNCTION)}.

decode_function(Snapshot) ->
    #{header_type := HeaderType} = Identity = decode_identity(Snapshot),
    Header = header(HeaderType),
    Pin = u8(Snapshot, ?ERX_PCIE_CFG_PIN),
    check(Pin =< ?ERX_PCIE_PIN_MAX, pin),
    {SubsystemVendor, Subsystem} = subsystem(Snapshot, Header),
    Bars = bars(Snapshot, Header),
    Found = capabilities(Snapshot),
    (maps:remove(header_type, Identity))#{
      command => u16(Snapshot, ?ERX_PCIE_CFG_COMMAND),
      header => Header,
      subsystem_vendor => SubsystemVendor,
      subsystem => Subsystem,
      pin => Pin,
      bars => Bars,
      msi => msi(Snapshot, maps:get(msi, Found, none)),
      msix => msix(Snapshot, maps:get(msix, Found, none), Bars),
      express => express(Snapshot, maps:get(express, Found, none)),
      bridge => bridge(Snapshot, Header)}.

header(Type) ->
    case lists:keyfind(Type, 2, ?ERX_PCIE_HEADER_MEMBERS) of
        {Name, Type} -> Name;
        false -> refuse(header_type)
    end.

subsystem(Snapshot, normal) ->
    {u16(Snapshot, ?ERX_PCIE_CFG_SUBVENDOR), u16(Snapshot, ?ERX_PCIE_CFG_SUBSYSTEM)};
subsystem(_Snapshot, bridge) ->
    {0, 0}.

%% The header's BAR registers decoded in order, then absent entries up to
%% the six a type-0 header holds.
bars(Snapshot, Header) ->
    Count = case Header of
                normal -> ?ERX_PCIE_NORMAL_BARS;
                bridge -> ?ERX_PCIE_BRIDGE_BARS
            end,
    Registers = [read(Snapshot, ?ERX_PCIE_CFG_BARS + 4 * Index, 4, snapshot)
                 || Index <- lists:seq(0, Count - 1)],
    Decoded = bar(0, Registers),
    Decoded ++ [absent(Index) || Index <- lists:seq(Count, ?ERX_PCIE_NORMAL_BARS - 1)].

bar(_Index, []) ->
    [];
bar(Index, [Word | Rest]) when Word band ?ERX_PCIE_BAR_IO_SPACE =/= 0 ->
    [#{index => Index, kind => io, addr64 => false, prefetchable => false,
       address => Word band ?ERX_PCIE_BAR_IO_BASE} | bar(Index + 1, Rest)];
bar(Index, [Word, Upper | Rest])
  when Word band ?ERX_PCIE_BAR_MEM_TYPE_MASK =:= ?ERX_PCIE_BAR_MEM_TYPE_64 ->
    [memory(Index, Upper bsl 32 bor Word, true), absent(Index + 1) | bar(Index + 2, Rest)];
bar(Index, [Word])
  when Word band ?ERX_PCIE_BAR_MEM_TYPE_MASK =:= ?ERX_PCIE_BAR_MEM_TYPE_64 ->
    refuse({bar, Index});
bar(Index, [Word | Rest]) ->
    [memory(Index, Word, false) | bar(Index + 1, Rest)].

memory(Index, Value, Wide) ->
    #{index => Index, kind => memory, addr64 => Wide,
      prefetchable => set(Value, ?ERX_PCIE_BAR_MEM_PREFETCH),
      address => Value band ?ERX_PCIE_BAR_MEM_BASE}.

absent(Index) ->
    #{index => Index, kind => absent, addr64 => false, prefetchable => false, address => 0}.

%% The offsets of the capabilities the parser reads, by name, from a walk
%% of the list bounded by pcie_caps_max steps.
capabilities(Snapshot) ->
    case set(u16(Snapshot, ?ERX_PCIE_CFG_STATUS), ?ERX_PCIE_STATUS_CAPABILITIES) of
        true -> chain(Snapshot, pointer(u8(Snapshot, ?ERX_PCIE_CFG_CAP_PTR)), 0, #{});
        false -> #{}
    end.

chain(_Snapshot, 0, _Steps, Found) ->
    Found;
chain(_Snapshot, _Pointer, Steps, _Found) when Steps >= ?ERX_PCIE_CAPS_MAX ->
    refuse(capability_list);
chain(_Snapshot, Pointer, _Steps, _Found) when Pointer < ?ERX_PCIE_CAP_FIRST ->
    refuse(capability_pointer);
chain(Snapshot, Pointer, Steps, Found) ->
    Next = pointer(u8(Snapshot, Pointer + 1)),
    chain(Snapshot, Next, Steps + 1, found(u8(Snapshot, Pointer), Pointer, Found)).

pointer(Byte) -> Byte band ?ERX_PCIE_CAP_POINTER_MASK.

found(Id, Pointer, Found) ->
    case lists:keyfind(Id, 2, ?ERX_PCIE_CAP_MEMBERS) of
        false ->
            Found;
        {Name, Id} ->
            check(not is_map_key(Name, Found), {duplicate, Name}),
            Found#{Name => Pointer}
    end.

msi(_Snapshot, none) ->
    none;
msi(Snapshot, At) ->
    Control = read(Snapshot, At + ?ERX_PCIE_MSI_CONTROL, 2, msi),
    Wide = set(Control, ?ERX_PCIE_MSI_CONTROL_64BIT),
    VectorMask = set(Control, ?ERX_PCIE_MSI_CONTROL_VECTOR),
    %% pcireg.h gives a 32-bit capability's mask and pending bits no
    %% offsets, so its structure ends at its data.
    fits(At, case {Wide, VectorMask} of
                 {true, true} -> ?ERX_PCIE_MSI_PENDING + 4;
                 {true, false} -> ?ERX_PCIE_MSI_DATA_64BIT + 2;
                 {false, _} -> ?ERX_PCIE_MSI_DATA + 2
             end, msi),
    {Upper, DataAt} =
        case Wide of
            true -> {read(Snapshot, At + ?ERX_PCIE_MSI_ADDRESS_HIGH, 4, msi),
                     At + ?ERX_PCIE_MSI_DATA_64BIT};
            false -> {0, At + ?ERX_PCIE_MSI_DATA}
        end,
    Mask = case Wide andalso VectorMask of
               true -> read(Snapshot, At + ?ERX_PCIE_MSI_MASK, 4, msi);
               false -> none
           end,
    #{offset => At,
      control => Control,
      addr64 => Wide,
      vector_mask => VectorMask,
      vectors_log2 => bits(Control, ?ERX_PCIE_MSI_CONTROL_MMC_MASK),
      enabled => set(Control, ?ERX_PCIE_MSI_CONTROL_ENABLE),
      mme => bits(Control, ?ERX_PCIE_MSI_CONTROL_MME_MASK),
      address => Upper bsl 32 bor read(Snapshot, At + ?ERX_PCIE_MSI_ADDRESS, 4, msi),
      data => read(Snapshot, DataAt, 2, msi),
      mask => Mask}.

msix(_Snapshot, none, _Bars) ->
    none;
msix(Snapshot, At, Bars) ->
    fits(At, ?ERX_PCIE_MSIX_PBA + 4, msix),
    Control = read(Snapshot, At + ?ERX_PCIE_MSIX_CONTROL, 2, msix),
    Table = read(Snapshot, At + ?ERX_PCIE_MSIX_TABLE, 4, msix),
    Indicator = Table band ?ERX_PCIE_MSIX_BIR_MASK,
    Offset = Table band bnot ?ERX_PCIE_MSIX_BIR_MASK,
    Entries = bits(Control, ?ERX_PCIE_MSIX_CONTROL_TABLE_SIZE) + 1,
    check(Indicator < ?ERX_PCIE_NORMAL_BARS
          andalso maps:get(kind, lists:nth(Indicator + 1, Bars)) =:= memory,
          msix_table_bar),
    check(Offset + Entries * ?ERX_PCIE_MSIX_ENTRY_SIZE =< 1 bsl 32,
          msix_table_offset),
    #{offset => At,
      control => Control,
      table_size => Entries,
      table_bar => Indicator,
      table_offset => Offset,
      enabled => set(Control, ?ERX_PCIE_MSIX_CONTROL_ENABLE),
      function_mask => set(Control, ?ERX_PCIE_MSIX_CONTROL_FUNCTION_MASK)}.

express(_Snapshot, none) ->
    none;
express(Snapshot, At) ->
    fits(At, ?ERX_PCIE_EXPRESS_DEVICE_STATUS + 2, express),
    Flags = read(Snapshot, At + ?ERX_PCIE_EXPRESS_FLAGS_WORD, 2, express),
    Capabilities = read(Snapshot, At + ?ERX_PCIE_EXPRESS_DEVICE_CAP, 4, express),
    #{offset => At,
      type => bits(Flags, ?ERX_PCIE_EXPRESS_FLAGS_TYPE),
      flr => set(Capabilities, ?ERX_PCIE_EXPRESS_DEVICE_CAP_FLR)}.

bridge(_Snapshot, normal) ->
    none;
bridge(Snapshot, bridge) ->
    maps:from_list([{Name, read(Snapshot, Offset, Bytes, snapshot)}
                    || {Name, Offset, Bytes} <- bridge_registers()]).

-doc """
A type-1 header's bridge registers as `bridge()` names them, each with
its offset and width in bytes; the planner writes them by the same table.
""".
-spec bridge_registers() -> [{atom(), byte(), 1 | 2 | 4}].
bridge_registers() ->
    [{primary_bus, ?ERX_PCIE_CFG_PRIMARY_BUS, 1},
     {secondary_bus, ?ERX_PCIE_CFG_SECONDARY_BUS, 1},
     {subordinate_bus, ?ERX_PCIE_CFG_SUBORDINATE_BUS, 1},
     {io_base, ?ERX_PCIE_CFG_IO_BASE, 1},
     {io_limit, ?ERX_PCIE_CFG_IO_LIMIT, 1},
     {memory_base, ?ERX_PCIE_CFG_MEMORY_BASE, 2},
     {memory_limit, ?ERX_PCIE_CFG_MEMORY_LIMIT, 2},
     {prefetch_base, ?ERX_PCIE_CFG_PREFETCH_BASE, 2},
     {prefetch_limit, ?ERX_PCIE_CFG_PREFETCH_LIMIT, 2},
     {prefetch_base_upper, ?ERX_PCIE_CFG_PREFETCH_BASE_UPPER, 4},
     {prefetch_limit_upper, ?ERX_PCIE_CFG_PREFETCH_LIMIT_UPPER, 4},
     {io_base_upper, ?ERX_PCIE_CFG_IO_BASE_UPPER, 2},
     {io_limit_upper, ?ERX_PCIE_CFG_IO_LIMIT_UPPER, 2},
     {bridge_control, ?ERX_PCIE_CFG_BRIDGE_CONTROL, 2}].

%% A header field, which lies inside every 256-byte snapshot.
u8(Snapshot, Offset) -> read(Snapshot, Offset, 1, snapshot).
u16(Snapshot, Offset) -> read(Snapshot, Offset, 2, snapshot).

%% The one reader of the snapshot: the little-endian field of Bytes bytes
%% at Offset, or the snapshot refused naming Field when it does not fit.
read(Snapshot, Offset, Bytes, Field) ->
    case Snapshot of
        <<_:Offset/binary, Value:Bytes/little-unit:8, _/binary>> -> Value;
        _ -> refuse(Field)
    end.

%% A capability at At whose structure is Length bytes long lies inside the
%% snapshot, or the snapshot is refused naming the capability.
fits(At, Length, Capability) ->
    check(At + Length =< ?ERX_PCIE_CONFIG_SIZE, Capability).

set(Value, Bit) -> Value band Bit =/= 0.

%% The field Mask selects in Value, shifted down to its lowest bit.
bits(Value, Mask) -> (Value band Mask) div (Mask band -Mask).

-spec decoded(fun(() -> Value)) -> {ok, Value} | {error, reason()}.
decoded(Decode) ->
    try
        {ok, Decode()}
    catch
        throw:{?MODULE, Reason} -> {error, Reason}
    end.

-spec refuse(reason()) -> no_return().
refuse(Reason) -> throw({?MODULE, Reason}).

check(true, _Reason) -> ok;
check(false, Reason) -> refuse(Reason).
