%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_place).
-moduledoc """
Placement (docs/design-pcie.md, "Placement"): the PCI addresses of a
placing walk's memory BARs inside the host bridge's window, as a pure
function of the bridge's windows and what the walk found.

Every memory BAR goes in the bridge's first memory window that is not
prefetchable and lies below 4 GiB, 64-bit and prefetchable BARs
included; I/O BARs are never placed. Each BAR is an item whose span is
its hardware size rounded up to the page size and whose alignment is
that span, so no two BARs share a page. The functions below a root port
are first laid out from offset 0 inside it; the root port is then one
item whose span is that extent rounded up to 1 MiB and whose alignment
is the larger of 1 MiB and its largest item's, so two root ports'
forwarding windows never overlap. Items are taken largest alignment
first, then by place and BAR index, and each gets the lowest address
from the window's base that is aligned to it and overlaps nothing placed
before it, so the same functions always get the same addresses. A BAR
that does not fit is `unplaced`, and so is every BAR below a root port
that does not fit.
""".

-export([layout/2]).
-export_type([addresses/0]).

-include("generated/erx_abi.hrl").

-doc "Each placed function's memory BARs, by index, with an address or `unplaced`.".
-type addresses() :: #{erx_pcie:place() => #{0..5 => {placed, 0..16#ffffffff} | unplaced}}.

%% What is packed: a BAR, or a root port with the offsets of the BARs laid
%% out inside it. Items of equal alignment go in the order of their place
%% and BAR index, a root port's as index 0.
-type item() :: #{order := {erx_pcie:place(), 0..5},
                  span := pos_integer(),
                  alignment := pos_integer(),
                  inside := [{Bar :: {erx_pcie:place(), 0..5}, Offset :: non_neg_integer() | unplaced}]}.

-doc """
The addresses of the memory BARs of a placing walk's functions, the
`read` outcomes of what it found, in the bridge's windows.
""".
-spec layout([erx_pcie:window()], [erx_pcie_walk:found()]) -> addresses().
layout(Windows, Found) ->
    Bars = [{Place, Parent, Index, Log2}
            || #{place := Place, parent := Parent, outcome := {read, _Read, Sizes}} <- Found,
               {Index, Log2} <- lists:sort(maps:to_list(Sizes))],
    Addresses = case window(Windows) of
                    none -> [{{Place, Index}, unplaced} || {Place, _, Index, _} <- Bars];
                    {Base, Size} -> addresses(Bars, Base, Size)
                end,
    lists:foldl(fun({{Place, Index}, Address}, Layout) ->
                        Bar = case Address of
                                  unplaced -> unplaced;
                                  _ -> {placed, Address}
                              end,
                        maps:update_with(Place, fun(Placed) -> Placed#{Index => Bar} end,
                                         #{Index => Bar}, Layout)
                end,
                maps:from_list([{Place, #{}} || #{place := Place, outcome := {read, _, _}} <- Found]),
                Addresses).

%% The first memory window that is not prefetchable and lies below 4 GiB,
%% as its PCI base and size, or none.
window(Windows) ->
    case [{Pci, Size} || #{pci := Pci, size := Size, io := false, prefetchable := false} <- Windows,
                         Pci + Size =< 1 bsl 32] of
        [] -> none;
        [First | _] -> First
    end.

%% Each BAR's address: the root bus's BARs and each root port's packed into
%% the window, a root port's BARs at its address plus their offsets in it.
addresses(Bars, Base, Size) ->
    Top = [bar_item(Place, Index, Log2) || {Place, root, Index, Log2} <- Bars]
        ++ [root_port_item(RootPort, [Bar || {_, Parent, _, _} = Bar <- Bars, Parent =:= RootPort], Size)
            || RootPort <- lists:usort([Parent || {_, Parent, _, _} <- Bars, Parent =/= root])],
    lists:append([inside(Item, Start) || {Item, Start} <- pack(Top, Base, Size)]).

bar_item(Place, Index, Log2) ->
    Span = max(1 bsl Log2, ?ERX_PAGE_SIZE),
    #{order => {Place, Index}, span => Span, alignment => Span,
      inside => [{{Place, Index}, 0}]}.

%% A root port as one item: its BARs packed from offset 0, its span their
%% extent rounded up to the bridge window's granule, its alignment the
%% larger of the granule and its largest BAR's.
root_port_item(RootPort, Bars, WindowSize) ->
    Items = [bar_item(Place, Index, Log2) || {Place, _, Index, Log2} <- Bars],
    Packed = pack(Items, 0, WindowSize),
    Extent = lists:max([0 | [Offset + Span || {#{span := Span}, Offset} <- Packed, Offset =/= unplaced]]),
    Granule = ?ERX_PCIE_BRIDGE_MEMORY_GRANULE,
    Alignment = lists:max([Granule | [A || #{alignment := A} <- Items]]),
    Span = round_up(max(Extent, 1), Granule),
    #{order => {RootPort, 0}, span => Span, alignment => Alignment,
      inside => lists:append([inside(Item, Offset) || {Item, Offset} <- Packed])}.

%% The address of each BAR inside an item placed at Start, or each unplaced.
inside(#{inside := Bars}, unplaced) ->
    [{Bar, unplaced} || {Bar, _Offset} <- Bars];
inside(#{inside := Bars}, Start) ->
    [{Bar, case Offset of
               unplaced -> unplaced;
               _ -> Start + Offset
           end} || {Bar, Offset} <- Bars].

%% Each item, largest alignment first and then in order, with the lowest
%% address in [Base, Base + Size) aligned to it that overlaps nothing placed before it, or unplaced.
-spec pack([item()], non_neg_integer(), non_neg_integer()) ->
          [{item(), non_neg_integer() | unplaced}].
pack(Items, Base, Size) ->
    Sorted = lists:sort(fun(A, B) -> sort_key(A) =< sort_key(B) end, Items),
    {Packed, _Taken} =
        lists:mapfoldl(fun(Item, Taken) ->
                               case lowest_fit(Item, Base, Base + Size, Taken) of
                                   unplaced -> {{Item, unplaced}, Taken};
                                   Start -> {{Item, Start}, [{Start, Start + span(Item)} | Taken]}
                               end
                       end, [], Sorted),
    Packed.

%% The lowest aligned start that fits: either the base aligned up or the
%% end of a placed range aligned up, since below any other fitting start
%% lies the base or a placed range ending above the start less one
%% alignment.
lowest_fit(#{span := Span, alignment := Alignment}, Base, Limit, Taken) ->
    Candidates = lists:usort([round_up(Point, Alignment) || Point <- [Base | [End || {_, End} <- Taken]]]),
    Fits = [Start || Start <- Candidates, Start + Span =< Limit,
                     not lists:any(fun({From, To}) -> Start < To andalso From < Start + Span end, Taken)],
    case Fits of
        [] -> unplaced;
        [Lowest | _] -> Lowest
    end.

span(#{span := Span}) -> Span.

sort_key(#{alignment := Alignment, order := Order}) -> {-Alignment, Order}.

round_up(Value, Alignment) -> (Value + Alignment - 1) div Alignment * Alignment.
