%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Cases of the BCM2711 bridge driver, erx_pcie_bcm2711 (docs/design-pcie.md, "The
%% bridge seam"), over the register model erx_pcie_bcm2711_model as its port: the
%% start's keep and reset paths, a link that never comes up, the clean turn-off,
%% configuration access through the seam, and `ready` holding back a VL805 whose
%% firmware does not read present.
-module(erx_pcie_bcm2711_driver_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_hw_bcm2711_pcie.hrl").

-define(DRIVER, erx_pcie_bcm2711).
-define(MODEL, erx_pcie_bcm2711_model).
-define(VERSION, 16#000138c1).

%% The model as a port whose notification loads no firmware and answers the model's
%% `notify`: `{error, enotsup}`, as pci_bus:firmware/1 answers while the device
%% service cannot make the call, or `ok`, a notification that did not take.
-export([op/2]).

op(notify_firmware, #{notify := Answer} = Model) ->
    %% Logged as made, the VL805 left without firmware.
    {ok, Logged} = ?MODEL:op(notify_firmware, Model),
    {Answer, Logged#{firmware := ?MODEL:firmware_register(Model)}};
op(Op, Model) -> ?MODEL:op(Op, Model).

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

open(Options) -> open(Options, ?MODEL).

open(Options, PortModule) ->
    Model = (?MODEL:new(Options))#{notify => maps:get(notify, Options, {error, enotsup})},
    ?DRIVER:open(bridge(), {PortModule, Model}).

model(State) -> element(2, ?DRIVER:effects(State)).

ops(Model) -> [Op || {_Time, Op} <- ?MODEL:log(Model)].

perst_asserted(Model) ->
    [W || {write, rgr1_sw_init_1, W} <- ops(Model), ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_PERST_GET(W) =:= 1].

notified(Model) -> lists:member(notify_firmware, ops(Model)).

%% A link the boot left up with the VL805's firmware loaded is kept: no PERST#, no
%% bridge reset, and `ready` gives the VL805 without a notification.
the_keep_path_resets_nothing_test() ->
    {ok, State} = open(#{boot => up, firmware => ?VERSION}),
    ?assertMatch(#{path := kept, turn_off := not_run}, ?DRIVER:up(State)),
    ?assertEqual([], perst_asserted(model(State))),
    ?assertEqual([], [Op || {write, rgr1_sw_init_1, _} = Op <- ops(model(State))]),
    {ok, Ready} = ?DRIVER:ready(vl805(), State),
    ?assertNot(notified(model(Ready))),
    ?assertEqual([], ?MODEL:violations(model(Ready))).

%% A link the boot left down is brought up, and the VL805's firmware is asked for
%% before `ready` gives it.
the_reset_path_brings_the_link_up_and_notifies_test() ->
    {ok, State} = open(#{boot => down}),
    ?assertEqual(#{path => reset, turn_off => not_run}, ?DRIVER:up(State)),
    ?assertNot(notified(model(State))),
    {ok, Ready} = ?DRIVER:ready(vl805(), State),
    ?assert(notified(model(Ready))),
    ?assertEqual(?VERSION, ?MODEL:firmware_register(model(Ready))),
    ?assertEqual([], ?MODEL:violations(model(Ready))).

%% A link up whose VL805 reads no firmware is turned off cleanly before bring-up:
%% L23 requested, then PERST#, the request cleared, the SerDes powered
%% down and the bridge put in reset, in that order.
the_turn_off_runs_before_bring_up_test() ->
    {ok, State} = open(#{boot => up, firmware => 0}),
    ?assertMatch(#{path := reset, turn_off := l23}, ?DRIVER:up(State)),
    Writes = [Register || {write, Register, _} <- ops(model(State))],
    %% The first write selects the VL805 for the firmware read that decided the reset.
    ?assertEqual([ext_cfg_index, misc_pcie_ctrl, rgr1_sw_init_1, misc_pcie_ctrl, hard_debug, rgr1_sw_init_1],
                 lists:sublist(Writes, 6)),
    ?assertEqual([], ?MODEL:violations(model(State))).

%% A link that never trains fails the start with link_down.
a_link_that_never_comes_up_fails_the_start_test() ->
    ?assertEqual({error, link_down}, open(#{boot => down, trains => false})).

%% A tree whose inbound window BAR2 cannot carry is refused before any register is
%% touched.
a_refused_tree_fails_the_start_test() ->
    ?assertEqual({error, dma_ranges},
                 ?DRIVER:open((bridge())#{inbound := [range(0, 16#1000, 16#c0000000)]}, {?MODEL, ?MODEL:new(#{})})).

%% A notification that fails holds the VL805 back, logged, and its firmware register is
%% not read again (docs/design-pcie.md, "The bridge seam", the endpoint's firmware).
a_vl805_whose_notification_fails_is_not_ready_test() ->
    {ok, State} = open(#{boot => down}, ?MODULE),
    {{not_ready, Held}, Logged} = erx_pcie_log_capture:logged(fun() -> ?DRIVER:ready(vl805(), State) end),
    ?assertEqual(["pcie: bridge 3: vl805 firmware not loaded"], Logged),
    Reads = [Op || {cfg_read, ext_cfg_data, 16#50, 4} = Op <- ops(model(Held))],
    ?assertEqual([], Reads),
    %% Asked again, it stays held without another notification.
    {not_ready, Again} = ?DRIVER:ready(vl805(), Held),
    ?assertEqual(ops(model(Held)), ops(model(Again))).

%% A function other than the VL805 is never held back, and asks for nothing.
another_function_is_ready_test() ->
    {ok, State} = open(#{boot => down}),
    Other = (vl805())#{vendor := 16#10de},
    {ok, Ready} = ?DRIVER:ready(Other, State),
    ?assertEqual(ops(model(State)), ops(model(Ready))).

%% Accesses through the seam: the VL805's vendor read through the index and data
%% window, the model's state carried from one access to the next; an unlisted place
%% answers absent with no operation; a link that fell answers link_down.
access_through_the_seam_test() ->
    {ok, State} = open(#{boot => down}),
    {{ok, 16#1106}, S1} = ?DRIVER:access({read, {1, 0, 0}, 0, 2}, State),
    ?assert(length(ops(model(S1))) > length(ops(model(State)))),
    {{error, absent}, S2} = ?DRIVER:access({read, {1, 1, 0}, 0, 4}, S1),
    ?assertEqual(ops(model(S1)), ops(model(S2))),
    {{error, absent}, S3} = ?DRIVER:access({read, {0, 1, 0}, 0, 4}, S2),
    ?assertEqual(ops(model(S2)), ops(model(S3))),
    ?assertEqual([], ?MODEL:violations(model(S3))).

a_link_that_falls_answers_link_down_test() ->
    {ok, State} = open(#{boot => down}),
    Count = length(ops(model(State))),
    {ok, Fell} = open(#{boot => down, fall_at => Count + 1}),
    ?assertEqual(ops(model(State)), ops(model(Fell))),
    ?assertMatch({{error, link_down}, _}, ?DRIVER:access({read, {1, 0, 0}, 0, 4}, Fell)).

%% The target's start refuses until the PCIe domain is given the bridge's inbound
%% window, a configuration view of its window and a route to the firmware notification
%% (TODO.md, "the BCM2711 bridge's start").
the_start_refuses_until_its_facts_are_carried_test() ->
    ?assertEqual({error, enotsup}, ?DRIVER:start(bridge(), no_device)).

%% Firmware that still reads absent after a notification that answered ok holds the
%% VL805 back, logged, its register read once after the notification.
a_vl805_whose_firmware_stays_absent_is_not_ready_test() ->
    {ok, State} = open(#{boot => down, notify => ok}, ?MODULE),
    {{not_ready, Held}, Logged} = erx_pcie_log_capture:logged(fun() -> ?DRIVER:ready(vl805(), State) end),
    ?assertEqual(["pcie: bridge 3: vl805 firmware not loaded"], Logged),
    ?assert(notified(model(Held))),
    ?assertEqual([{cfg_read, ext_cfg_data, 16#50, 4}],
                 [Op || {cfg_read, ext_cfg_data, 16#50, 4} = Op <- ops(model(Held))]).

%% A link that falls under the firmware read ends the enumerator with link_down, as
%% an access that answers link_down does, logged, so the domain's restart recovers.
a_link_that_falls_under_the_firmware_read_ends_the_enumerator_test() ->
    {ok, State} = open(#{boot => down}),
    Count = length(ops(model(State))),
    {ok, Fell} = open(#{boot => down, fall_at => Count + 1}),
    {Result, Logged} = erx_pcie_log_capture:logged(fun() -> ?DRIVER:ready(vl805(), Fell) end),
    ?assertEqual({exit, link_down}, Result),
    ?assertEqual(["pcie: bridge 3: link down under the vl805 firmware read"], Logged).
