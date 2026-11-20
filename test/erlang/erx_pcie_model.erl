%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A model of a host bridge's configuration space for the walk's and the ECAM
%% driver's cases (docs/design-pcie.md, "Host tests of the pure cores"). The model is
%% an ets table holding each present function's 256 bytes and the writable bits of its
%% BAR registers, the buses a root port's applied target has opened, and a log of
%% every access that reached the hardware.
%%
%% It is reached two ways: as an ECAM configuration window (read/3 and write/4 at a
%% window offset, the window() erx_pcie_ecam:open/2 takes), and as a closed bridge
%% driver, the BCM2711's contract over the same model: an access at a place
%% erx_pcie_bridge:reaches/2 refuses answers absent without touching the model, and a
%% model whose link is down answers link_down.
-module(erx_pcie_model).

-behaviour(erx_pcie_bridge).

-export([new/1, open_bus/2, set_link/2, hardware/1, register/3]).
-export([read/3, write/4]).
-export([start/2, access/2, ready/2, closed/2]).

%% Functions: [{Place, Snapshot, #{BarOffset => WritableMask}}]. Bus 0 and the bus
%% first given are open from the start; a root port's bus opens when its target is
%% applied.
new(Functions) ->
    Table = ets:new(model, [public, ordered_set]),
    ets:insert(Table, [{{function, Place}, Snapshot, Masks} || {Place, Snapshot, Masks} <- Functions]),
    ets:insert(Table, [{log, []}, {link, up}, {{open, 0}, true}]),
    Table.

open_bus(Table, Bus) -> ets:insert(Table, {{open, Bus}, true}).

set_link(Table, State) -> ets:insert(Table, {link, State}).

%% Every access that reached the model, oldest first, as {Kind, Place, Offset}.
hardware(Table) -> lists:reverse(ets:lookup_element(Table, log, 2)).

%% The model's register of Width bytes at Offset of a place.
register(Table, Place, {Offset, Width}) ->
    [{_, Bytes, _}] = ets:lookup(Table, {function, Place}),
    <<_:Offset/binary, Value:Width/little-unit:8, _/binary>> = Bytes,
    Value.

%% The ECAM window: the handle is {Table, BusFirst}.
read({Table, First}, At, Width) ->
    model_read(Table, place(First, At), At band 16#fff, Width).

write({Table, First}, At, Width, Value) ->
    model_write(Table, place(First, At), At band 16#fff, Width, Value).

place(First, At) -> {First + (At bsr 20), (At bsr 15) band 31, (At bsr 12) band 7}.

%% The closed bridge driver.
start(_Bridge, _Device) -> {error, unsupported}.

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
%% place with nothing there is dropped.
model_write(Table, Place, Offset, Width, Value) ->
    log(Table, {write, Place, Offset}),
    case present(Table, Place) of
        {Bytes, Masks} ->
            <<Head:Offset/binary, Old:Width/little-unit:8, Tail/binary>> = Bytes,
            Mask = maps:get(Offset, Masks, 1 bsl (8 * Width) - 1),
            New = (Value band Mask) bor (Old band bnot Mask),
            ets:insert(Table, {{function, Place}, <<Head/binary, New:Width/little-unit:8, Tail/binary>>, Masks}),
            ok;
        none ->
            ok
    end.

present(Table, {Bus, _, _} = Place) ->
    case {ets:member(Table, {open, Bus}), ets:lookup(Table, {function, Place})} of
        {true, [{_, Bytes, Masks}]} -> {Bytes, Masks};
        _ -> none
    end.

log(Table, Entry) ->
    ets:insert(Table, {log, [Entry | ets:lookup_element(Table, log, 2)]}).
