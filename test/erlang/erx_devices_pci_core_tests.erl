%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_devices_pci_core, the device service's PCIe decisions, over catalogues
%% shaped as erx_domain_lib:pci_bridges/0 and devices/0 answer them. The answer to
%% `report` lowers every pci row whose function the catalogue, as the library's
%% intake left it, does not keep, whatever the start said it kept
%% (docs/design-pcie.md, "Facets").
-module(erx_devices_pci_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(BRIDGE, 4).

bridge(Index) -> #{index => Index, bus_first => 0, bus_last => 255}.

record(Bridge, Device) -> #{bridge => Bridge, bus => 0, device => Device, function => 0, state => ready}.

layout(Device, State, Confirmed) -> #{record => record(?BRIDGE, Device), state => State, confirmed => Confirmed}.

catalogue(Layouts) -> #{bridge => bridge(?BRIDGE), firmware_lost => false, layouts => Layouts}.

mastering() -> #{mode => mastering, route => msi, message => #{address => 16#8000000, data => 1}}.

%% A pci row at Device of the bridge, its setting mastering.
row(Index, Device) -> #{index => Index, place => {?BRIDGE, 0, Device, 0}, setting => mastering()}.

other_row(Index) -> #{index => Index, place => none, setting => none}.

%% The intake refused the latest report whole: every layout of its bridge is
%% unconfirmed, though each keeps the state an earlier report gave it and the
%% start reported it kept.
a_report_refused_whole_lowers_every_function_of_its_bridge_test() ->
    Catalogues = [catalogue([layout(1, ready, false), layout(2, ready, false)])],
    ?assertEqual([10, 11], erx_devices_pci_core:lowered(Catalogues, [row(10, 1), row(11, 2), other_row(12)], [])).

%% A layout the walk left unreported past pcie_functions_max: not listed, state none.
a_function_left_unreported_is_lowered_test() ->
    Catalogues = [catalogue([layout(1, ready, true), layout(2, none, false)])],
    ?assertEqual([11], erx_devices_pci_core:lowered(Catalogues, [row(10, 1), row(11, 2)], [])).

a_function_the_latest_report_found_not_ready_is_lowered_test() ->
    Catalogues = [catalogue([layout(1, not_ready, true)])],
    ?assertEqual([10], erx_devices_pci_core:lowered(Catalogues, [row(10, 1)], [])).

%% A row at a place with no layout, as on a bridge whose placing report the intake
%% refused, or of a bridge the library holds no catalogue for.
a_row_with_no_layout_is_lowered_test() ->
    ?assertEqual([10, 11], erx_devices_pci_core:lowered([catalogue([])], [row(10, 1), row(11, 2)], [])),
    ?assertEqual([10], erx_devices_pci_core:lowered([], [row(10, 1)], [])).

a_confirmed_ready_function_keeps_its_setting_test() ->
    Catalogues = [catalogue([layout(1, ready, true)])],
    Reported = [#{record => record(?BRIDGE, 1), kept => true}],
    ?assertEqual([], erx_devices_pci_core:lowered(Catalogues, [row(10, 1), other_row(11)], Reported)).

%% The start found the function disturbed and turned it off with its record
%% unchanged: the intake confirms it ready, and the library's setting must follow
%% the hardware down.
a_function_the_start_turned_off_is_lowered_though_confirmed_test() ->
    Catalogues = [catalogue([layout(1, ready, true), layout(2, ready, true)])],
    Reported = [#{record => record(?BRIDGE, 1), kept => false}, #{record => record(?BRIDGE, 2), kept => true}],
    ?assertEqual([10], erx_devices_pci_core:lowered(Catalogues, [row(10, 1), row(11, 2)], Reported)).

a_bridge_marked_firmware_lost_keeps_no_row_test() ->
    Lost = (catalogue([layout(1, ready, true)]))#{firmware_lost := true},
    ?assertEqual([10], erx_devices_pci_core:lowered([Lost], [row(10, 1)], [])).

%% Each held bridge gets its own records, in report order, and one the report has
%% none for gets an empty report; a record naming a bridge the library does not
%% hold reaches no intake.
the_report_reaches_only_the_bridges_the_library_holds_test() ->
    Held = [catalogue([]), #{bridge => bridge(7), firmware_lost => false, layouts => []}],
    Reported = [#{record => record(?BRIDGE, 2), kept => true}, #{record => record(9, 1), kept => true},
                #{record => record(?BRIDGE, 1), kept => false}],
    ?assertEqual({[{?BRIDGE, [record(?BRIDGE, 2), record(?BRIDGE, 1)]}, {7, []}], [record(9, 1)]},
                 erx_devices_pci_core:reports(Reported, Held)).

a_function_no_row_names_is_unlisted_test() ->
    Reported = [#{record => record(?BRIDGE, 1), kept => true}, #{record => record(?BRIDGE, 2), kept => true}],
    ?assertEqual([record(?BRIDGE, 2)], erx_devices_pci_core:unlisted(Reported, [row(10, 1), other_row(11)])).

targets_answer_the_librarys_bridges_layouts_and_settings_test() ->
    Catalogues = [catalogue([layout(1, ready, true), layout(2, none, false)])],
    ?assertEqual({ok, [bridge(?BRIDGE)], [record(?BRIDGE, 1), record(?BRIDGE, 2)], #{{?BRIDGE, 0, 1, 0} => mastering()}},
                 erx_devices_pci_core:targets(Catalogues, [row(10, 1), other_row(11)])).
