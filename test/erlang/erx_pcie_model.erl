%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A model of a host bridge's configuration space for the walk's and the ECAM
%% driver's cases (docs/design-pcie.md, "Host tests of the pure cores"). The model is
%% an ets table holding each present function's 256 bytes and the writable bits of its
%% BAR registers, the buses a root port's applied target has opened, a log of every
%% access that reached the hardware, and the rule by which it ignores writes, if any.
%%
%% It is reached two ways: as an ECAM configuration window in the device NIF's shape
%% (elements/2, config_read/4 and config_write/5 over pci_ecam's `function` space, the
%% space() erx_pcie_ecam:open/2 takes), and as a closed bridge
%% driver, the BCM2711's contract over the same model: an access at a place
%% erx_pcie_bridge:reaches/2 refuses answers absent without touching the model, and a
%% model whose link is down answers link_down.
-module(erx_pcie_model).

-behaviour(erx_pcie_bridge).

-export([new/1, open_bus/2, set_link/2, ignore/2, hardware/1, register/3, snapshot/2]).
-export([elements/2, config_read/4, config_write/5]).
-export([start/3, access/2, ready/2, closed/2]).

%% Functions: [{Place, Snapshot, #{BarOffset => WritableMask}}]. Bus 0 and the bus
%% first given are open from the start; a root port's bus opens when its target is
%% applied.
new(Functions) ->
    Table = ets:new(model, [public, ordered_set]),
    ets:insert(Table, [{{function, Place}, Snapshot, Masks} || {Place, Snapshot, Masks} <- Functions]),
    ets:insert(Table, [{accesses, 0}, {writes, 0}, {ignore, none}, {link, up}, {{open, 0}, true}]),
    Table.

open_bus(Table, Bus) -> ets:insert(Table, {{open, Bus}, true}).

set_link(Table, State) -> ets:insert(Table, {link, State}).

%% Writes that do not take, counting every write that reaches the model from 1:
%% {once, N} drops write N alone, so a later write of its register takes; {from, N}
%% makes the register write N names, its place and offset, ignore that write and every
%% later one.
ignore(Table, Rule) -> ets:insert(Table, {ignore, Rule}).

%% Every access that reached the model, oldest first, as {Kind, Place, Offset}.
hardware(Table) -> [Entry || [Entry] <- ets:match(Table, {{log, '_'}, '$1'})].

%% The model's register of Width bytes at Offset of a place.
register(Table, Place, {Offset, Width}) ->
    [{_, Bytes, _}] = ets:lookup(Table, {function, Place}),
    <<_:Offset/binary, Value:Width/little-unit:8, _/binary>> = Bytes,
    Value.

%% The 256 bytes of a place's function.
snapshot(Table, Place) -> ets:lookup_element(Table, {function, Place}, 2).

%% The ECAM window: the handle is {Table, BusFirst}, or {Table, BusFirst, Buses} for a
%% window that covers only Buses buses, as a tree's reg may; a block past it is badarg, as
%% the device NIF's is.
elements({Table, First}, function) -> elements({Table, First, 256}, function);
elements({_Table, _First, Buses}, function) -> Buses * 256.

config_read(Handle, {function, Routing}, Offset, Width) ->
    {Table, First} = window(Handle, Routing),
    model_read(Table, place(First, Routing), Offset, Width).

config_write(Handle, {function, Routing}, Offset, Width, Value) ->
    {Table, First} = window(Handle, Routing),
    model_write(Table, place(First, Routing), Offset, Width, Value).

window(Handle, Routing) ->
    Routing < elements(Handle, function) orelse error(badarg),
    {element(1, Handle), element(2, Handle)}.

place(First, Routing) -> {First + (Routing bsr 8), (Routing bsr 3) band 31, Routing band 7}.

%% The closed bridge driver.
start(_Bridge, _Device, _Effects) -> {error, unsupported}.

closed(Bridge, Table) -> {ok, {Bridge, Table}}.

access(Access, {Bridge, Table} = State) ->
    Place = element(2, Access),
    Answer = case {erx_pcie_bridge:reaches(Bridge, Place), ets:lookup_element(Table, link, 2)} of
                 {false, _} -> {error, absent};
                 {true, down} -> {error, link_down};
                 {true, up} -> closed_access(Table, Access)
             end,
    {Answer, State}.

ready(_Function, State) -> {ok, State}.

closed_access(Table, {read, Place, 0, Width}) ->
    case model_read(Table, Place, 0, Width) of
        Ones when Ones =:= 1 bsl (8 * Width) - 1 -> {error, absent};
        Value -> {ok, Value}
    end;
closed_access(Table, {read, Place, Offset, Width}) ->
    {ok, model_read(Table, Place, Offset, Width)};
closed_access(Table, {write, Place, Offset, Width, Value}) ->
    model_write(Table, Place, Offset, Width, Value).

%% A read of a place with no function, or on a bus no root port opened, reads all ones.
model_read(Table, Place, Offset, Width) ->
    log(Table, {read, Place, Offset}),
    case present(Table, Place) of
        {Bytes, _Masks} ->
            <<_:Offset/binary, Value:Width/little-unit:8, _/binary>> = Bytes,
            Value;
        none ->
            1 bsl (8 * Width) - 1
    end.

%% A write stores its bytes, but only a BAR register's writable bits; a write to a
%% place with nothing there, or one the ignore rule names, is dropped.
model_write(Table, Place, Offset, Width, Value) ->
    log(Table, {write, Place, Offset}),
    Ignored = ignored(Table, ets:update_counter(Table, writes, 1), {Place, Offset}),
    case present(Table, Place) of
        {Bytes, Masks} when not Ignored ->
            <<Head:Offset/binary, Old:Width/little-unit:8, Tail/binary>> = Bytes,
            Mask = maps:get(Offset, Masks, 1 bsl (8 * Width) - 1),
            New = (Value band Mask) bor (Old band bnot Mask),
            ets:insert(Table, {{function, Place}, <<Head/binary, New:Width/little-unit:8, Tail/binary>>, Masks}),
            ok;
        _ ->
            ok
    end.

ignored(Table, Count, Register) ->
    case ets:lookup_element(Table, ignore, 2) of
        {once, N} -> N =:= Count;
        {from, Count} -> ets:insert(Table, {ignore, {register, Register}});
        {register, Deaf} -> Deaf =:= Register;
        _ -> false
    end.

present(Table, {Bus, _, _} = Place) ->
    case {ets:member(Table, {open, Bus}), ets:lookup(Table, {function, Place})} of
        {true, [{_, Bytes, Masks}]} -> {Bytes, Masks};
        _ -> none
    end.

log(Table, Entry) ->
    ets:insert(Table, {{log, ets:update_counter(Table, accesses, 1)}, Entry}).
