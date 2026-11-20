%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_plan).
-moduledoc """
The PCIe enumerator's planner (docs/design-pcie.md, "The plan"): from a
function's configuration as read, a value of erx_pcie_cfg:parse/1, and
its target, the writes that take it there, in at most three stages, each
with the state it leads to. Pure: erx_pcie_apply makes the writes and
confirms each stage by a readback, with differs/2, before the next.

A **field** is one thing a target decides. A **switch** is a small
ordered level, lowest first: `io`, `memory`, `master` (the command
register's bits), `intx` (0 while the command register's interrupt
disable is set, 1 while it is clear), `msi` (its enable bit) and `msix`
(0 with its enable clear, 1 enabled with its function mask set, 2
enabled with it clear); a capability the function lacks has no switch.
**Data** is the address bits of a BAR register (`{bar, I}`, and
`{bar_high, I}` for a 64-bit BAR's upper register), MSI's multiple
message enable, address, upper address, data and mask register, and a
root port's bus numbers and window registers. A **state** maps each
field the target decides to its value, and `identity` to the function's
structure: its vendor and device, header type, the kind and width of
each BAR its layout implements, and the offset and form of its MSI and
MSI-X. A function reads as a state when it has that identity and every
field reads as the state's value; a read with another identity is
`gone`, so no write is computed against a structure the layout does not
describe.

For an `msi` route MSI's mask register is cleared whole, which unmasks
vector 0, the one message multiple message enable 0 leaves, whichever bit
the specification gives it.

Every write is a whole register, `{Offset, Width, Value}`, computed from
the register as it stands after the writes before it, so bits no field
names (status enables, reserved bits) are written as they read, and a
BAR's read-only type bits as the read value gives them.
""".

-export([plan/2, quiet/1, start_target/2, differs/2]).
-export_type([target/0, layout/0, setting/0, root_port/0, stage/0, state/0, write/0,
              field/0, reason/0]).

-include("generated/erx_abi.hrl").

-doc """
The fields of `erx_pcie_function` the planner reads, by the record's
names: its identity, header type, pin, six BARs (each with its kind, its
flags and its PCI address, 0 when not placed) and its MSI and MSI-X
offsets (0 for none) with MSI's flags.
""".
-type layout() :: #{vendor := 0..16#ffff,
                    device_id := 0..16#ffff,
                    header := byte(),
                    pin := 0..4,
                    bars := [#{kind := erx_abi_enums:pcie_bar_kind(),
                               flags := [addr64 | prefetchable | placed],
                               address := 0..16#ffffffffffffffff,
                               _ => _}],
                    msi_offset := byte(),
                    msi_flags := [addr64 | vector_mask],
                    msix_offset := byte(),
                    _ => _}.

-doc "`erx_pcie_setting`: a mode, a route and the route's one message.".
-type setting() :: #{mode := erx_abi_enums:pcie_mode(),
                     route := erx_abi_enums:pcie_route(),
                     message := #{address := 0..16#ffffffffffffffff, data := 0..16#ffffffff}}.

