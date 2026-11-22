%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Cases of the BCM2711 bridge driver, erx_pcie_bcm2711 (docs/design-pcie.md, "The
%% bridge seam"), over the register model erx_pcie_bcm2711_model kept in an ets table,
%% reached as the driver reaches its device and through the seam's effects: the
%% start's keep and reset paths, a link that never comes up, the clean turn-off,
%% configuration access through the seam, and `ready` holding back a VL805 whose
%% firmware does not read present.
-module(erx_pcie_bcm2711_driver_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_hw_bcm2711_pcie.hrl").

-define(DRIVER, erx_pcie_bcm2711).
-define(MODEL, erx_pcie_bcm2711_model).
-define(VERSION, 16#000138c1).

range(Pci, Cpu, Size) ->
    #{pci => Pci, cpu => Cpu, size => Size, flags => []}.

unused_place() -> #{bus => 0, device => 0, function => 0, pin => 0}.

bridge() ->
    #{index => 3, bus_first => 0, bus_last => 1, flags => [closed],
      windows => [range(16#c0000000, 16#600000000, 16#40000000) | lists:duplicate(3, range(0, 0, 0))],
      inbound => [inbound() | lists:duplicate(3, range(0, 0, 0))],
      places => [#{bus => 1, device => 0, function => 0, pin => 1} | lists:duplicate(3, unused_place())]}.

%% The tree's dma-ranges: PCI 0 at CPU 0, 3 GiB.
inbound() -> range(0, 0, 16#c0000000).

vl805() -> #{bus => 1, device => 0, function => 0, vendor => 16#1106, device_id => 16#3483}.

%% The driver's start over a model made with Options, and the model's table.
open(Options) -> open(bridge(), Options).

open(Bridge, Options) ->
    Table = ?MODEL:table(Options),
    {?DRIVER:open(Bridge, {?MODEL, Table}, ?MODEL:effects(Table)), Table}.

ops(Table) -> [Op || {_Time, Op} <- ?MODEL:log(?MODEL:stored(Table))].

violations(Table) -> ?MODEL:violations(?MODEL:stored(Table)).

perst_asserted(Table) ->
    [W || {write, rgr1_sw_init_1, W} <- ops(Table), ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_PERST_GET(W) =:= 1].

notified(Table) -> lists:member(notify_firmware, ops(Table)).

%% The firmware register's reads after the notification.
read_after_notification(Table) ->
    [Op || {cfg_read, ext_cfg_data, 16#50, 4} = Op <- tl(lists:dropwhile(fun(Op) -> Op =/= notify_firmware end,
                                                                         ops(Table)))].

%% Lines logged with the notification's round trip, whatever it took, as _.
any_round_trip(Lines) -> [re:replace(Line, " in [0-9]+ us$", " in _ us", [{return, list}]) || Line <- Lines].

%% A link the boot left up with the VL805's firmware loaded is kept: no PERST#, no
%% bridge reset, and `ready` gives the VL805 without a notification.
the_keep_path_resets_nothing_test() ->
    {{ok, State}, Table} = open(#{boot => up, firmware => ?VERSION}),
    ?assertMatch(#{path := kept, turn_off := not_run}, ?DRIVER:up(State)),
    ?assertEqual([], perst_asserted(Table)),
    ?assertEqual([], [Op || {write, rgr1_sw_init_1, _} = Op <- ops(Table)]),
    {ok, _Ready} = ?DRIVER:ready(vl805(), State),
    ?assertNot(notified(Table)),
    ?assertEqual([], violations(Table)).

%% A link the boot left down is brought up, each wait of the core a sleep of whole
%% milliseconds, and the VL805's firmware is asked for before `ready` gives it.
the_reset_path_brings_the_link_up_and_notifies_test() ->
    {{ok, State}, Table} = open(#{boot => down}),
    ?assertEqual(#{path => reset, turn_off => not_run, firmware => not_read}, ?DRIVER:up(State)),
    ?assertNot(notified(Table)),
    %% The 100 us settles are slept as 1 ms, the 100 ms after PERST#'s release as 100.
    ?assertEqual([{wait, 1000}, {wait, 1000}, {wait, 100000}],
                 lists:sublist([Op || {wait, _} = Op <- ops(Table)], 3)),
    {ok, _Ready} = ?DRIVER:ready(vl805(), State),
    ?assert(notified(Table)),
    ?assertEqual(?VERSION, ?MODEL:firmware_register(?MODEL:stored(Table))),
    ?assertEqual([], violations(Table)).

%% A link up whose VL805 reads no firmware is turned off cleanly before bring-up:
%% L23 requested, then PERST#, the request cleared, the SerDes powered
%% down and the bridge put in reset, in that order.
the_turn_off_runs_before_bring_up_test() ->
    {{ok, State}, Table} = open(#{boot => up, firmware => 0}),
    ?assertMatch(#{path := reset, turn_off := l23}, ?DRIVER:up(State)),
    Writes = [Register || {write, Register, _} <- ops(Table)],
    %% The first write selects the VL805 for the firmware read that decided the reset.
    ?assertEqual([ext_cfg_index, misc_pcie_ctrl, rgr1_sw_init_1, misc_pcie_ctrl, hard_debug, rgr1_sw_init_1],
                 lists:sublist(Writes, 6)),
    ?assertEqual([], violations(Table)).

%% A link that never trains fails the start with link_down.
a_link_that_never_comes_up_fails_the_start_test() ->
    ?assertMatch({{error, link_down}, _}, open(#{boot => down, trains => false})).

%% A tree whose inbound window BAR2 cannot carry is refused before any register is
%% touched.
a_refused_tree_fails_the_start_test() ->
    {Result, Table} = open((bridge())#{inbound := [range(0, 16#1000, 16#c0000000)]}, #{}),
    ?assertEqual({error, dma_ranges}, Result),
    ?assertEqual([], ops(Table)).

%% A notification that fails, as pci_bus:firmware/1 answers while the device service
%% cannot make the call, holds the VL805 back, logged, and its firmware register is
%% not read again (docs/design-pcie.md, "The bridge seam", the endpoint's firmware).
a_vl805_whose_notification_fails_is_not_ready_test() ->
    {{ok, State}, Table} = open(#{boot => down, notify => {answer, {error, enotsup}}}),
    {{not_ready, Held}, Logged} = erx_pcie_log_capture:logged(fun() -> ?DRIVER:ready(vl805(), State) end),
    ?assertEqual(["pcie: bridge 3: vl805 firmware 0x00000000 after PERST#",
                  "pcie: bridge 3: vl805 firmware not read 1 ms after the notification, which answered "
                  "{error,enotsup} in _ us",
                  "pcie: bridge 3: vl805 firmware not loaded"], any_round_trip(Logged)),
    ?assertEqual([], read_after_notification(Table)),
    %% Asked again, it stays held without another notification.
    Before = ops(Table),
    {not_ready, _Again} = ?DRIVER:ready(vl805(), Held),
    ?assertEqual(Before, ops(Table)).

%% A function other than the VL805 is never held back, and asks for nothing.
another_function_is_ready_test() ->
    {{ok, State}, Table} = open(#{boot => down}),
    Before = ops(Table),
    {ok, _Ready} = ?DRIVER:ready((vl805())#{vendor := 16#10de}, State),
    ?assertEqual(Before, ops(Table)).

%% Accesses through the seam: the VL805's vendor read through the index and data
%% window; an unlisted place answers absent with no operation, as does any place on
%% bus 0 but the root port.
access_through_the_seam_test() ->
    {{ok, State}, Table} = open(#{boot => down}),
    Started = length(ops(Table)),
    {{ok, 16#1106}, S1} = ?DRIVER:access({read, {1, 0, 0}, 0, 2}, State),
    Read = ops(Table),
    ?assert(length(Read) > Started),
    {{error, absent}, S2} = ?DRIVER:access({read, {1, 1, 0}, 0, 4}, S1),
    {{error, absent}, _S3} = ?DRIVER:access({read, {0, 1, 0}, 0, 4}, S2),
    ?assertEqual(Read, ops(Table)),
    ?assertEqual([], violations(Table)).

a_link_that_falls_answers_link_down_test() ->
    {{ok, _}, Up} = open(#{boot => down}),
    Count = length(ops(Up)),
    {{ok, Fell}, Table} = open(#{boot => down, fall_at => Count + 1}),
    ?assertEqual(ops(Up), ops(Table)),
    ?assertMatch({{error, link_down}, _}, ?DRIVER:access({read, {1, 0, 0}, 0, 4}, Fell)).

%% Firmware that still reads absent after a notification that answered ok holds the
%% VL805 back, logged, its register read once after the notification.
a_vl805_whose_firmware_stays_absent_is_not_ready_test() ->
    {{ok, State}, Table} = open(#{boot => down, notify => {answer, ok}}),
    {{not_ready, _Held}, Logged} = erx_pcie_log_capture:logged(fun() -> ?DRIVER:ready(vl805(), State) end),
    ?assertEqual(["pcie: bridge 3: vl805 firmware 0x00000000 after PERST#",
                  "pcie: bridge 3: vl805 firmware 0x00000000 1 ms after the notification, which answered ok in _ us",
                  "pcie: bridge 3: vl805 firmware not loaded"], any_round_trip(Logged)),
    ?assert(notified(Table)),
    ?assertEqual([{cfg_read, ext_cfg_data, 16#50, 4}], read_after_notification(Table)).

%% A link that falls under the firmware read is answered link_down, logged, which the
%% enumerator turns into its exit, as for an access that answers link_down.
a_link_that_falls_under_the_firmware_read_answers_link_down_test() ->
    {{ok, _}, Up} = open(#{boot => down}),
    Count = length(ops(Up)),
    {{ok, Fell}, _Table} = open(#{boot => down, fall_at => Count + 1}),
    {Result, Logged} = erx_pcie_log_capture:logged(fun() -> ?DRIVER:ready(vl805(), Fell) end),
    ?assertEqual({error, link_down}, Result),
    ?assertEqual(["pcie: bridge 3: vl805 firmware link_down after PERST#",
                  "pcie: bridge 3: vl805 firmware link_down 1 ms after the notification, which answered ok in _ us",
                  "pcie: bridge 3: link down under the vl805 firmware read"], any_round_trip(Logged)).

%% Probe B1 (docs/design-usb.md, "The VL805's firmware"): the start's line names what
%% the firmware register read at the start, or that it was not read.
the_start_logs_the_firmware_register_test() ->
    {{{ok, _}, _}, Kept} = erx_pcie_log_capture:logged(fun() -> open(#{boot => up, firmware => ?VERSION}) end),
    ?assertEqual(["pcie: bridge 3: kept, turn-off not_run, vl805 firmware 0x000138c1 at the start"], Kept),
    {{{ok, _}, _}, Off} = erx_pcie_log_capture:logged(fun() -> open(#{boot => up, firmware => 0}) end),
    ?assertEqual(["pcie: bridge 3: reset, turn-off l23, vl805 firmware 0x00000000 at the start"], Off),
    {{{ok, _}, _}, Down} = erx_pcie_log_capture:logged(fun() -> open(#{boot => down}) end),
    ?assertEqual(["pcie: bridge 3: reset, turn-off not_run, vl805 firmware not read at the start"], Down).

%% After a PERST# cycle `ready` logs the register before the notification and 1 ms
%% after it, with the notification's status and its round trip.
ready_logs_the_firmware_register_around_the_notification_test() ->
    {{ok, State}, _Table} = open(#{boot => down}),
    {{ok, _}, Logged} = erx_pcie_log_capture:logged(fun() -> ?DRIVER:ready(vl805(), State) end),
    ?assertEqual(["pcie: bridge 3: vl805 firmware 0x00000000 after PERST#",
                  "pcie: bridge 3: vl805 firmware 0x000138c1 1 ms after the notification, which answered ok in _ us"],
                 any_round_trip(Logged)).

%% The round trip is the notification's own: a firmware effect that takes 20 ms is
%% logged at 20 ms or more.
the_round_trip_is_the_notifications_test() ->
    Table = ?MODEL:table(#{boot => down}),
    #{firmware := Firmware} = Effects = ?MODEL:effects(Table),
    Slow = Effects#{firmware := fun() -> timer:sleep(20), Firmware() end},
    {ok, State} = ?DRIVER:open(bridge(), {?MODEL, Table}, Slow),
    {{ok, _}, [_, After]} = erx_pcie_log_capture:logged(fun() -> ?DRIVER:ready(vl805(), State) end),
    {match, [Us]} = re:run(After, " in ([0-9]+) us$", [{capture, all_but_first, list}]),
    ?assert(list_to_integer(Us) >= 20000).
