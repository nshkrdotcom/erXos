%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of the BCM2711 bridge's core, erx_pcie_bcm2711_core, against the register
%% model erx_pcie_bcm2711_model (docs/design-pcie.md, "Host tests of the pure cores";
%% docs/design-usb.md, "Verification", the bridge row): the keep-or-reset table over
%% every link and firmware reading, bring-up's order, values and waits, the tree's
%% refusals, the places an access reaches, the link around every access below the root
%% port, the notification after every PERST# cycle, and a link that falls before any
%% operation of each machine.
-module(erx_pcie_bcm2711_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_hw_bcm2711_pcie.hrl").

-define(CORE, erx_pcie_bcm2711_core).
-define(MODEL, erx_pcie_bcm2711_model).
-define(VL805, {1, 0, 0}).

%% The Raspberry Pi 4's bridge as its downstream tree gives it (facts record,
%% section 0): one 1 GiB outbound window at PCI 0xc0000000, CPU 0x6_00000000, and the
%% VL805 alone below the root port.
range(Pci, Cpu, Size) ->
    #{pci => Pci, cpu => Cpu, size => Size, flags => []}.

bridge() -> bridge([range(16#c0000000, 16#600000000, 16#40000000)]).

%% The record as the tree decodes it: window, inbound and place slots padded to their
%% limits (pcie_windows_max, pcie_closed_max), the unused ones zeroed, the tree's one
%% inbound window, and the VL805 in the second place slot, so erx_pcie:windows/1,
%% erx_pcie:inbound/1 and erx_pcie:places/1 do their filtering.
bridge(Windows) ->
    bridge(Windows, [unused_place(), #{bus => 1, device => 0, function => 0, pin => 1}]).

bridge(Windows, Places) ->
    #{index => 0, bus_first => 0, bus_last => 1, flags => [closed],
      windows => pad(Windows, range(0, 0, 0), 4), inbound => pad([inbound()], range(0, 0, 0), 4),
      places => pad(Places, unused_place(), 4)}.

unused_place() -> #{bus => 0, device => 0, function => 0, pin => 0}.

pad(Slots, Unused, Count) -> Slots ++ lists:duplicate(max(0, Count - length(Slots)), Unused).

%% The tree's dma-ranges: PCI 0 at CPU 0, 3 GiB.
inbound() -> range(0, 0, 16#c0000000).

%% The bridge with the inbound windows Inbound in place of the tree's one.
inbound(Inbound) -> (bridge())#{inbound := pad(Inbound, range(0, 0, 0), 4)}.

start(Options) -> start(Options, bridge()).

start(Options, Bridge) ->
    ?MODEL:run(?MODEL:new(Options), ?CORE:start(Bridge)).

%% start/1, then firmware/1 when it came up.
start_and_firmware(Options) ->
    case start(Options) of
        {{up, _} = Up, Core, Model} ->
            {Firmware, _, After} = ?MODEL:run(Model, ?CORE:firmware(Core)),
            {Up, Firmware, After};
        {Error, _, Model} -> {Error, none, Model}
    end.

ops(Model) -> [Op || {_Time, Op} <- ?MODEL:log(Model)].

writes(Model) -> [{Register, Word} || {write, Register, Word} <- ops(Model)].

perst_asserted(Model) ->
    [Word || {rgr1_sw_init_1, Word} <- writes(Model), ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_PERST_GET(Word) =:= 1].

notified(Model) -> lists:member(notify_firmware, ops(Model)).

last_write(Model, Register) ->
    lists:last([Word || {Written, Word} <- writes(Model), Written =:= Register]).

%% The keep-or-reset table (docs/design-usb.md,
%% "Keep or reset, decided from what the bridge reads"), every row.
the_keep_or_reset_table_test_() ->
    Rows = [{up, 16#000138c1, kept, not_run, present, false},
            {up, 0, reset, l23, present, true},
            {up, 16#ffffffff, reset, l23, present, true},
            {down, 0, reset, not_run, present, true},
            {down, 16#000138c1, reset, not_run, present, true}],
    [{lists:flatten(io_lib:format("link ~p, firmware ~.16#", [Link, Firmware])),
      fun() ->
              {{up, Up}, FirmwareResult, Model} = start_and_firmware(#{boot => Link, firmware => Firmware}),
              ?assertEqual(#{path => Path, turn_off => TurnOff}, Up),
              ?assertEqual({firmware, Present}, FirmwareResult),
              ?assertEqual(Notified, notified(Model)),
              ?assertEqual(Notified, perst_asserted(Model) =/= []),
              ?assertEqual([], ?MODEL:violations(Model))
      end}
     || {Link, Firmware, Path, TurnOff, Present, Notified} <- Rows].

a_kept_link_sees_no_perst_write_test() ->
    {{up, #{path := kept}}, Core, Model} = start(#{boot => up, firmware => 16#000138c1}),
    ?assertEqual([], perst_asserted(Model)),
    ?assertEqual([], [Op || {write, rgr1_sw_init_1, _} = Op <- ops(Model)]),
    {{firmware, present}, _, After} = ?MODEL:run(Model, ?CORE:firmware(Core)),
    ?assertNot(notified(After)),
    %% MISC_CTRL and the windows are written again with the tree's values.
    ?assertEqual([ext_cfg_index, misc_ctrl, bar2_config_lo, bar2_config_hi, bar1_config_lo, bar3_config_lo,
                  {win_lo, 0}, {win_hi, 0}, {win_base_limit, 0}, {win_base_hi, 0}, {win_limit_hi, 0}],
                 [Register || {Register, _} <- writes(Model)]).

%% Bring-up's writes and waits in the vendor's order (facts record, section 1, steps 3
%% and 6), from a link the boot left down.
bring_up_runs_in_the_vendors_order_test() ->
    {{up, #{path := reset}}, _, Model} = start(#{boot => down}),
    Sequence = [case Op of
                    {write, Register, _} -> Register;
                    {wait, Microseconds} -> {wait, Microseconds};
                    {read, misc_pcie_status} -> status;
                    {read, _} -> read
                end || Op <- ops(Model)],
    Expected = [status,
                read, rgr1_sw_init_1, read, rgr1_sw_init_1, {wait, 100}, read, rgr1_sw_init_1,
                read, hard_debug, {wait, 100},
                read, misc_ctrl, bar2_config_lo, bar2_config_hi, bar1_config_lo, bar3_config_lo,
                status,
                read, misc_ctrl, read, rc_cfg_priv1_id_val3,
                {win_lo, 0}, {win_hi, 0}, {win_base_limit, 0}, {win_base_hi, 0}, {win_limit_hi, 0},
                read, rc_cfg_vendor_specific_reg1, read, hard_debug,
                read, rgr1_sw_init_1, {wait, 100000}, status],
    %% The model's link is up at the first poll, the start's last operation.
    ?assertEqual(Expected, Sequence).

%% The words bring-up leaves, against the facts record's worked values for the Pi 4
%% (section 2: BAR2_CONFIG_LO 0x11, SCB0_SIZE 17; the downstream tree's window).
bring_up_writes_the_records_values_test() ->
    {{up, _}, _, Model} = start(#{boot => down}),
    MiscCtrl = last_write(Model, misc_ctrl),
    ?assertEqual(17, ?ERX_HW_BCM2711_PCIE_MISC_CTRL_SCB0_SIZE_GET(MiscCtrl)),
    ?assertEqual(0, ?ERX_HW_BCM2711_PCIE_MISC_CTRL_MAX_BURST_SIZE_GET(MiscCtrl)),
    ?assertEqual(1, ?ERX_HW_BCM2711_PCIE_MISC_CTRL_SCB_ACCESS_EN_GET(MiscCtrl)),
    ?assertEqual(1, ?ERX_HW_BCM2711_PCIE_MISC_CTRL_CFG_READ_UR_MODE_GET(MiscCtrl)),
    ?assertEqual(1, ?ERX_HW_BCM2711_PCIE_MISC_CTRL_RCB_MPS_MODE_GET(MiscCtrl)),
    ?assertEqual(1, ?ERX_HW_BCM2711_PCIE_MISC_CTRL_RCB_64B_MODE_GET(MiscCtrl)),
    ?assertEqual(16#11, last_write(Model, bar2_config_lo)),
    ?assertEqual(0, last_write(Model, bar2_config_hi)),
    ?assertEqual(0, last_write(Model, bar1_config_lo)),
    ?assertEqual(0, last_write(Model, bar3_config_lo)),
    ?assertEqual(16#060400, last_write(Model, rc_cfg_priv1_id_val3) band 16#ffffff),
    ?assertEqual(0, ?ERX_HW_BCM2711_PCIE_RC_CFG_VENDOR_SPECIFIC_REG1_ENDIAN_MODE_BAR2_GET(
                       last_write(Model, rc_cfg_vendor_specific_reg1))),
    HardDebug = last_write(Model, hard_debug),
    ?assertEqual(0, ?ERX_HW_BCM2711_PCIE_HARD_DEBUG_CLKREQ_DEBUG_ENABLE_GET(HardDebug)),
    ?assertEqual(0, ?ERX_HW_BCM2711_PCIE_HARD_DEBUG_L1SS_ENABLE_GET(HardDebug)),
    ?assertEqual(0, ?ERX_HW_BCM2711_PCIE_HARD_DEBUG_SERDES_IDDQ_GET(HardDebug)),
    ?assertEqual(0, last_write(Model, rgr1_sw_init_1)),
    ?assertEqual([16#c0000000, 0, 16#3ff00000, 6, 6],
                 [last_write(Model, {Register, 0}) || Register <- [win_lo, win_hi, win_base_limit, win_base_hi, win_limit_hi]]).

%% The mainline tree's window (facts record, section 0): 64 MiB at PCI 0xf8000000, CPU
%% 0x6_00000000. Its limit is the last MiB, 0x603f, as FreeBSD's encoder computes it
%% (bcm2838_pci.c:591-596); the facts record's worked value for it, 0x00300000 in
%% section 2, drops the low bits of that MiB.
an_outbound_window_takes_the_mainline_trees_values_test() ->
    {{up, _}, _, Model} = start(#{boot => down}, bridge([range(16#f8000000, 16#600000000, 16#4000000)])),
    ?assertEqual([16#f8000000, 0, 16#03f00000, 6, 6],
                 [last_write(Model, {Register, 0}) || Register <- [win_lo, win_hi, win_base_limit, win_base_hi, win_limit_hi]]).

%% Kept bits survive a read-modify-write: what no source names is written back.
a_read_modify_write_keeps_the_unnamed_bits_test() ->
    Model0 = ?MODEL:new(#{boot => down}),
    #{regs := Regs} = Model0,
    Seeded = Model0#{regs := Regs#{misc_ctrl => 16#000fc000, hard_debug => 16#10000000}},
    {{up, _}, _, Model} = ?MODEL:run(Seeded, ?CORE:start(bridge())),
    ?assertEqual(16#000fc000, last_write(Model, misc_ctrl) band 16#000fc000),
    ?assertEqual(16#10000000, last_write(Model, hard_debug) band 16#10000000).

the_first_endpoint_access_is_100_ms_after_perst_release_test() ->
    {{up, #{path := reset}}, {firmware, present}, Model} = start_and_firmware(#{boot => down, train_us => 1000}),
    ?assertEqual([], ?MODEL:violations(Model)),
    Log = ?MODEL:log(Model),
    [Release] = [Time || {Time, {write, rgr1_sw_init_1, Word}} <- Log,
                         ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_PERST_GET(Word) =:= 0,
                         ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_INIT_GET(Word) =:= 0],
    [First | _] = [Time || {Time, {cfg_read, ext_cfg_data, _, _}} <- Log],
    ?assert(First - Release >= 100000).

a_link_that_never_trains_fails_after_200_ms_test() ->
    {{error, link_down}, _, Model} = start(#{boot => down, trains => false}),
    Log = ?MODEL:log(Model),
    [Release] = [Time || {Time, {write, rgr1_sw_init_1, 0}} <- Log],
    {End, _} = lists:last(Log),
    ?assertEqual(200000, End - Release),
    Polls = [Time || {Time, {read, misc_pcie_status}} <- Log, Time > Release],
    ?assertEqual(21, length(Polls)).

an_endpoint_mode_block_fails_before_perst_is_released_test() ->
    {{error, endpoint_mode}, _, Model} = start(#{boot => down, endpoint => true}),
    ?assertEqual([], [Word || {rgr1_sw_init_1, Word} <- writes(Model),
                              ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_PERST_GET(Word) =:= 0]).

a_turn_off_whose_l23_never_comes_goes_on_after_15_polls_test() ->
    {{up, #{path := reset, turn_off := l23_timed_out}}, _, Model} =
        start(#{boot => up, firmware => 0, l23 => false}),
    Log = ?MODEL:log(Model),
    [Requested | _] = [Time || {Time, {write, misc_pcie_ctrl, 1}} <- Log],
    [Asserted | _] = [Time || {Time, {write, rgr1_sw_init_1, Word}} <- Log,
                              ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_PERST_GET(Word) =:= 1],
    ?assertEqual(14 * 2000, Asserted - Requested).

%% A tree whose windows break the rules touches no register.
the_trees_windows_are_refused_before_any_operation_test_() ->
    Ranges = [{dma_ranges, inbound([range(16#40000000, 0, 16#80000000)])},   % not a multiple of its size
              {dma_ranges, inbound([range(16#c0000000, 0, 16#40000000)])},   % between 2 and 4 GiB
              {dma_ranges, inbound([range(0, 16#1000, 16#c0000000)])},       % CPU side not at 0
              {dma_ranges, inbound([range(0, 0, 16#8000)])},                 % below 64 KiB
              {dma_ranges, inbound([range(0, 0, 16#2000000000)])},           % above 64 GiB
              {dma_ranges, inbound([])},                                     % no inbound window
              {dma_ranges, inbound([inbound(), range(16#100000000, 16#100000000, 16#10000)])},  % two
              {ranges, bridge([])},
              {ranges, bridge([(range(0, 0, 16#10000))#{flags := [io]}])},
              {ranges, bridge(lists:duplicate(5, range(16#c0000000, 16#600000000, 16#100000)))},
              {ranges, bridge([range(16#c0000000, 16#600080000, 16#100000)])},
              {ranges, bridge([range(16#c0000000, 16#600000000, 16#180000)])},
              {ranges, bridge([range(16#c0000000, 16#10000000000, 16#100000)])}],
    [fun() ->
             {{error, Reason}, _, Model} = start(#{boot => up, firmware => 16#000138c1}, Bridge),
             ?assertEqual(Expected, Reason),
             ?assertEqual([], ops(Model))
     end || {Expected, Bridge} <- Ranges].

%% A bridge whose every place slot is unused has no endpoint: start refuses it as a
%% bad record, touching no register.
a_bridge_with_no_endpoint_is_refused_before_any_operation_test() ->
    {{error, Reason}, _, Model} = start(#{boot => up, firmware => 16#000138c1}, bridge([range(16#c0000000, 16#600000000, 16#40000000)], [])),
    ?assertEqual(ranges, Reason),
    ?assertEqual([], ops(Model)).

%% An access does not need the endpoint: a bridge with no place slot in use still
%% reaches its root port.
an_access_needs_no_endpoint_test() ->
    {Result, _, _} = ?MODEL:run(?MODEL:new(#{boot => down}),
                                ?CORE:access({read, {0, 0, 0}, 16#3c, 2}, bridge([], []))),
    ?assertMatch({ok, _}, Result).

%% On bus 0 only the root port, below it only the listed place; every other place
%% answers absent with no operation (facts record, section 3, unknown 6).
places_the_bridge_does_not_reach_answer_absent_without_an_operation_test() ->
    Places = [{0, Device, Function} || Device <- lists:seq(0, 31), Function <- lists:seq(0, 7),
                                       {Device, Function} =/= {0, 0}]
        ++ [{1, Device, Function} || Device <- lists:seq(0, 31), Function <- lists:seq(0, 7),
                                     {Device, Function} =/= {0, 0}]
        ++ [{2, 0, 0}],
    lists:foreach(
      fun(Place) ->
              {Result, _, Model} = ?MODEL:run(?MODEL:new(#{boot => up}), ?CORE:access({read, Place, 0, 4}, bridge())),
              ?assertEqual({{error, absent}, []}, {Result, ops(Model)})
      end, Places).

the_root_port_is_read_in_its_own_space_test() ->
    {Result, _, Model} = ?MODEL:run(?MODEL:new(#{boot => down}), ?CORE:access({read, {0, 0, 0}, 16#3c, 2}, bridge())),
    ?assertEqual({ok, 0}, Result),
    ?assertEqual([{cfg_read, root_port, 16#3c, 2}], ops(Model)).

%% A record that called the bridge open would let reaches/2 grant every bus-0 place;
%% the bus-0 rule is the hardware's, so the core refuses them all the same.
the_bus_0_rule_holds_whatever_the_record_says_test() ->
    Open = (bridge())#{flags := [], bus_last := 255},
    lists:foreach(
      fun(Place) ->
              {Result, _, Model} = ?MODEL:run(?MODEL:new(#{boot => up}), ?CORE:access({read, Place, 0, 4}, Open)),
              ?assertEqual({{error, absent}, []}, {Result, ops(Model)})
      end, [{0, Device, Function} || Device <- lists:seq(0, 31), Function <- lists:seq(0, 7),
                                     {Device, Function} =/= {0, 0}]).

an_access_below_the_root_port_sits_between_two_link_reads_test() ->
    {Result, _, Model} = ?MODEL:run(?MODEL:new(#{boot => up}), ?CORE:access({read, ?VL805, 0, 4}, bridge())),
    ?assertEqual({ok, 16#34831106}, Result),
    Index = ?ERX_HW_BCM2711_PCIE_EXT_CFG_INDEX_BUS_PUT(1),
    ?assertEqual([{read, misc_pcie_status}, {write, ext_cfg_index, Index}, {cfg_read, ext_cfg_data, 0, 4},
                  {read, misc_pcie_status}], ops(Model)).

a_link_down_before_the_access_makes_none_test() ->
    {Result, _, Model} = ?MODEL:run(?MODEL:new(#{boot => down}), ?CORE:access({write, ?VL805, 4, 2, 6}, bridge())),
    ?assertEqual({error, link_down}, Result),
    ?assertEqual([{read, misc_pcie_status}], ops(Model)).

%% The link falls at the data read itself, the third operation: the read completes
%% with a plausible value, which the second link read keeps from being taken.
a_value_read_across_a_fall_is_not_taken_test() ->
    Model0 = ?MODEL:new(#{boot => up, firmware => 16#000138c1, fall_at => 3}),
    {Result, _, Model} = ?MODEL:run(Model0, ?CORE:access({read, ?VL805, 16#50, 4}, bridge())),
    ?assertEqual({error, link_down}, Result),
    ?assertEqual([{abort, 16#50}], ?MODEL:violations(Model)).

all_ones_at_offset_0_is_absent_test() ->
    Model0 = ?MODEL:new(#{boot => up}),
    {Result, _, _} = ?MODEL:run(Model0, ?CORE:access({read, ?VL805, 0, 2}, bridge())),
    ?assertEqual({ok, 16#1106}, Result),
    ?assertEqual({error, absent}, erx_pcie_bridge:read_answer(0, 2, 16#ffff)),
    ?assertEqual({ok, 16#ffff}, erx_pcie_bridge:read_answer(2, 2, 16#ffff)).

%% PERST# cleared the VL805's firmware, so the reset path ends with the notification,
%% 1 ms, and the firmware register read again (docs/design-pcie.md, the endpoint's
%% firmware).
bring_up_ends_with_the_notification_test() ->
    {{up, #{path := reset}}, Core, Model} = start(#{boot => down}),
    ?assertEqual(0, ?MODEL:firmware_register(Model)),
    {Result, _, After} = ?MODEL:run(Model, ?CORE:firmware(Core)),
    ?assertEqual({firmware, present}, Result),
    Firmware = lists:nthtail(length(ops(Model)), ops(After)),
    ?assertMatch([notify_firmware, {wait, 1000}, {read, misc_pcie_status}, {write, ext_cfg_index, _},
                  {cfg_read, ext_cfg_data, 16#50, 4}, {read, misc_pcie_status}], Firmware).

a_refused_notification_is_not_loaded_and_reads_nothing_more_test() ->
    {{up, #{path := reset}}, Core, Model} = start(#{boot => down}),
    {Core1, notify_firmware} = ?CORE:firmware(Core),
    ?assertEqual({done, {firmware, not_loaded}}, element(2, ?CORE:step({error, timed_out}, Core1))),
    ?assertEqual(0, ?MODEL:firmware_register(Model)).

%% The link falls before each operation in turn of the three paths: kept, reset from
%% a link up, and bring-up from a link down. Whatever the step, no access locks up the
%% memory controller, none comes within 100 ms of PERST#'s release, a value read with
%% the link down is never taken, a kept bridge sees no PERST#, and a bridge that comes
%% up after a PERST# cycle is notified.
a_link_that_falls_at_any_step_is_never_misread_test_() ->
    Paths = [#{boot => up, firmware => 16#000138c1}, #{boot => up, firmware => 0}, #{boot => down}],
    [fun() -> falls_at_every_step(Options) end || Options <- Paths].

falls_at_every_step(Options) ->
    {_, _, Clean} = start_and_firmware(Options),
    lists:foreach(fun(Step) -> fall_holds(Options, Step) end, lists:seq(1, length(ops(Clean)))).

fall_holds(Options, Step) ->
    {Start, Core, Started} = start(Options#{fall_at => Step}),
    Context = {Options, Step, Start},
    ?assertEqual({Context, []}, {Context, not_aborts(?MODEL:violations(Started))}),
    case Start of
        {up, #{path := kept}} ->
            %% A kept bridge decided from a read made with the link up.
            ?assertEqual({Context, [], []}, {Context, perst_asserted(Started), ?MODEL:violations(Started)});
        {up, #{path := reset}} ->
            {Firmware, _, After} = ?MODEL:run(Started, ?CORE:firmware(Core)),
            ?assert(notified(After)),
            Later = lists:nthtail(length(?MODEL:violations(Started)), ?MODEL:violations(After)),
            ?assertEqual({Context, []}, {Context, not_aborts(Later)}),
            Later =:= [] orelse ?assertEqual({Context, {error, link_down}}, {Context, Firmware});
        {error, link_down} -> ok
    end.

not_aborts(Violations) -> [Violation || {Kind, _} = Violation <- Violations, Kind =/= abort].