-doc """
A root port's target (docs/design-pcie.md, "Root ports"): the bus numbers
the walk gave it and its memory window, closed or the PCI addresses of its
first and last byte, 1 MiB granular.
""".
-type root_port() :: #{primary_bus := byte(),
                       secondary_bus := byte(),
                       subordinate_bus := byte(),
                       window := closed | {0..16#ffffffff, 0..16#ffffffff}}.

-type target() :: {function, layout(), setting()} | {root_port, root_port()}.

-type switch() :: io | memory | master | intx | msi | msix.
-type data() :: {bar, 0..5} | {bar_high, 0..4} | msi_mme | msi_address | msi_address_high
              | msi_data | msi_mask | primary_bus | secondary_bus | subordinate_bus
              | memory_base | memory_limit | prefetch_base | prefetch_limit
              | prefetch_base_upper | prefetch_limit_upper
              | io_base | io_limit | io_base_upper | io_limit_upper.
-type field() :: identity | switch() | data().
-type state() :: #{field() => term()}.
-type write() :: {Offset :: byte(), Width :: 1 | 2 | 4, Value :: non_neg_integer()}.
-type stage() :: #{writes := [write(), ...], state := state()}.

-doc """
Why there is no plan: `gone`, the read has another identity than the
target's layout, or a root port's target meets a type-0 header; `route`,
the route does not fit the function (no such capability or pin, or a
message beyond its MSI address or data width); `reset`, the mastering
rule.
""".
-type reason() :: gone | route | reset.

%% The design's orders: the descent lowers bus master first, and the ascent
%% raises each switch to each level in turn, bus master last.
-define(DESCENT, [master, msi, msix, intx, memory, io]).
-define(ASCENT, [{memory, 1}, {msix, 1}, {msi, 1}, {msix, 2}, {intx, 1}, {master, 1}]).

-doc """
The stages that take a function reading as Read to Target, in order; none
when it reads as Target.
""".
-spec plan(erx_pcie_cfg:read(), target()) -> {ok, [stage()]} | {error, reason()}.
plan(Read, Target) ->
    decided(fun() ->
                    Projection = projection(Read, Target),
                    As = read_as(Read, Projection),
                    mastering_rule(Read, Target, As, Projection),
                    stages(Read, As, Projection)
            end).

-doc """
The descent alone: every switch to its lowest, its state quiet with the
read's identity. It needs no layout.
""".
-spec quiet(erx_pcie_cfg:read()) -> {ok, [stage()]}.
quiet(Read) ->
    Identity = identity(Read),
    Quiet = maps:from_list([{identity, Identity} | [{Switch, 0} || Switch <- switches(Identity)]]),
    {ok, stages(Read, read_as(Read, Quiet), Quiet)}.

-doc """
The start's rule: Target when the function reads as it, else the same
target in mode `off`.
""".
-spec start_target(erx_pcie_cfg:read(), {function, layout(), setting()}) ->
          {function, layout(), setting()}.
start_target(Read, {function, Layout, Setting} = Target) ->
    case plan(Read, Target) of
        {ok, []} -> Target;
        _ -> {function, Layout, Setting#{mode := off}}
    end.

-doc """
The first field, in register order, that Read does not read as State
holds: `identity` when Read has another identity, `none` when it reads as
State.
""".
-spec differs(erx_pcie_cfg:read(), state()) -> none | field().
differs(Read, #{identity := Identity} = State) ->
    case identified(Read, Identity) of
        false ->
            identity;
        true ->
            Image = registers(Read),
            Fields = in_register_order(maps:keys(maps:remove(identity, State)), Identity),
            case [Field || Field <- Fields, decode(Field, Identity, Image) =/= maps:get(Field, State)] of
                [] -> none;
                [First | _] -> First
            end
    end.

%% The mastering rule: a target of mode mastering is planned only from a
%% function that reads as the same target at decoding or at mastering.
mastering_rule(Read, {function, Layout, #{mode := mastering} = Setting}, As, Projection) ->
    Decoding = projection(Read, {function, Layout, Setting#{mode := decoding}}),
    check(As =:= Projection orelse As =:= Decoding, reset);
mastering_rule(_Read, _Target, _As, _Projection) ->
    ok.

%% The descent, the data and the ascent, each a stage with the state it
%% leads to; an empty one is left out. As holds what the function reads for
%% each field of the projection.
stages(Read, As, Projection) ->
    Identity = maps:get(identity, Projection),
    Floor = floor(As, Projection),
    Descent = [{Switch, maps:get(Switch, Floor)}
               || Switch <- ?DESCENT, is_map_key(Switch, Floor),
                  maps:get(Switch, Floor) < maps:get(Switch, As)],
    Data = [{Field, maps:get(Field, Projection)}
            || Field <- in_register_order(data_fields(Projection), Identity),
               maps:get(Field, Projection) =/= maps:get(Field, As)],
    Ascent = [{Switch, Level}
              || {Switch, Level} <- ?ASCENT, is_map_key(Switch, Floor),
                 maps:get(Switch, Floor) < Level, Level =< maps:get(Switch, Projection)],
    Planned = [{Descent, maps:merge(As, Floor)},
               {Data, maps:merge(Projection, Floor)},
               {Ascent, Projection}],
    {Stages, _Image} = lists:mapfoldl(fun({Steps, State}, Image) -> stage(Steps, State, Identity, Image) end,
                                      registers(Read), Planned),
    [Stage || #{writes := [_ | _]} = Stage <- Stages].

%% The floor: every switch at its lowest when any data field differs, since
%% data moves only while the function is quiet; otherwise each switch at the
%% lower of what it reads and what the target decides.
floor(As, Projection) ->
    DataDiffers = maps:with(data_fields(Projection), As) =/= maps:with(data_fields(Projection), Projection),
    maps:from_list([{Switch, floor_level(DataDiffers, maps:get(Switch, As), maps:get(Switch, Projection))}
                    || Switch <- switches(maps:get(identity, Projection))]).

floor_level(true, _Read, _Target) -> 0;
floor_level(false, Read, Target) -> min(Read, Target).

%% A stage's writes, each its register as it stands after the writes
%% before it, with the register image they leave.
stage(Steps, State, Identity, Image0) ->
    {Writes, Image} =
        lists:mapfoldl(fun({Field, Value}, Image) ->
                               {Offset, Width, Codec} = field(Field, Identity),
                               Register = encode(Codec, Value, maps:get(Offset, Image)),
                               {{Offset, Width, Register}, Image#{Offset := Register}}
                       end, Image0, Steps),
    {#{writes => Writes, state => State}, Image}.

%% The state a target decides: its identity, its switches and its data.
projection(Read, {function, Layout, Setting}) ->
    Identity = layout_identity(Layout),
    check(identified(Read, Identity), gone),
    check(fits(Identity, Layout, Setting), route),
    maps:merge(function_switches(Identity, Setting),
               maps:from_list([{identity, Identity} | function_data(Identity, Layout, Setting)]));
projection(Read, {root_port, Port}) ->
    Identity = identity(Read),
    check(maps:get(header, Identity) =:= bridge, gone),
    maps:merge(root_port_switches(Identity, Port),
               maps:from_list([{identity, Identity} | root_port_data(Port)])).

%% The design's table of a function's switches by mode; a capability the
%% route does not use is disabled in every mode.
function_switches(Identity, #{mode := Mode, route := Route}) ->
    Mastering = Mode =:= mastering,
    present(Identity, #{io => 0,
                        memory => level(Mode =/= off),
                        master => level(Mastering),
                        intx => level(Mastering andalso Route =:= intx),
                        msi => level(Mastering andalso Route =:= msi),
                        msix => case Route of
                                    msix -> msix_level(Mode);
                                    _ -> 0
                                end}).

msix_level(off) -> 0;
msix_level(decoding) -> 1;
msix_level(mastering) -> 2.

%% Each BAR's address from the layout; for an msi route, MSI's message.
function_data(Identity, #{bars := Bars}, Setting) ->
    lists:flatmap(fun layout_bar/1, lists:zip(lists:seq(0, length(Bars) - 1), Bars))
        ++ msi_data(Identity, Setting).

layout_bar({_Index, #{kind := absent}}) ->
    [];
layout_bar({Index, #{kind := io, address := Address}}) ->
    [{{bar, Index}, Address band ?ERX_PCIE_BAR_IO_BASE}];
layout_bar({Index, #{kind := memory, flags := Flags, address := Address}}) ->
    [{{bar, Index}, Address band ?ERX_PCIE_BAR_MEM_BASE band 16#ffffffff}
     | [{{bar_high, Index}, Address bsr 32} || lists:member(addr64, Flags)]].

msi_data(#{msi := {_At, Wide, VectorMask}},
         #{route := msi, message := #{address := Address, data := Data}}) ->
    [{msi_mme, 0}, {msi_address, Address band 16#ffffffff}, {msi_data, Data}]
        ++ [{msi_address_high, Address bsr 32} || Wide]
        ++ [{msi_mask, 0} || Wide andalso VectorMask];
msi_data(_Identity, _Setting) ->
    [].

%% A route fits when the function has its mechanism and, for msi, MSI can
%% hold its message.
fits(_Identity, _Layout, #{route := none}) -> true;
fits(#{msi := none}, _Layout, #{route := msi}) -> false;
fits(#{msi := {_At, Wide, _VectorMask}}, _Layout,
     #{route := msi, message := #{address := Address, data := Data}}) ->
    (Wide orelse Address bsr 32 =:= 0) andalso Data bsr 16 =:= 0;
fits(#{msix := Msix}, _Layout, #{route := msix}) -> Msix =/= none;
fits(_Identity, #{pin := Pin}, #{route := intx}) -> Pin =/= 0.

%% A root port forwards and masters for the functions below it exactly
%% when its window is open, and raises no interrupt of its own.
root_port_switches(Identity, #{window := Window}) ->
    Open = level(Window =/= closed),
    present(Identity, #{io => 0, memory => Open, master => Open, intx => 0, msi => 0, msix => 0}).

%% Its bus numbers and memory window, its prefetchable and I/O windows
%% closed: a closed window's base holds every address bit and its limit none.
root_port_data(#{primary_bus := Primary, secondary_bus := Secondary,
                 subordinate_bus := Subordinate, window := Window}) ->
    {MemoryBase, MemoryLimit} = memory_window(Window),
    [{primary_bus, Primary}, {secondary_bus, Secondary}, {subordinate_bus, Subordinate},
     {memory_base, MemoryBase}, {memory_limit, MemoryLimit},
     {prefetch_base, ?ERX_PCIE_BRIDGE_MEMORY_WINDOW_MASK}, {prefetch_limit, 0},
     {prefetch_base_upper, 0}, {prefetch_limit_upper, 0},
     {io_base, ?ERX_PCIE_BRIDGE_IO_WINDOW_MASK}, {io_limit, 0},
     {io_base_upper, 0}, {io_limit_upper, 0}].

memory_window(closed) ->
    {?ERX_PCIE_BRIDGE_MEMORY_WINDOW_MASK, 0};
memory_window({First, Last}) ->
    {(First bsr ?ERX_PCIE_BRIDGE_MEMORY_WINDOW_SHIFT) band ?ERX_PCIE_BRIDGE_MEMORY_WINDOW_MASK,
     (Last bsr ?ERX_PCIE_BRIDGE_MEMORY_WINDOW_SHIFT) band ?ERX_PCIE_BRIDGE_MEMORY_WINDOW_MASK}.

%% A function's structure, as its layout records it and as a read gives it.
%% A layout's BARs count only where it implements one, since an
%% unimplemented BAR register reads as an empty 32-bit memory BAR.
layout_identity(#{vendor := Vendor, device_id := Device, header := Header, bars := Bars,
                  msi_offset := MsiAt, msi_flags := MsiFlags, msix_offset := MsixAt}) ->
    #{vendor => Vendor,
      device_id => Device,
      header => header_name(Header),
      bars => maps:from_list([{Index, {Kind, lists:member(addr64, Flags)}}
                              || {Index, #{kind := Kind, flags := Flags}}
                                     <- lists:zip(lists:seq(0, length(Bars) - 1), Bars),
                                 Kind =/= absent]),
      msi => case MsiAt of
                 0 -> none;
                 _ -> {MsiAt, lists:member(addr64, MsiFlags), lists:member(vector_mask, MsiFlags)}
             end,
      msix => case MsixAt of
                  0 -> none;
                  _ -> MsixAt
              end}.

identity(#{vendor := Vendor, device_id := Device, header := Header, bars := Bars,
           msi := Msi, msix := Msix}) ->
    #{vendor => Vendor,
      device_id => Device,
      header => Header,
      bars => maps:from_list([{Index, {Kind, Wide}}
                              || #{index := Index, kind := Kind, addr64 := Wide} <- Bars,
                                 Kind =/= absent]),
      msi => case Msi of
                 none -> none;
                 #{offset := At, addr64 := Wide, vector_mask := VectorMask} -> {At, Wide, VectorMask}
             end,
      msix => case Msix of
                  none -> none;
                  #{offset := At} -> At
              end}.

header_name(Header) ->
    case lists:keyfind(Header, 2, ?ERX_PCIE_HEADER_MEMBERS) of
        {Name, Header} -> Name;
        false -> Header
    end.

%% Read has Identity: the same vendor, device, header and capabilities, and
%% each BAR Identity implements of the same kind and width.
identified(Read, Identity) ->
    Own = identity(Read),
    maps:without([bars], Own) =:= maps:without([bars], Identity)
        andalso maps:with(maps:keys(maps:get(bars, Identity)), maps:get(bars, Own))
                    =:= maps:get(bars, Identity).

%% The value each field of State reads as in Read, which has State's identity.
read_as(Read, #{identity := Identity} = State) ->
    Image = registers(Read),
    maps:map(fun(identity, _Value) -> Identity;
                (Field, _Value) -> decode(Field, Identity, Image)
             end, State).

%% Every register a field may name, by offset, as Read gives it.
registers(#{command := Command, bars := Bars, msi := Msi, msix := Msix, bridge := Bridge}) ->
    maps:from_list([{?ERX_PCIE_CFG_COMMAND, Command}]
                   ++ lists:flatmap(fun bar_registers/1, Bars)
                   ++ msi_registers(Msi)
                   ++ msix_registers(Msix)
                   ++ bridge_registers(Bridge)).

%% A BAR's register rebuilt from the read value: its address bits, and the
%% type bits the read value keeps (I/O space, 64-bit, prefetchable). A
%% memory BAR's type 2 or 6 bit and an I/O BAR's reserved bit, which the
%% parser drops, are written 0; both are read-only.
bar_registers(#{kind := absent}) ->
    [];
bar_registers(#{index := Index, kind := io, address := Address}) ->
    [{bar_offset(Index), Address bor ?ERX_PCIE_BAR_IO_SPACE}];
bar_registers(#{index := Index, kind := memory, addr64 := false, prefetchable := Prefetch,
                address := Address}) ->
    [{bar_offset(Index), Address bor prefetch(Prefetch)}];
bar_registers(#{index := Index, kind := memory, addr64 := true, prefetchable := Prefetch,
                address := Address}) ->
    [{bar_offset(Index), (Address band 16#ffffffff) bor ?ERX_PCIE_BAR_MEM_TYPE_64 bor prefetch(Prefetch)},
     {bar_offset(Index + 1), Address bsr 32}].

prefetch(true) -> ?ERX_PCIE_BAR_MEM_PREFETCH;
prefetch(false) -> 0.

msi_registers(none) ->
    [];
msi_registers(#{offset := At, control := Control, addr64 := Wide, address := Address,
                data := Data, mask := Mask}) ->
    [{At + ?ERX_PCIE_MSI_CONTROL, Control},
     {At + ?ERX_PCIE_MSI_ADDRESS, Address band 16#ffffffff},
     {At + msi_data_offset(Wide), Data}]
        ++ [{At + ?ERX_PCIE_MSI_ADDRESS_HIGH, Address bsr 32} || Wide]
        ++ [{At + ?ERX_PCIE_MSI_MASK, Mask} || Mask =/= none].

msix_registers(none) ->
    [];
msix_registers(#{offset := At, control := Control}) ->
    [{At + ?ERX_PCIE_MSIX_CONTROL, Control}].

bridge_registers(none) ->
    [];
bridge_registers(Bridge) ->
    [{Offset, maps:get(Name, Bridge)} || {Name, Offset, _Bytes} <- erx_pcie_cfg:bridge_registers()].

%% Where a field lies, {Offset, Width, Codec}, in a function of Identity.
field(Switch, _Identity) when Switch =:= io; Switch =:= memory; Switch =:= master; Switch =:= intx ->
    {?ERX_PCIE_CFG_COMMAND, 2, command_codec(Switch)};
field(msi, #{msi := {At, _Wide, _VectorMask}}) ->
    {At + ?ERX_PCIE_MSI_CONTROL, 2, {flag, ?ERX_PCIE_MSI_CONTROL_ENABLE, 1}};
field(msix, #{msix := At}) ->
    {At + ?ERX_PCIE_MSIX_CONTROL, 2, msix};
field({bar, Index}, #{bars := Bars}) ->
    Mask = case maps:get(Index, Bars) of
               {io, _Wide} -> ?ERX_PCIE_BAR_IO_BASE;
               {memory, _Wide} -> ?ERX_PCIE_BAR_MEM_BASE band 16#ffffffff
           end,
    {bar_offset(Index), 4, {bits, Mask}};
field({bar_high, Index}, _Identity) ->
    {bar_offset(Index + 1), 4, {bits, 16#ffffffff}};
field(msi_mme, #{msi := {At, _Wide, _VectorMask}}) ->
    {At + ?ERX_PCIE_MSI_CONTROL, 2, {bits, ?ERX_PCIE_MSI_CONTROL_MME_MASK}};
field(msi_address, #{msi := {At, _Wide, _VectorMask}}) ->
    {At + ?ERX_PCIE_MSI_ADDRESS, 4, {bits, 16#ffffffff}};
field(msi_address_high, #{msi := {At, _Wide, _VectorMask}}) ->
    {At + ?ERX_PCIE_MSI_ADDRESS_HIGH, 4, {bits, 16#ffffffff}};
field(msi_data, #{msi := {At, Wide, _VectorMask}}) ->
    {At + msi_data_offset(Wide), 2, {bits, 16#ffff}};
field(msi_mask, #{msi := {At, _Wide, _VectorMask}}) ->
    {At + ?ERX_PCIE_MSI_MASK, 4, {bits, 16#ffffffff}};
field(Name, _Identity) ->
    {Name, Offset, Bytes} = lists:keyfind(Name, 1, erx_pcie_cfg:bridge_registers()),
    {Offset, Bytes, {bits, bridge_mask(Name, Bytes)}}.

command_codec(io) -> {flag, ?ERX_PCIE_COMMAND_IO, 1};
command_codec(memory) -> {flag, ?ERX_PCIE_COMMAND_MEMORY, 1};
command_codec(master) -> {flag, ?ERX_PCIE_COMMAND_MASTER, 1};
command_codec(intx) -> {flag, ?ERX_PCIE_COMMAND_INTX_DISABLE, 0}.

%% A window register's address bits; every bit of a bus number or an upper
%% half.
bridge_mask(Name, _Bytes) when Name =:= io_base; Name =:= io_limit ->
    ?ERX_PCIE_BRIDGE_IO_WINDOW_MASK;
bridge_mask(Name, _Bytes) when Name =:= memory_base; Name =:= memory_limit;
                               Name =:= prefetch_base; Name =:= prefetch_limit ->
    ?ERX_PCIE_BRIDGE_MEMORY_WINDOW_MASK;
bridge_mask(_Name, Bytes) ->
    (1 bsl (8 * Bytes)) - 1.

bar_offset(Index) -> ?ERX_PCIE_CFG_BARS + 4 * Index.

msi_data_offset(true) -> ?ERX_PCIE_MSI_DATA_64BIT;
msi_data_offset(false) -> ?ERX_PCIE_MSI_DATA.

%% A field's value in its register, and its register with the value written.
%% A flag is level Set while its bit is set; MSI-X's three levels are its
%% enable and function-mask bits, disabled whatever its mask reads.
decode(Field, Identity, Image) ->
    {Offset, _Width, Codec} = field(Field, Identity),
    value(Codec, maps:get(Offset, Image)).

value({flag, Bit, Set}, Register) when Register band Bit =/= 0 -> Set;
value({flag, _Bit, Set}, _Register) -> 1 - Set;
value(msix, Register) when Register band ?ERX_PCIE_MSIX_CONTROL_ENABLE =:= 0 -> 0;
value(msix, Register) when Register band ?ERX_PCIE_MSIX_CONTROL_FUNCTION_MASK =/= 0 -> 1;
value(msix, _Register) -> 2;
value({bits, Mask}, Register) -> Register band Mask.

encode({flag, Bit, SetLevel}, Level, Register) when Level =:= SetLevel -> Register bor Bit;
encode({flag, Bit, _SetLevel}, _Level, Register) -> Register band bnot Bit;
encode(msix, 0, Register) ->
    Register band bnot ?ERX_PCIE_MSIX_CONTROL_ENABLE;
encode(msix, 1, Register) ->
    Register bor ?ERX_PCIE_MSIX_CONTROL_ENABLE bor ?ERX_PCIE_MSIX_CONTROL_FUNCTION_MASK;
encode(msix, 2, Register) ->
    (Register bor ?ERX_PCIE_MSIX_CONTROL_ENABLE) band bnot ?ERX_PCIE_MSIX_CONTROL_FUNCTION_MASK;
encode({bits, Mask}, Value, Register) ->
    (Register band bnot Mask) bor (Value band Mask).

%% Fields by the offset of their register, a 64-bit BAR's low word first.
in_register_order(Fields, Identity) ->
    [Field || {_Offset, Field} <- lists:sort([{element(1, field(Field, Identity)), Field} || Field <- Fields])].

%% The switches a function of Identity has: MSI and MSI-X only where it has
%% the capability.
switches(Identity) ->
    [Switch || Switch <- [io, memory, master, intx, msi, msix], has_switch(Switch, Identity)].

has_switch(msi, #{msi := Msi}) -> Msi =/= none;
has_switch(msix, #{msix := Msix}) -> Msix =/= none;
has_switch(_Switch, _Identity) -> true.

present(Identity, Switches) ->
    maps:with(switches(Identity), Switches).

data_fields(State) ->
    maps:keys(maps:without([identity | switches(maps:get(identity, State))], State)).

level(true) -> 1;
level(false) -> 0.

-spec decided(fun(() -> [stage()])) -> {ok, [stage()]} | {error, reason()}.
decided(Plan) ->
    try
        {ok, Plan()}
    catch
        throw:{?MODULE, Reason} -> {error, Reason}
    end.

check(true, _Reason) -> ok;
check(false, Reason) -> throw({?MODULE, Reason}).
