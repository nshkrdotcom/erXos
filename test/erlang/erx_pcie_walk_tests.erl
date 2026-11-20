%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_pcie_walk and erx_pcie_ecam (docs/design-pcie.md, "Host tests of
%% the pure cores"), against erx_pcie_model: an open root bus behind the ECAM driver,
%% with multifunction devices and root ports, and a closed bridge whose root port sets
%% the multifunction bit and whose bus 1 holds functions at listed and unlisted places.
%% Every offset and bit is written out as sys/dev/pci/pcireg.h gives it.
-module(erx_pcie_walk_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erx_pcie_cfg_tests, [blank/0, put/4, endpoint/0, root_port/0]).

%% The endpoint fixture's BAR registers, each register's writable bits: a 4 KiB BAR 0,
%% an I/O BAR 1, a 16 KiB 64-bit BAR in registers 2 and 3, and registers 4 and 5,
%% which implement no BAR and read 0 whatever is written.
endpoint_masks() ->
    #{16#10 => 16#fffff000, 16#14 => 16#ffffffc0, 16#18 => 16#ffffc000, 16#1c => 16#ffffffff,
      16#20 => 0, 16#24 => 0}.

%% A root port's two BAR registers, which implement none.
root_port_masks() -> #{16#10 => 0, 16#14 => 0}.

endpoint_at(Place) -> {Place, endpoint(), endpoint_masks()}.

%% The endpoint fixture as a single-function device.
single_at(Place) -> {Place, put(endpoint(), 16#0e, 1, 16#00), endpoint_masks()}.

root_port_at(Place) -> {Place, root_port(), root_port_masks()}.

open_bridge(Last) ->
    #{index => 7, bus_first => 0, bus_last => Last, closed => false, windows => [], places => []}.

closed_bridge(Listed) ->
    #{index => 8, bus_first => 0, bus_last => 1, closed => true, windows => [],
      places => [#{place => Place, pin => 1} || Place <- Listed]}.

%% The walk run to its end over the ECAM driver on the model, each root port's
%% target applied with the answer ApplyAnswer.
ecam_walk(Kind, Bridge, Table) ->
    ecam_walk(Kind, Bridge, Table, ok).

ecam_walk(Kind, Bridge, Table, ApplyAnswer) ->
    {ok, State} = erx_pcie_ecam:open(Bridge, {erx_pcie_model, {Table, 0}}),
    drive(erx_pcie_walk:start(Bridge, Kind), {erx_pcie_ecam, State, ApplyAnswer}, Table, []).

closed_walk(Kind, Bridge, Table) ->
    {ok, State} = erx_pcie_model:closed(Bridge, Table),
    drive(erx_pcie_walk:start(Bridge, Kind), {erx_pcie_model, State, ok}, Table, []).

%% Each access made through the driver; each root port's target applied by
%% opening its secondary bus in the model when ApplyAnswer is ok. Returns the
%% stop and the root ports applied, with their buses, in order.
drive({_Walk, [{stop, Stop}]}, _Edge, _Table, Applied) ->
    {Stop, lists:reverse(Applied)};
drive({Walk, [{access, Access}]}, {Driver, State, ApplyAnswer}, Table, Applied) ->
    {Answer, Next} = Driver:access(Access, State),
    drive(erx_pcie_walk:step(Answer, Walk), {Driver, Next, ApplyAnswer}, Table, Applied);
drive({Walk, [{root_port, Place, _Read, #{secondary := Bus} = Buses}]}, {_, _, ApplyAnswer} = Edge,
      Table, Applied) ->
    ApplyAnswer =:= ok andalso erx_pcie_model:open_bus(Table, Bus),
    drive(erx_pcie_walk:step(ApplyAnswer, Walk), Edge, Table, [{Place, Buses} | Applied]).

places(#{found := Found}) -> [Place || #{place := Place} <- Found].

outcome(Place, #{found := Found}) ->
    [Outcome] = [O || #{place := P, outcome := O} <- Found, P =:= Place],
    Outcome.

an_open_root_bus_finds_every_function_and_numbers_root_ports_in_place_order_test() ->
    Table = erx_pcie_model:new([endpoint_at({0, 0, 0}), single_at({0, 0, 3}),
                                root_port_at({0, 2, 0}), single_at({1, 0, 0}),
                                root_port_at({0, 4, 0}), endpoint_at({2, 5, 0}),
                                single_at({2, 5, 6})]),
    {{done, Result}, Applied} = ecam_walk(later, open_bridge(255), Table),
    ?assertEqual([{0, 0, 0}, {0, 0, 3}, {1, 0, 0}, {2, 5, 0}, {2, 5, 6}], places(Result)),
    ?assertEqual([{{0, 2, 0}, #{primary => 0, secondary => 1, subordinate => 1}},
                  {{0, 4, 0}, #{primary => 0, secondary => 2, subordinate => 2}}], Applied),
    ?assertEqual([{{0, 2, 0}, ok}, {{0, 4, 0}, ok}],
                 [{P, A} || #{place := P, applied := A} <- maps:get(root_ports, Result)]),
    ?assertMatch(#{parent := {0, 2, 0}}, lists:nth(3, maps:get(found, Result))),
    ?assertMatch({read, #{vendor := 16#1af4, header := normal}, #{}}, outcome({0, 0, 0}, Result)).

a_closed_bridge_reaches_only_its_root_port_and_listed_places_test() ->
    RootPort = put(root_port(), 16#0e, 1, 16#81),
    Table = erx_pcie_model:new([{{0, 0, 0}, RootPort, root_port_masks()}, single_at({1, 0, 0}),
                                single_at({1, 1, 0}), single_at({0, 0, 1})]),
    {{done, Result}, Applied} = closed_walk(placing, closed_bridge([{1, 0, 0}]), Table),
    ?assertEqual([{1, 0, 0}], places(Result)),
    ?assertMatch([{{0, 0, 0}, #{secondary := 1}}], Applied),
    Touched = lists:usort([Place || {_Kind, Place, _Offset} <- erx_pcie_model:hardware(Table)]),
    ?assertEqual([{0, 0, 0}, {1, 0, 0}], Touched).

a_header_type_above_1_is_unsupported_without_a_parse_test() ->
    CardBus = put(put(put(blank(), 16#00, 2, 16#104c), 16#0e, 1, 16#02), 16#3d, 1, 9),
    Table = erx_pcie_model:new([{{0, 0, 0}, CardBus, #{}}]),
    {{done, Result}, _} = ecam_walk(placing, open_bridge(255), Table),
    ?assertEqual({unsupported, header_type}, outcome({0, 0, 0}, Result)),
    ?assertMatch([#{identity := #{vendor := 16#104c, header_type := 2}}], maps:get(found, Result)).

a_refused_snapshot_is_malformed_and_gets_one_quieting_write_test() ->
    Refused = put(endpoint(), 16#34, 1, 16#38),
    Table = erx_pcie_model:new([{{0, 0, 0}, Refused, endpoint_masks()}]),
    {{done, Result}, _} = ecam_walk(placing, open_bridge(255), Table),
    ?assertEqual({malformed, capability_pointer}, outcome({0, 0, 0}, Result)),
    Writes = [Offset || {write, {0, 0, 0}, Offset} <- erx_pcie_model:hardware(Table)],
    ?assertEqual([16#04], Writes),
    ?assertEqual(16#0400, erx_pcie_model:register(Table, {0, 0, 0}, {16#04, 2})).

a_placing_walk_sizes_memory_bars_and_restores_them_test() ->
    Table = erx_pcie_model:new([single_at({0, 0, 0})]),
    Before = [erx_pcie_model:register(Table, {0, 0, 0}, R) || R <- registers()],
    {{done, Result}, _} = ecam_walk(placing, open_bridge(255), Table),
    ?assertMatch({read, _, #{0 := 12, 2 := 14}}, outcome({0, 0, 0}, Result)),
    {read, _, Sizes} = outcome({0, 0, 0}, Result),
    ?assertEqual([0, 2], lists:sort(maps:keys(Sizes))),
    ?assertEqual(Before, [erx_pcie_model:register(Table, {0, 0, 0}, R) || R <- registers()]).

registers() -> [{16#04, 2}, {16#10, 4}, {16#14, 4}, {16#18, 4}, {16#1c, 4}].

a_later_walk_writes_nothing_test() ->
    Table = erx_pcie_model:new([single_at({0, 0, 0}), root_port_at({0, 1, 0}), single_at({1, 0, 0})]),
    {{done, _}, _} = ecam_walk(later, open_bridge(255), Table),
    ?assertEqual([], [W || {write, _, _} = W <- erx_pcie_model:hardware(Table)]).

a_root_port_with_a_bar_is_unsupported_with_nothing_below_read_test() ->
    Table = erx_pcie_model:new([{{0, 1, 0}, root_port(), #{16#10 => 16#fffff000}},
                                single_at({1, 0, 0})]),
    {{done, Result}, Applied} = ecam_walk(placing, open_bridge(255), Table),
    ?assertEqual({unsupported, root_port_bar}, outcome({0, 1, 0}, Result)),
    ?assertEqual([], Applied),
    ?assertEqual([], [P || {_, {1, _, _} = P, _} <- erx_pcie_model:hardware(Table)]).

a_type_1_header_below_a_root_port_is_unsupported_test() ->
    Table = erx_pcie_model:new([root_port_at({0, 1, 0}), root_port_at({1, 0, 0}),
                                single_at({2, 0, 0})]),
    {{done, Result}, Applied} = ecam_walk(later, open_bridge(255), Table),
    ?assertEqual({unsupported, below_root_port}, outcome({1, 0, 0}, Result)),
    ?assertMatch([{{0, 1, 0}, _}], Applied),
    ?assertEqual([{1, 0, 0}], places(Result)).

a_root_port_whose_target_did_not_apply_has_nothing_below_read_test() ->
    Table = erx_pcie_model:new([root_port_at({0, 1, 0}), single_at({1, 0, 0})]),
    erx_pcie_model:open_bus(Table, 1),
    {{done, Result}, _} = ecam_walk(later, open_bridge(255), Table, {error, stuck}),
    ?assertMatch([#{place := {0, 1, 0}, applied := {error, stuck}}], maps:get(root_ports, Result)),
    ?assertEqual([], places(Result)),
    ?assertEqual([], [P || {_, {1, _, _} = P, _} <- erx_pcie_model:hardware(Table)]).

bus_numbers_follow_the_root_ports_places_alone_test() ->
    Functions = [{{0, 1, 0}, root_port(), #{16#10 => 16#fffff000}}, root_port_at({0, 2, 0})],
    {{done, Placing}, PlacingApplied} = ecam_walk(placing, open_bridge(255), erx_pcie_model:new(Functions)),
    ?assertEqual({unsupported, root_port_bar}, outcome({0, 1, 0}, Placing)),
    ?assertMatch([{{0, 2, 0}, #{secondary := 2}}], PlacingApplied),
    {{done, _}, LaterApplied} = ecam_walk(later, open_bridge(255), erx_pcie_model:new(Functions)),
    ?assertMatch([{{0, 1, 0}, #{secondary := 1}}, {{0, 2, 0}, #{secondary := 2}}], LaterApplied).

a_sizing_mask_with_holes_is_malformed_test() ->
    Table = erx_pcie_model:new([{{0, 0, 0}, put(endpoint(), 16#0e, 1, 0),
                                 (endpoint_masks())#{16#10 => 16#ff0ff000}}]),
    {{done, Result}, _} = ecam_walk(placing, open_bridge(255), Table),
    ?assertEqual({malformed, {bar_mask, 0}}, outcome({0, 0, 0}, Result)).

a_bar_of_4_gib_is_unplaced_test() ->
    Snapshot = put(put(endpoint(), 16#0e, 1, 0), 16#18, 4, 16#0000000c),
    Table = erx_pcie_model:new([{{0, 0, 0}, Snapshot,
                                 (endpoint_masks())#{16#18 => 0}}]),
    {{done, Result}, _} = ecam_walk(placing, open_bridge(255), Table),
    ?assertMatch({unplaced, #{vendor := 16#1af4}, {bar_size, 2}}, outcome({0, 0, 0}, Result)).

a_root_port_past_the_bus_range_is_unsupported_test() ->
    Table = erx_pcie_model:new([root_port_at({0, 1, 0})]),
    {{done, Result}, Applied} = ecam_walk(later, open_bridge(0), Table),
    ?assertEqual({unsupported, bus_range}, outcome({0, 1, 0}, Result)),
    ?assertEqual([], Applied).

functions_past_the_bound_are_listed_and_left_test() ->
    Functions = [{{0, Device, Function}, endpoint(), endpoint_masks()}
                 || Device <- lists:seq(0, 4), Function <- lists:seq(0, 7)],
    Table = erx_pcie_model:new(Functions),
    {{done, Result}, _} = ecam_walk(later, open_bridge(255), Table),
    ?assertEqual(32, length(maps:get(found, Result))),
    ?assertEqual([{0, 4, F} || F <- lists:seq(0, 7)], maps:get(past_bound, Result)),
    %% Device 4's probe reads its vendor and header type, then each function only
    %% its vendor.
    ?assertEqual([0, 16#0e], lists:usort([Offset || {read, {0, 4, _}, Offset}
                                                     <- erx_pcie_model:hardware(Table)])).

a_link_down_stops_the_walk_test() ->
    Table = erx_pcie_model:new([single_at({0, 0, 0})]),
    erx_pcie_model:set_link(Table, down),
    ?assertMatch({link_down, []}, closed_walk(later, closed_bridge([]), Table)).

ecam_places_each_function_at_its_window_offset_test() ->
    Table = erx_pcie_model:new([single_at({2, 3, 4})]),
    erx_pcie_model:open_bus(Table, 2),
    Bridge = (open_bridge(255))#{bus_first => 1},
    {ok, State} = erx_pcie_ecam:open(Bridge, {erx_pcie_model, {Table, 1}}),
    ?assertMatch({{ok, 16#1af4}, _}, erx_pcie_ecam:access({read, {2, 3, 4}, 0, 2}, State)),
    ?assertEqual([{read, {2, 3, 4}, 0}], erx_pcie_model:hardware(Table)).

ecam_answers_absent_outside_its_bus_range_without_touching_the_window_test() ->
    Table = erx_pcie_model:new([single_at({1, 0, 0})]),
    erx_pcie_model:open_bus(Table, 1),
    {ok, State} = erx_pcie_ecam:open(open_bridge(0), {erx_pcie_model, {Table, 0}}),
    ?assertMatch({{error, absent}, _}, erx_pcie_ecam:access({read, {1, 0, 0}, 0, 4}, State)),
    ?assertMatch({{error, absent}, _}, erx_pcie_ecam:access({write, {1, 0, 0}, 4, 2, 0}, State)),
    ?assertEqual([], erx_pcie_model:hardware(Table)).

ecam_answers_absent_below_its_first_bus_test() ->
    Table = erx_pcie_model:new([single_at({0, 0, 0})]),
    Bridge = (open_bridge(255))#{bus_first => 1},
    {ok, State} = erx_pcie_ecam:open(Bridge, {erx_pcie_model, {Table, 1}}),
    ?assertMatch({{error, absent}, _}, erx_pcie_ecam:access({read, {0, 0, 0}, 0, 4}, State)),
    ?assertEqual([], erx_pcie_model:hardware(Table)).

ecam_takes_all_ones_as_absent_only_at_offset_0_test() ->
    Table = erx_pcie_model:new([]),
    {ok, State} = erx_pcie_ecam:open(open_bridge(255), {erx_pcie_model, {Table, 0}}),
    ?assertMatch({{error, absent}, _}, erx_pcie_ecam:access({read, {0, 0, 0}, 0, 4}, State)),
    ?assertMatch({{ok, 16#ffff}, _}, erx_pcie_ecam:access({read, {0, 0, 0}, 4, 2}, State)),
    ?assertMatch({ok, _}, erx_pcie_ecam:ready(#{}, State)),
    ?assertEqual({error, unsupported}, erx_pcie_ecam:start(open_bridge(255), 0)).
