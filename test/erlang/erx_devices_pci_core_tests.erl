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

catalogue(Layouts) -> #{bridge => bridge(?BRIDGE), firmware_lost => false, answered => none, layouts => Layouts}.

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
    Held = [catalogue([]), #{bridge => bridge(7), firmware_lost => false, answered => none, layouts => []}],
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

%% The state machine of "Concurrency": a holder's requests and ends in each phase.

-define(FACET, pcie_facet).
-define(HOLDER, 21).

synced() -> {synced, 9, ?FACET}.

%% A pci row at Device, held by ?HOLDER, its setting of Mode.
held(Index, Device, Mode) ->
    (row(Index, Device))#{holder => ?HOLDER, setting => (mastering())#{mode := Mode}}.

request(Operation) -> #{from => from, grantee => ?HOLDER, operation => Operation}.

place(Device) -> {?BRIDGE, 0, Device, 0}.

%% A holder's end lowers each of its rows in the library first and, only with an
%% answered incarnation, sends the lowering after it; with none, the next start's
%% targets carry it.
a_holders_end_lowers_its_rows_in_the_library_then_sends_test() ->
    Rows = [held(10, 1, mastering), held(11, 2, decoding)],
    Off = fun(Device) -> {set, place(Device), (mastering())#{mode := off}} end,
    ?assertEqual([{mode, 10, off}, {mode, 11, off}, {pcie, ?FACET, Off(1), lowering}, {pcie, ?FACET, Off(2), lowering}],
                 erx_devices_pci_core:holder_ended(Rows, synced())),
    ?assertEqual([{mode, 10, off}, {mode, 11, off}], erx_devices_pci_core:holder_ended(Rows, {between, 9})),
    ?assertEqual([{mode, 10, off}, {mode, 11, off}], erx_devices_pci_core:holder_ended(Rows, down)).

a_request_waits_between_and_is_unavailable_when_down_test() ->
    Devices = [held(10, 1, off)],
    ?assertEqual(wait, erx_devices_pci_core:request(request({open, place(1)}), {between, start}, Devices)),
    ?assertEqual([{reply, from, {error, unavailable}}],
                 erx_devices_pci_core:request(request({open, place(1)}), down, Devices)).

%% The device service matches a place against the grantee's own rows alone: another
%% holder's function, the grantee's row with no place and a place no row names are
%% not held.
a_place_the_grantee_does_not_hold_is_refused_test() ->
    Devices = [held(10, 1, off), (held(11, 2, off))#{holder => ?HOLDER + 1},
               (other_row(12))#{holder => ?HOLDER}],
    [?assertEqual([{reply, from, {error, not_held}}],
                  erx_devices_pci_core:request(request({Operation, Place}), synced(), Devices))
     || Operation <- [open, master, reset], Place <- [place(2), place(3), none]].

%% A raise is sent first and written to the library only on the enumerator's ok;
%% master from mastering is sent again.
open_and_master_raise_after_the_enumerators_ok_test() ->
    Devices = [held(10, 1, off)],
    Open = request({open, place(1)}),
    Decoding = (mastering())#{mode := decoding},
    ?assertEqual([{pcie, ?FACET, {set, place(1), Decoding}, {raise, Open, 10, decoding}}],
                 erx_devices_pci_core:request(Open, synced(), Devices)),
    ?assertEqual({[{mode, 10, decoding}, {reply, from, ok}], none},
                 erx_devices_pci_core:pcie_answer({raise, Open, 10, decoding}, ok, synced(), Devices)),
    Master = request({master, place(1)}),
    [?assertEqual([{pcie, ?FACET, {set, place(1), mastering()}, {raise, Master, 10, mastering}}],
                  erx_devices_pci_core:request(Master, synced(), [held(10, 1, Mode)])) || Mode <- [decoding, mastering]],
    ?assertEqual([{reply, from, {error, order}}], erx_devices_pci_core:request(Master, synced(), Devices)).

%% A raise answered after its holder ended, or after the row passed to another
%% holder, writes nothing: the library never says more than a living holder asked.
a_raise_answered_after_its_holders_end_is_not_written_test() ->
    Open = request({open, place(1)}),
    [?assertEqual({[{reply, from, ok}], none},
                  erx_devices_pci_core:pcie_answer({raise, Open, 10, decoding}, ok, synced(), [Row]))
     || Row <- [(held(10, 1, off))#{holder => none}, (held(10, 1, off))#{holder => ?HOLDER + 1}]],
    Reset = request({reset, place(1)}),
    ?assertEqual({[{reply, from, {ok, none}}], none},
                 erx_devices_pci_core:pcie_answer({reset, Reset, 10}, {ok, none}, synced(),
                                                  [(held(10, 1, off))#{holder => none}])).

%% A reset lowers the library's setting before it is sent, and its ok, which leaves
%% the function decoding, raises the library to decoding, so the driver's master
%% after it is not refused as out of order; a refused or timed-out reset writes
%% nothing more.
a_reset_lowers_before_it_is_sent_test() ->
    Reset = request({reset, place(1)}),
    Devices = [held(10, 1, off)],
    ?assertEqual([{mode, 10, off}, {pcie, ?FACET, {reset, place(1)}, {reset, Reset, 10}}],
                 erx_devices_pci_core:request(Reset, synced(), [held(10, 1, mastering)])),
    ?assertEqual({[{mode, 10, decoding}, {reply, from, {ok, flr}}], none},
                 erx_devices_pci_core:pcie_answer({reset, Reset, 10}, {ok, flr}, synced(), Devices)),
    ?assertEqual({[{reply, from, {error, busy}}], none},
                 erx_devices_pci_core:pcie_answer({reset, Reset, 10}, {error, busy}, synced(), Devices)),
    ?assertEqual({[{reply, from, {error, unavailable}}], none},
                 erx_devices_pci_core:pcie_answer({reset, Reset, 10}, timeout, synced(), Devices)).

%% A call the incarnation's end failed waits again, or is handled at once when a later
%% incarnation is already answered; a timeout answers unavailable and writes nothing; a
%% refusal is the holder's answer; a lowering's answer is nobody's.
the_enumerators_answers_test() ->
    Open = request({open, place(1)}),
    Reset = request({reset, place(1)}),
    Raise = {raise, Open, 10, decoding},
    Devices = [held(10, 1, off)],
    ?assertEqual({[], Open}, erx_devices_pci_core:pcie_answer(Raise, ended, {between, 9}, Devices)),
    ?assertEqual({[], Reset}, erx_devices_pci_core:pcie_answer({reset, Reset, 10}, ended, {between, 9}, Devices)),
    Later = {synced, 10, later_facet},
    ?assertEqual({[{pcie, later_facet, {set, place(1), (mastering())#{mode := decoding}}, Raise}], none},
                 erx_devices_pci_core:pcie_answer(Raise, ended, Later, Devices)),
    ?assertEqual({[{reply, from, {error, unavailable}}], none},
                 erx_devices_pci_core:pcie_answer(Raise, timeout, synced(), Devices)),
    ?assertEqual({[{reply, from, {error, gone}}], none},
                 erx_devices_pci_core:pcie_answer(Raise, {error, gone}, synced(), Devices)),
    ?assertEqual({[], none}, erx_devices_pci_core:pcie_answer(lowering, ended, {between, 9}, Devices)),
    ?assertEqual({[], none}, erx_devices_pci_core:pcie_answer(lowering, ok, synced(), Devices)).

%% The answered incarnation's end moves synced to between and arms its 5 s timer;
%% another incarnation's end changes nothing; the timer moves its own between to down
%% and answers every waiting request unavailable, and a timer of an earlier between is
%% ignored; an answer replays the waiting requests in order.
the_phases_test() ->
    ?assertEqual({{between, 9}, [{arm_down, 9}]}, erx_devices_pci_core:incarnation_ended(9, synced())),
    ?assertEqual({synced(), []}, erx_devices_pci_core:incarnation_ended(8, synced())),
    ?assertEqual({{between, 9}, []}, erx_devices_pci_core:incarnation_ended(9, {between, 9})),
    Waiting = [request({open, place(1)}), (request({reset, place(1)}))#{from := later}],
    ?assertEqual({down, [{reply, from, {error, unavailable}}, {reply, later, {error, unavailable}}]},
                 erx_devices_pci_core:down_timer(9, {between, 9}, Waiting)),
    ?assertEqual({{between, 10}, []}, erx_devices_pci_core:down_timer(9, {between, 10}, Waiting)),
    ?assertEqual({synced(), []}, erx_devices_pci_core:down_timer(9, synced(), [])),
    {Phase, Actions} = erx_devices_pci_core:answered(9, ?FACET, Waiting, [held(10, 1, off)]),
    ?assertEqual(synced(), Phase),
    ?assertMatch([release_held, {pcie, ?FACET, {set, _, _}, {raise, _, 10, decoding}}, {mode, 10, off},
                  {pcie, ?FACET, {reset, _}, {reset, _, 10}}], Actions).

%% A restarted process begins synced only with the answered incarnation that
%% still holds the bridge; an ended one's answered, or none, begins between.
a_restart_resumes_only_the_answered_incarnation_holding_its_bridge_test() ->
    Answered = (catalogue([]))#{answered => 11},
    Bridge = fun(Holder) -> #{index => ?BRIDGE, holder => Holder, place => none, setting => none} end,
    ?assertEqual({await, 11}, erx_devices_pci_core:resume([Answered], [Bridge(11)])),
    ?assertEqual(between, erx_devices_pci_core:resume([Answered], [Bridge(12)])),
    ?assertEqual(between, erx_devices_pci_core:resume([Answered], [Bridge(none)])),
    ?assertEqual(between, erx_devices_pci_core:resume([catalogue([])], [Bridge(11)])).

%% Resumed, the process sends off for every row the library holds at off, then
%% handles the waiting requests; a later answered report's synced stays.
resumed_sends_every_row_at_off_then_handles_waiting_test() ->
    Off = (row(1, 0))#{holder => none, setting => #{mode => off, route => none}},
    Held = (row(2, 1))#{holder => 7},
    Request = #{from => from, grantee => 7, operation => {master, {?BRIDGE, 0, 1, 0}}},
    {{synced, 11, facet}, Actions} = erx_devices_pci_core:resumed(11, facet, {between, start}, [Request], [Off, Held]),
    ?assertMatch([{pcie, facet, {set, {?BRIDGE, 0, 0, 0}, #{mode := off}}, lowering},
                  {pcie, facet, {set, {?BRIDGE, 0, 1, 0}, #{mode := mastering}}, {raise, Request, 2, mastering}}],
                 Actions),
    ?assertEqual({{synced, 12, later}, []}, erx_devices_pci_core:resumed(11, facet, {synced, 12, later}, [], [Off])).

%% The rows held at boot (docs/design-system.md, "Waiting for a grant", "The rows
%% held at boot"), on a machine whose row 0 holds the host bridge, device ?BRIDGE,
%% row 1 a function behind it, and row 2 no pci device: row 1 is held with the
%% fallback; the PCIe row is never held, though it holds a function too; and with no
%% place naming a bridge there is no PCIe row and nothing is held. Only rows asked
%% for are answered, in the order asked.
held_holds_the_rows_with_a_pci_device_never_the_pcie_row_test() ->
    Devices = [#{index => ?BRIDGE, row => 0, place => none}, #{index => 5, row => 1, place => place(1)},
               #{index => 6, row => 2, place => none}, #{index => 7, row => 0, place => place(2)}],
    ?assertEqual({[1], {settled, <<"pcie">>, 30000}}, erx_devices_pci_core:held(Devices, [0, 1, 2])),
    ?assertEqual({[], none}, erx_devices_pci_core:held(Devices, [0, 2])),
    Unplaced = [Device#{place := none} || Device <- Devices],
    ?assertEqual({[], none}, erx_devices_pci_core:held(Unplaced, [0, 1, 2])).

%% The release, each event once: the answer to a report, the start of a process whose
%% library names an answered incarnation, whether or not it still holds the bridge, and
%% the forwarded end of a PCIe row's domain; not a resumed incarnation's facet, whose
%% start released already, nor the start of a process with none answered, nor the end
%% of another row's domain or a session's.
release_once_answered_is_written_and_at_a_pcie_rows_end_test() ->
    Devices = [#{index => ?BRIDGE, row => 0, holder => none, place => none, setting => none},
               (row(5, 1))#{row => 1}],
    Answered = (catalogue([]))#{answered => 11},
    {_, AnsweredActions} = erx_devices_pci_core:answered(11, facet, [], Devices),
    ?assertEqual([release_held], [Action || release_held = Action <- AnsweredActions]),
    {_, Resumed} = erx_devices_pci_core:resumed(11, facet, {between, start}, [], Devices),
    ?assertEqual([], [Action || release_held = Action <- Resumed]),
    ?assertEqual([release_held], erx_devices_pci_core:released_at_start([Answered])),
    ?assertEqual([], erx_devices_pci_core:released_at_start([catalogue([])])),
    ?assertEqual([release_held], erx_devices_pci_core:released_at_end({configured, 0}, Devices)),
    ?assertEqual([], erx_devices_pci_core:released_at_end({configured, 1}, Devices)),
    ?assertEqual([], erx_devices_pci_core:released_at_end({session, 3}, Devices)),
    ?assertEqual([], erx_devices_pci_core:released_at_end(none, Devices)).
