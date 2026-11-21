%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The enumerator's start and its pcie operations (docs/design-pcie.md, "Facets",
%% "The plan"), run as the process over an ECAM bridge on erx_pcie_model and a model
%% device service: the bus edge answers targets as the case gives them, keeps the
%% report, and answers it with the case's settings.
-module(erx_pcie_enumerator_tests).

%% A bridge driver of the cases (a_held_function_whose_start_failed_is_not_ready_test).
-export([access/2, ready/2]).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-import(erx_pcie_cfg_tests, [put/4, endpoint/0]).

-define(BRIDGE, 3).
-define(PLACE, {0, 1, 0}).
-define(KEY, {?BRIDGE, 0, 1, 0}).
-define(WINDOW, 16#10000000).

%% The endpoint fixture as a single-function device, with the walk tests' BAR masks.
endpoint_at(Place, Snapshot) ->
    {Place, put(Snapshot, 16#0e, 1, 16#00),
     #{16#10 => 16#fffff000, 16#14 => 16#ffffffc0, 16#18 => 16#ffffc000, 16#1c => 16#ffffffff,
       16#20 => 0, 16#24 => 0}}.

%% An open bridge with one 256 MiB memory window at PCI address 0x10000000.
bridge() ->
    Window = #{pci => 0, cpu => 0, size => 0, flags => []},
    Place = #{bus => 0, device => 0, function => 0, pin => 0},
    Record = #{index => ?BRIDGE, bus_first => 0, bus_last => 255, flags => [],
               windows => [#{pci => ?WINDOW, cpu => ?WINDOW, size => 16#10000000, flags => []}
                           | lists:duplicate(?ERX_PCIE_WINDOWS_MAX - 1, Window)],
               places => lists:duplicate(?ERX_PCIE_CLOSED_MAX, Place)},
    {ok, Bridge} = erx_abi_layout:decode(erx_pcie_bridge, erx_abi_layout:encode(erx_pcie_bridge, Record)),
    Bridge.

setting(Mode) -> #{mode => Mode, route => none, message => #{address => 0, data => 0}}.

%% The enumerator started over Table with the targets given, its report answered with
%% Answer; returns the enumerator and what it reported once its start is done.
started(Table, Layouts, Settings, Answer) ->
    Reports = ets:new(reports, [public]),
    Bus = fun(targets) -> {ok, [bridge()], Layouts, Settings};
             ({report, Reported}) -> ets:insert(Reports, {report, Reported}), {ok, Answer}
          end,
    Open = fun(Bridge) ->
                   {ok, State} = erx_pcie_ecam:open(Bridge, {erx_pcie_model, {Table, 0}}),
                   {ok, {erx_pcie_ecam, State}}
           end,
    {ok, Pid} = erx_pcie_enumerator:start_link(#{bus => Bus, open => Open, sleep => fun(_) -> ok end}),
    _ = sys:get_state(Pid),
    [{report, Reported}] = ets:lookup(Reports, report),
    {Pid, Reported}.

stop(Pid) ->
    unlink(Pid),
    exit(Pid, kill).

command(Table) -> erx_pcie_model:register(Table, ?PLACE, {16#04, 2}).

%% The placing start's report, with the function's BARs written by it.
placed() ->
    Table = erx_pcie_model:new([endpoint_at(?PLACE, endpoint())]),
    {Pid, [#{record := Record}] = Reported} = started(Table, [], #{}, #{}),
    stop(Pid),
    {Table, Record, Reported}.

a_placing_start_reports_each_function_placed_in_the_window_and_writes_its_bars_test() ->
    {Table, Record, [#{kept := Kept}]} = placed(),
    #{state := ready, bridge := ?BRIDGE, vendor := 16#1af4, device_id := 16#1041,
      bars := [Bar0, _, Bar2 | _], msix_offset := 16#40, msi_offset := 16#50} = Record,
    ?assertMatch(#{kind := memory, size_log2 := 12, flags := [placed]}, Bar0),
    ?assertMatch(#{kind := memory, size_log2 := 14, flags := [addr64, prefetchable, placed]}, Bar2),
    #{address := Address0} = Bar0,
    #{address := Address2} = Bar2,
    ?assert(Address0 >= ?WINDOW andalso Address2 >= ?WINDOW),
    ?assertEqual(Address0, erx_pcie_model:register(Table, ?PLACE, {16#10, 4}) band 16#fffff000),
    ?assertEqual(Address2, erx_pcie_model:register(Table, ?PLACE, {16#18, 4}) band 16#ffffc000),
    %% The start's target is the layout in mode off: every switch quiet, and kept.
    ?assertEqual(0, command(Table) band 16#7),
    ?assert(Kept).

a_later_start_applies_an_answered_setting_and_serves_set_test() ->
    {_, Layout, _} = placed(),
    Table = erx_pcie_model:new([endpoint_at(?PLACE, endpoint())]),
    {Pid, [#{record := Record, kept := true}]} = started(Table, [Layout], #{}, #{?KEY => setting(decoding)}),
    ?assertEqual(Layout#{state := ready}, Record),
    ?assertEqual(16#2, command(Table) band 16#7),
    ?assertEqual(ok, erx_pcie_enumerator:set(Pid, ?KEY, setting(off))),
    ?assertEqual(0, command(Table) band 16#7),
    ?assertEqual({error, unknown}, erx_pcie_enumerator:set(Pid, {?BRIDGE, 0, 2, 0}, setting(off))),
    stop(Pid).

a_function_with_another_identity_is_reported_unplaced_and_lowered_test() ->
    {_, Layout, _} = placed(),
    Table = erx_pcie_model:new([endpoint_at(?PLACE, put(endpoint(), 16#02, 2, 16#1042))]),
    {Pid, [#{record := Record, kept := false}]} = started(Table, [Layout], #{?KEY => setting(decoding)}, #{}),
    stop(Pid),
    ?assertMatch(#{state := unplaced, device_id := 16#1042}, Record),
    ?assertEqual(0, command(Table) band 16#7).

%% A function changed where the planner's identity does not look, here its subsystem,
%% is reported as the walk read it, with its layout's BAR sizes and addresses, so the
%% library's intake sees the change.
a_later_record_is_what_the_walk_read_test() ->
    {_, Layout, _} = placed(),
    Table = erx_pcie_model:new([endpoint_at(?PLACE, put(endpoint(), 16#2e, 2, 16#1101))]),
    {Pid, [#{record := Record}]} = started(Table, [Layout], #{}, #{}),
    stop(Pid),
    ?assertEqual(Layout#{state := ready, subsystem := 16#1101}, Record).

%% A master request refused by the mastering rule turns the function off: here its BAR
%% was rewritten behind the enumerator's back while it decoded.
a_set_refused_by_the_mastering_rule_turns_the_function_off_test() ->
    {_, Layout, _} = placed(),
    Table = erx_pcie_model:new([endpoint_at(?PLACE, endpoint())]),
    {Pid, _} = started(Table, [Layout], #{}, #{?KEY => setting(decoding)}),
    ?assertEqual(16#2, command(Table) band 16#7),
    erx_pcie_model:config_write({Table, 0}, {function, 8}, 16#10, 4, 16#0fff0000),
    ?assertEqual({error, reset}, erx_pcie_enumerator:set(Pid, ?KEY, setting(mastering))),
    ?assertEqual(0, command(Table) band 16#7),
    #{bars := [#{address := Address0} | _]} = Layout,
    ?assertEqual(Address0, erx_pcie_model:register(Table, ?PLACE, {16#10, 4}) band 16#fffff000),
    stop(Pid).

a_function_level_reset_initiates_the_reset_and_returns_to_decoding_test() ->
    {_, Layout, _} = placed(),
    Table = erx_pcie_model:new([endpoint_at(?PLACE, endpoint())]),
    {Pid, _} = started(Table, [Layout], #{}, #{?KEY => setting(decoding)}),
    ?assertEqual({ok, flr}, erx_pcie_enumerator:reset(Pid, ?KEY)),
    ?assertEqual(16#2, command(Table) band 16#7),
    ?assertNotEqual(0, erx_pcie_model:register(Table, ?PLACE, {16#78, 2}) band 16#8000),
    stop(Pid).

%% A layout the placing walk left unplaced keeps its state at a later start: it is
%% lowered to quiet, never started, and set refuses it.
a_layout_left_unplaced_stays_unplaced_and_is_never_driven_test() ->
    {_, Layout, _} = placed(),
    Table = erx_pcie_model:new([endpoint_at(?PLACE, endpoint())]),
    {Pid, [#{record := Record, kept := false}]} = started(Table, [Layout#{state := unplaced}], #{}, #{}),
    ?assertMatch(#{state := unplaced}, Record),
    ?assertEqual(0, command(Table) band 16#7),
    ?assertEqual({error, unknown}, erx_pcie_enumerator:set(Pid, ?KEY, setting(decoding))),
    stop(Pid).

%% A function a previous incarnation left mastering whose later record differs from its
%% layout only where the planner's identity does not look, here its subsystem, starts
%% at off and is reported not kept, whatever its setting: the intake leaves it
%% unconfirmed and gives it to no one, so it must not go on mastering
%% ("Failure handling and restart"). Neither an answer raising it nor a set does.
a_changed_function_starts_off_whatever_its_setting_test() ->
    {_, Layout, _} = placed(),
    Table = erx_pcie_model:new([endpoint_at(?PLACE, endpoint())]),
    {First, _} = started(Table, [Layout], #{}, #{?KEY => setting(decoding)}),
    ok = erx_pcie_enumerator:set(First, ?KEY, setting(mastering)),
    stop(First),
    ?assertEqual(16#6, command(Table) band 16#7),
    ok = erx_pcie_model:config_write({Table, 0}, {function, 8}, 16#2e, 2, 16#1101),
    {Pid, [#{record := Record, kept := Kept}]} =
        started(Table, [Layout], #{?KEY => setting(mastering)}, #{?KEY => setting(decoding)}),
    ?assertMatch(#{state := ready, subsystem := 16#1101}, Record),
    ?assertNot(Kept),
    ?assertEqual(0, command(Table) band 16#7),
    ?assertEqual({error, unknown}, erx_pcie_enumerator:set(Pid, ?KEY, setting(decoding))),
    ?assertEqual(0, command(Table) band 16#7),
    stop(Pid).

%% A bridge driver that holds every function back and drops every write of the command
%% register, so the function keeps the fixture's decoding command, the start's readback
%% differs and its apply answers an error (`stuck`): a held function is reported
%% not_ready on that path too, since `ready` is the one funnel to a ready report
%% (docs/design-pcie.md, "The bridge seam").

access({write, _Place, 16#04, 2, _Value}, State) ->
    {ok, State};
access(Access, State) ->
    erx_pcie_ecam:access(Access, State).

ready(_Function, State) -> {not_ready, State}.

a_held_function_whose_start_failed_is_not_ready_test() ->
    Table = erx_pcie_model:new([endpoint_at(?PLACE, endpoint())]),
    Reports = ets:new(reports, [public]),
    Bus = fun(targets) -> {ok, [bridge()], [], #{}};
             ({report, Reported}) -> ets:insert(Reports, {report, Reported}), {ok, #{}}
          end,
    Open = fun(Bridge) ->
                   {ok, State} = erx_pcie_ecam:open(Bridge, {erx_pcie_model, {Table, 0}}),
                   {ok, {?MODULE, State}}
           end,
    {ok, Pid} = erx_pcie_enumerator:start_link(#{bus => Bus, open => Open, sleep => fun(_) -> ok end}),
    _ = sys:get_state(Pid),
    [{report, [#{record := Record, kept := Kept}]}] = ets:lookup(Reports, report),
    stop(Pid),
    ?assertEqual(not_ready, maps:get(state, Record)),
    ?assertNot(Kept).
