%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_pcie_place (docs/design-pcie.md, "Host tests of the pure cores"):
%% a fixed set of BARs at addresses written out here, the window's choice, what does
%% not fit, and generated sets, with and without root ports, checked for every
%% placed BAR inside the window and aligned to its span, no two spans overlapping, no
%% two root ports' windows overlapping, and the same addresses in any input order.
-module(erx_pcie_place_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PAGE, 16#1000).
-define(MIB, 16#100000).

%% QEMU virt's 32-bit memory window, from its tree's ranges.
window() ->
    #{pci => 16#10000000, cpu => 16#10000000, size => 16#2eff0000,
      addr64 => false, prefetchable => false, io => false}.

%% A function the walk read, with the hardware size of each memory BAR by index.
found(Place, Parent, Sizes) ->
    #{place => Place, parent => Parent, identity => #{}, outcome => {read, #{}, Sizes}}.

a_fixed_set_gets_the_addresses_written_here_test() ->
    Found = [found({0, 1, 0}, root, #{0 => 12}), found({0, 2, 0}, root, #{0 => 16}),
             found({0, 3, 0}, root, #{0 => 20})],
    ?assertEqual(#{{0, 1, 0} => #{0 => {placed, 16#10110000}},
                   {0, 2, 0} => #{0 => {placed, 16#10100000}},
                   {0, 3, 0} => #{0 => {placed, 16#10000000}}},
                 erx_pcie_place:layout([window()], Found)).

a_small_bar_takes_a_whole_page_test() ->
    Found = [found({0, 1, 0}, root, #{0 => 4, 1 => 8})],
    ?assertEqual(#{{0, 1, 0} => #{0 => {placed, 16#10000000}, 1 => {placed, 16#10001000}}},
                 erx_pcie_place:layout([window()], Found)).

the_window_is_the_first_low_memory_window_that_is_not_prefetchable_test() ->
    Prefetchable = (window())#{prefetchable => true},
    High = (window())#{pci => 16#8000000000, size => 16#8000000000, addr64 => true},
    Io = (window())#{pci => 0, size => 16#10000, io => true},
    Low = (window())#{pci => 16#40000000, size => 16#100000},
    Found = [found({0, 1, 0}, root, #{0 => 12})],
    ?assertEqual(#{{0, 1, 0} => #{0 => {placed, 16#40000000}}},
                 erx_pcie_place:layout([Prefetchable, High, Io, Low], Found)),
    ?assertEqual(#{{0, 1, 0} => #{0 => unplaced}},
                 erx_pcie_place:layout([Prefetchable, High, Io], Found)).

alignment_is_absolute_not_from_the_windows_base_test() ->
    Unaligned = (window())#{pci => 16#10001000, cpu => 16#10001000},
    Found = [found({0, 1, 0}, root, #{0 => 16})],
    ?assertEqual(#{{0, 1, 0} => #{0 => {placed, 16#10010000}}},
                 erx_pcie_place:layout([Unaligned], Found)).

what_does_not_fit_is_unplaced_test() ->
    Small = (window())#{size => ?MIB},
    Found = [found({0, 1, 0}, root, #{0 => 20}), found({0, 2, 0}, root, #{0 => 12}),
             found({0, 3, 0}, root, #{}), found({1, 0, 0}, {0, 4, 0}, #{0 => 12})],
    ?assertEqual(#{{0, 1, 0} => #{0 => {placed, 16#10000000}},
                   {0, 2, 0} => #{0 => unplaced},
                   {0, 3, 0} => #{},
                   {1, 0, 0} => #{0 => unplaced}},
                 erx_pcie_place:layout([Small], Found)).

a_root_ports_functions_lie_inside_its_granule_aligned_window_test() ->
    Found = [found({0, 1, 0}, root, #{0 => 12}),
             found({1, 0, 0}, {0, 2, 0}, #{0 => 14, 2 => 12})],
    ?assertEqual(#{{0, 1, 0} => #{0 => {placed, 16#10100000}},
                   {1, 0, 0} => #{0 => {placed, 16#10000000}, 2 => {placed, 16#10004000}}},
                 erx_pcie_place:layout([window()], Found)).

generated_sets_satisfy_every_placement_property_test_() ->
    {timeout, 60, fun() -> lists:foreach(fun check_generated/1, lists:seq(1, 300)) end}.

check_generated(Seed) ->
    rand:seed(exsss, {Seed, Seed * 7, Seed * 13}),
    Found = generated(),
    Layout = erx_pcie_place:layout([window()], Found),
    #{pci := Base, size := Size} = window(),
    Spans = [{Place, Parent, Address, max(1 bsl Log2, ?PAGE)}
             || #{place := Place, parent := Parent, outcome := {read, _, Sizes}} <- Found,
                {Index, Log2} <- maps:to_list(Sizes),
                {placed, Address} <- [maps:get(Index, maps:get(Place, Layout))]],
    [begin
         ?assert(Address >= Base andalso Address + Span =< Base + Size),
         ?assertEqual(0, Address rem Span)
     end || {_, _, Address, Span} <- Spans],
    ?assertEqual([], overlaps([{A, A + S} || {_, _, A, S} <- Spans])),
    RootPorts = lists:usort([Parent || {_, Parent, _, _} <- Spans, Parent =/= root]),
    Windows = [forwarding(RootPort, Spans) || RootPort <- RootPorts]
        ++ [{A, A + S} || {_, root, A, S} <- Spans],
    ?assertEqual([], overlaps(Windows)),
    Shuffled = [F || {_, F} <- lists:sort([{rand:uniform(), F} || F <- Found])],
    ?assertEqual(Layout, erx_pcie_place:layout([window()], Shuffled)).

%% A root port's forwarding window: from its lowest BAR to its highest BAR's
%% end, each rounded out to 1 MiB, as its target derives it from the layouts.
forwarding(RootPort, Spans) ->
    Inside = [{A, A + S} || {_, Parent, A, S} <- Spans, Parent =:= RootPort],
    Low = lists:min([A || {A, _} <- Inside]),
    High = lists:max([E || {_, E} <- Inside]),
    {Low div ?MIB * ?MIB, (High + ?MIB - 1) div ?MIB * ?MIB}.

overlaps(Ranges) ->
    [{R1, R2} || {{_, E1} = R1, {S2, _} = R2} <- neighbours(lists:sort(Ranges)), S2 < E1].

neighbours([First, Second | Rest]) -> [{First, Second} | neighbours([Second | Rest])];
neighbours(_) -> [].

%% Up to eight functions on the root bus and up to three root ports with up to
%% six functions each, every function with up to three memory BARs of 16 bytes to
%% 16 MiB.
generated() ->
    Root = [found({0, Device, 0}, root, sizes()) || Device <- lists:seq(1, rand:uniform(8))],
    Below = [found({Bus, Device, 0}, {0, 16 + Bus, 0}, sizes())
             || Bus <- lists:seq(1, rand:uniform(4) - 1), Device <- lists:seq(0, rand:uniform(6) - 1)],
    Root ++ Below.

sizes() ->
    maps:from_list([{Index, 3 + rand:uniform(21)} || Index <- lists:seq(0, rand:uniform(4) - 2)]).
