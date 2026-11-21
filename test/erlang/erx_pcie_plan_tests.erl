%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_pcie_plan, the planner (docs/design-pcie.md, "The plan" and "Host
%% tests of the pure cores"). Each plan runs against a model of configuration space: a
%% 256-byte snapshot each write is made to, parsed by erx_pcie_cfg after every write.
%% What a function reads as is judged here from the parsed value by the design's table,
%% written out apart from the module, so the module's own projection is not its oracle.
%%
%% The function is exhaustive over every switch state (I/O, memory, bus master, INTx,
%% MSI, MSI-X), every mode and route, each data field equal, differing alone or all
%% differing, and each MSI form (none, 32-bit, 32-bit with per-vector masking, 64-bit,
%% 64-bit with per-vector masking) with and without MSI-X. A root port is exhaustive over
%% its switch states, each data field equal or differing, and its window closed or open.
-module(erx_pcie_plan_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erx_pcie_cfg_tests, [blank/0, put/4]).

%% The inputs and the oracle erx_pcie_apply_tests runs the effect layer over.
-export([endpoint/4, layout/2, message/0, switch_states/2, data_fields/1, root_port/2, root_target/1,
         parsed/1, made/2, levels/1, data_view/1, data_ok/2, reads_as/2]).

-define(MESSAGE, #{address => 16#fee00000, data => 16#41}).
-define(BAR0, 16#fe000000).
-define(BAR2, 16#fe100000).
-define(DEADLINE, 600).

%% --- The model -------------------------------------------------------------------

puts(Snapshot, Fields) ->
    lists:foldl(fun({Offset, Bytes, Value}, S) -> put(S, Offset, Bytes, Value) end, Snapshot, Fields).

parsed(Snapshot) ->
    {ok, Read} = erx_pcie_cfg:parse(Snapshot),
    Read.

made(Snapshot, {Offset, Width, Value}) -> put(Snapshot, Offset, Width, Value).

message() -> ?MESSAGE.

%% --- The endpoint ----------------------------------------------------------------

%% An endpoint with a 64-bit memory BAR in registers 0 and 1, a 32-bit one in 2, an I/O
%% BAR in 3, MSI-X at 0x40 with its table in BAR 0 when Msix, and MSI at 0x50 of the form
%% Msi; its switches as Levels give them and Differing the data fields that differ from
%% the layout's and the message's.
endpoint(Msi, Msix, Levels, Differing) ->
    Differs = fun(Field) -> lists:member(Field, Differing) end,
    Caps = [{16#40, msix} || Msix] ++ [{16#50, msi} || Msi =/= none],
    Command = flag(maps:get(io, Levels), 16#1) bor flag(maps:get(memory, Levels), 16#2)
        bor flag(maps:get(master, Levels), 16#4) bor flag(1 - maps:get(intx, Levels), 16#400),
    Base = puts(blank(),
                [{16#00, 2, 16#1b36}, {16#02, 2, 16#000d}, {16#04, 2, Command}, {16#06, 2, 16#0010},
                 {16#09, 3, 16#0c0330}, {16#0e, 1, 0}, {16#3d, 1, 1},
                 {16#10, 4, pick(Differs(bar0), 16#fd000004, ?BAR0 bor 4)},
                 {16#14, 4, pick(Differs(bar0_high), 1, 0)},
                 {16#18, 4, pick(Differs(bar2), 16#fd100000, ?BAR2)},
                 {16#1c, 4, pick(Differs(bar3), 16#c001, 1)},
                 {16#34, 1, case Caps of [] -> 0; [{First, _} | _] -> First end}]),
    lists:foldl(fun({{At, Cap}, Next}, S) -> capability(Cap, At, Next, S, Msi, Levels, Differs) end,
                Base, lists:zip(Caps, tl([At || {At, _} <- Caps] ++ [0]))).

capability(msix, At, Next, S, _Msi, Levels, _Differs) ->
    Control = case maps:get(msix, Levels) of 0 -> 16#4000; 1 -> 16#c000; 2 -> 16#8000 end,
    puts(S, [{At, 1, 16#11}, {At + 1, 1, Next}, {At + 2, 2, Control},
             {At + 4, 4, 16#2000}, {At + 8, 4, 16#3000}]);
capability(msi, At, Next, S, Msi, Levels, Differs) ->
    Wide = Msi =:= msi64 orelse Msi =:= msi64_mask,
    Mask = Msi =:= msi32_mask orelse Msi =:= msi64_mask,
    Control = flag(maps:get(msi, Levels), 16#1) bor 16#4 bor flag(Differs(msi_mme), 16#10)
        bor flag(Wide, 16#80) bor flag(Mask, 16#100),
    DataAt = case Wide of true -> At + 16#c; false -> At + 8 end,
    puts(S, [{At, 1, 16#05}, {At + 1, 1, Next}, {At + 2, 2, Control},
             {At + 4, 4, pick(Differs(msi_address), 16#fee01000, 16#fee00000)},
             {DataAt, 2, pick(Differs(msi_data), 16#42, 16#41)}]
         ++ [{At + 8, 4, pick(Differs(msi_address_high), 1, 0)} || Wide]
         ++ [{At + 16#10, 4, pick(Differs(msi_mask), 1, 0)} || Wide andalso Mask]).

flag(true, Bit) -> Bit;
flag(false, _Bit) -> 0;
flag(1, Bit) -> Bit;
flag(0, _Bit) -> 0.

pick(true, Differing, _Equal) -> Differing;
pick(false, _Differing, Equal) -> Equal.

layout(Msi, Msix) ->
    Bar = fun(Kind, Flags, Address) -> #{kind => Kind, flags => Flags, size_log2 => 12, address => Address} end,
    #{bridge => 0, bus => 0, device => 1, function => 0, state => ready,
      vendor => 16#1b36, device_id => 16#000d, class_code => 16#010802, revision => 2, header => 0,
      subsystem_vendor => 16#1af4, subsystem => 16#1100, pin => 1,
      bars => [Bar(memory, [addr64, placed], ?BAR0), Bar(absent, [], 0), Bar(memory, [placed], ?BAR2),
               Bar(io, [], 0), Bar(absent, [], 0), Bar(absent, [], 0)],
      msi_offset => case Msi of none -> 0; _ -> 16#50 end,
      msi_flags => [addr64 || Msi =:= msi64 orelse Msi =:= msi64_mask]
          ++ [vector_mask || Msi =:= msi32_mask orelse Msi =:= msi64_mask],
      msi_vectors => 0,
      msix_offset => case Msix of true -> 16#40; false -> 0 end,
      msix_table_size => 0, msix_table_bar => 0, msix_table_offset => 0,
      express_offset => 0, express_type => 0, express_flags => []}.

%% --- The oracle ------------------------------------------------------------------

%% Each switch's level as Read gives it.
levels(#{command := Command, msi := Msi, msix := Msix}) ->
    maps:merge(#{io => bit(Command, 16#1), memory => bit(Command, 16#2), master => bit(Command, 16#4),
                 intx => 1 - bit(Command, 16#400)},
               maps:from_list([{msi, level(Enabled)} || #{enabled := Enabled} <- [Msi]]
                              ++ [{msix, msix_level(M)} || #{} = M <- [Msix]])).

msix_level(#{enabled := false}) -> 0;
msix_level(#{function_mask := true}) -> 1;
msix_level(#{function_mask := false}) -> 2.

bit(Value, Bit) -> level(Value band Bit =/= 0).

level(true) -> 1;
level(false) -> 0.

%% The design's table: the levels a target decides for each switch Read has.
target_levels({function, _Layout, #{mode := Mode, route := Route}}, Read) ->
    Live = level(Mode =:= mastering),
    All = #{io => 0, memory => level(Mode =/= off), master => Live,
            intx => case Route of intx -> Live; _ -> 0 end,
            msi => case Route of msi -> Live; _ -> 0 end,
            msix => case {Route, Mode} of {msix, decoding} -> 1; {msix, mastering} -> 2; _ -> 0 end},
    maps:with(maps:keys(levels(Read)), All);
target_levels({root_port, #{window := Window}}, Read) ->
    Open = level(Window =/= closed),
    maps:with(maps:keys(levels(Read)), #{io => 0, memory => Open, master => Open, intx => 0, msi => 0, msix => 0}).

%% The data fields the plan may move, as Read gives them.
data_view(#{bars := Bars, msi := Msi, bridge := Bridge}) ->
    {[Address || #{address := Address} <- Bars],
     case Msi of none -> none; #{address := A, data := D, mme := M, mask := K} -> {A, D, M, K} end,
     Bridge}.

%% Read holds the target's data: each BAR the layout's address, MSI the message for an
%% msi route, a root port its bus numbers and windows.
data_ok(#{bars := Bars} = Read, {function, _Layout, #{route := Route}}) ->
    [B0, _, B2, B3 | _] = [Address || #{address := Address} <- Bars],
    {B0, B2, B3} =:= {?BAR0, ?BAR2, 0}
        andalso (Route =/= msi orelse msi_ok(maps:get(msi, Read)));
data_ok(#{bridge := Bridge}, {root_port, #{buses := Buses, window := Window}}) ->
    {Base, Limit} = case Window of
                        closed -> {16#fff0, 0};
                        {First, Last} -> {(First bsr 16) band 16#fff0, (Last bsr 16) band 16#fff0}
                    end,
    Masked = fun(Name, Mask) -> maps:get(Name, Bridge) band Mask end,
    [Masked(primary_bus, 16#ff), Masked(secondary_bus, 16#ff), Masked(subordinate_bus, 16#ff)]
        =:= [maps:get(Name, Buses) || Name <- [primary_bus, secondary_bus, subordinate_bus]]
        andalso {Masked(memory_base, 16#fff0), Masked(memory_limit, 16#fff0)} =:= {Base, Limit}
        andalso {Masked(prefetch_base, 16#fff0), Masked(prefetch_limit, 16#fff0)} =:= {16#fff0, 0}
        andalso {Masked(io_base, 16#f0), Masked(io_limit, 16#f0)} =:= {16#f0, 0}
        andalso [maps:get(Name, Bridge) || Name <- [prefetch_base_upper, prefetch_limit_upper,
                                                    io_base_upper, io_limit_upper]] =:= [0, 0, 0, 0].

msi_ok(#{address := Address, data := Data, mme := Mme, mask := Mask}) ->
    #{address => Address, data => Data} =:= ?MESSAGE andalso Mme =:= 0 andalso lists:member(Mask, [none, 0]).

reads_as(Read, Target) ->
    levels(Read) =:= target_levels(Target, Read) andalso data_ok(Read, Target).

route_fits(#{msi := Msi, msix := Msix, pin := Pin}, {function, _Layout, #{route := Route}}) ->
    case Route of
        none -> true;
        msi -> Msi =/= none;
        msix -> Msix =/= none;
        intx -> Pin =/= 0
    end.

with_mode({function, Layout, Setting}, Mode) -> {function, Layout, Setting#{mode := Mode}}.

%% --- The properties --------------------------------------------------------------

%% The planner's answer for one function and target meets every property of "The plan".
check(Snapshot, Target) ->
    Read = parsed(Snapshot),
    Context = {Read, Target},
    case erx_pcie_plan:plan(Read, Target) of
        {error, gone} ->
            expect(false, never_gone, Context);
        {error, route} ->
            expect(not route_fits(Read, Target), route_refused, Context);
        {error, reset} ->
            expect(route_fits(Read, Target) andalso mastering_refused(Read, Target), reset_refused, Context);
        {ok, Stages} ->
            expect(not mastering_refused(Read, Target), mastering_rule, Context),
            expect((Stages =:= []) =:= reads_as(Read, Target), nothing_to_do, Context),
            expect(length(Stages) =< 3, at_most_three_stages, Context),
            Final = run(Snapshot, Read, Target, Stages, Context),
            expect(reads_as(parsed(Final), Target), ends_at_target, Context)
    end.

mastering_refused(Read, {function, _Layout, #{mode := mastering}} = Target) ->
    not (reads_as(Read, Target) orelse reads_as(Read, with_mode(Target, decoding)));
mastering_refused(_Read, _Target) ->
    false.


%% Makes each stage's writes to the model, checking each write and each stage as it goes,
%% then the order of lowerings and raisings across the plan; the final snapshot.
run(Snapshot0, Read0, Target, Stages, Context) ->
    {Final, Moves} = lists:foldl(fun(Stage, {Snapshot, Moves}) ->
                                         run_stage(Stage, Snapshot, Moves, Read0, Target, Context)
                                 end, {Snapshot0, []}, Stages),
    order(Moves, Context),
    Final.

run_stage(#{writes := Writes, state := State}, Snapshot, Moves, Read0, Target, Context) ->
    Snapshots = lists:reverse(lists:foldl(fun(Write, [S | _] = Acc) -> [made(S, Write) | Acc] end,
                                          [Snapshot], Writes)),
    Reads = [parsed(S) || S <- Snapshots],
    Pairs = lists:zip(lists:droplast(Reads), tl(Reads)),
    {Start, End} = {levels(hd(Reads)), levels(lists:last(Reads))},
    [check_write(Before, After, {Start, End}, Read0, Target, Context) || {Before, After} <- Pairs],
    expect(erx_pcie_plan:differs(lists:last(Reads), State) =:= none, stage_state, {Context, State}),
    {lists:last(Snapshots), Moves ++ [move(levels(Before), levels(After), Context) || {Before, After} <- Pairs]}.

%% One write: it carries every switch between the stage's two ends; it moves data only
%% while the model is quiet; after it no switch is above both what it read and what the
%% target decides, none is above what it read while data differ, none is below both
%% when no data differs (the floor is the lower of the two, never quiet for nothing),
%% and the start's rule takes the function on from there.
check_write(Before, After, {Start, End}, Read0, Target, Context) ->
    {Levels, Read, Decided} = {levels(After), levels(Read0), target_levels(Target, Read0)},
    Between = fun(Switch) ->
                      Level = maps:get(Switch, Levels),
                      Level >= min(maps:get(Switch, Start), maps:get(Switch, End))
                          andalso Level =< max(maps:get(Switch, Start), maps:get(Switch, End))
              end,
    expect(lists:all(Between, maps:keys(Levels)), one_way, {Context, After}),
    Quiet = fun(L) -> lists:all(fun(Level) -> Level =:= 0 end, maps:values(L)) end,
    expect(data_view(Before) =:= data_view(After) orelse (Quiet(levels(Before)) andalso Quiet(Levels)),
           data_while_quiet, {Context, After}),
    expect(lists:all(fun(Switch) -> maps:get(Switch, Levels) =< max(maps:get(Switch, Read), maps:get(Switch, Decided)) end,
                     maps:keys(Levels)), prefix_bounded, {Context, After}),
    expect(data_ok(After, Target)
               orelse lists:all(fun(Switch) -> maps:get(Switch, Levels) =< maps:get(Switch, Read) end, maps:keys(Levels)),
           raised_while_data_differ, {Context, After}),
    expect(not data_ok(Read0, Target)
               orelse lists:all(fun(Switch) -> maps:get(Switch, Levels) >= min(maps:get(Switch, Read), maps:get(Switch, Decided)) end,
                                maps:keys(Levels)),
           floor_minimal, {Context, After}),
    start_rule(After, Target, Context).

start_rule(Read, {function, _Layout, _Setting} = Target, Context) ->
    Start = erx_pcie_plan:start_target(Read, Target),
    Expected = case reads_as(Read, Target) of
                   true -> Target;
                   false -> with_mode(Target, off)
               end,
    expect(Start =:= Expected, start_target, {Context, Read}),
    expect(element(1, erx_pcie_plan:plan(Read, Start)) =:= ok, start_plans, {Context, Read});
start_rule(_Read, {root_port, _Port}, _Context) ->
    ok.

%% Which way a write moved the switches: never both.
move(Before, After, Context) ->
    Down = [Switch || Switch <- maps:keys(After), maps:get(Switch, After) < maps:get(Switch, Before)],
    Up = [Switch || Switch <- maps:keys(After), maps:get(Switch, After) > maps:get(Switch, Before)],
    expect(Down =:= [] orelse Up =:= [], one_direction, Context),
    case {Down, Up} of
        {[], []} -> none;
        {[], _} -> {up, Up};
        {_, []} -> {down, Down}
    end.

%% Every lowering precedes every raising; bus master is the first lowering and the last
%% raising.
order(Moves, Context) ->
    Ways = [Move || Move <- Moves, Move =/= none],
    expect(not lists:keymember(down, 1, lists:dropwhile(fun({Way, _}) -> Way =:= down end, Ways)),
           lowering_before_raising, Context),
    Downs = [Switches || {down, Switches} <- Ways],
    Ups = [Switches || {up, Switches} <- Ways],
    Lowered = lists:any(fun(Switches) -> lists:member(master, Switches) end, Downs),
    Raised = lists:any(fun(Switches) -> lists:member(master, Switches) end, Ups),
    expect(not Lowered orelse lists:member(master, hd(Downs)), master_lowered_first, Context),
    expect(not Raised orelse lists:member(master, lists:last(Ups)), master_raised_last, Context).

expect(true, _Property, _Context) -> ok;
expect(false, Property, Context) -> erlang:error({Property, Context}).

%% --- The endpoint, exhaustively --------------------------------------------------

-define(MSI_FORMS, [none, msi32, msi32_mask, msi64, msi64_mask]).

endpoint_test_() ->
    [{timeout, ?DEADLINE, {lists:flatten(io_lib:format("endpoint ~p msix ~p", [Msi, Msix])),
                           fun() -> endpoint_cases(Msi, Msix) end}}
     || Msi <- ?MSI_FORMS, Msix <- [false, true]].

endpoint_cases(Msi, Msix) ->
    Layout = layout(Msi, Msix),
    Fields = data_fields(Msi),
    lists:foreach(fun({Levels, Differing, Mode, Route}) ->
                          check(endpoint(Msi, Msix, Levels, Differing),
                                {function, Layout, #{mode => Mode, route => Route, message => ?MESSAGE}})
                  end,
                  [{Levels, Differing, Mode, Route}
                   || Levels <- switch_states(Msi =/= none, Msix),
                      Differing <- [[]] ++ [[Field] || Field <- Fields] ++ [Fields],
                      Mode <- [off, decoding, mastering],
                      Route <- [none, msi, msix, intx]]).

data_fields(Msi) ->
    Wide = Msi =:= msi64 orelse Msi =:= msi64_mask,
    [bar0, bar0_high, bar2, bar3]
        ++ [Field || Msi =/= none, Field <- [msi_address, msi_data, msi_mme]]
        ++ [msi_address_high || Wide]
        ++ [msi_mask || Msi =:= msi64_mask].

switch_states(Msi, Msix) ->
    [#{io => Io, memory => Memory, master => Master, intx => Intx, msi => M, msix => X}
     || Io <- [0, 1], Memory <- [0, 1], Master <- [0, 1], Intx <- [0, 1],
        M <- case Msi of true -> [0, 1]; false -> [0] end,
        X <- case Msix of true -> [0, 1, 2]; false -> [0] end].

%% --- quiet/1 ---------------------------------------------------------------------

quiet_lowers_every_switch_and_moves_no_data_test() ->
    lists:foreach(
      fun(Levels) ->
              Snapshot = endpoint(msi64_mask, true, Levels, [bar0, msi_address]),
              Read = parsed(Snapshot),
              {ok, Stages} = erx_pcie_plan:quiet(Read),
              Final = lists:foldl(fun(#{writes := Writes}, S) -> lists:foldl(fun(W, S1) -> made(S1, W) end, S, Writes) end,
                                  Snapshot, Stages),
              Quiet = parsed(Final),
              ?assert(length(Stages) =< 1),
              ?assertEqual(maps:map(fun(_, _) -> 0 end, levels(Read)), levels(Quiet)),
              ?assertEqual(data_view(Read), data_view(Quiet)),
              [?assertEqual(none, erx_pcie_plan:differs(Quiet, State)) || #{state := State} <- Stages]
      end, switch_states(true, true)).

%% --- Refusals and identity -------------------------------------------------------

a_route_the_function_cannot_take_is_refused_test() ->
    Read = parsed(endpoint(msi32, false, hd(switch_states(true, false)), [])),
    Layout = layout(msi32, false),
    Setting = fun(Route, Message) -> #{mode => decoding, route => Route, message => Message} end,
    ?assertEqual({error, route}, erx_pcie_plan:plan(Read, {function, Layout, Setting(msi, #{address => 1 bsl 32, data => 0})})),
    ?assertEqual({error, route}, erx_pcie_plan:plan(Read, {function, Layout, Setting(msi, #{address => 16#fee00000, data => 1 bsl 16})})),
    ?assertEqual({error, route}, erx_pcie_plan:plan(Read, {function, Layout, Setting(msix, ?MESSAGE)})),
    Pinless = parsed(put(endpoint(msi32, false, hd(switch_states(true, false)), []), 16#3d, 1, 0)),
    ?assertEqual({error, route}, erx_pcie_plan:plan(Pinless, {function, Layout#{pin := 0}, Setting(intx, ?MESSAGE)})).

another_identity_is_gone_test() ->
    Snapshot = endpoint(msi64, true, hd(switch_states(true, true)), []),
    Target = {function, layout(msi64, true), #{mode => off, route => none, message => ?MESSAGE}},
    Others = [put(Snapshot, 16#00, 2, 16#1af4),
              put(Snapshot, 16#18, 4, 16#c001),
              put(Snapshot, 16#52, 2, 16#0004),
              put(Snapshot, 16#06, 2, 0)],
    [?assertEqual({error, gone}, erx_pcie_plan:plan(parsed(Other), Target)) || Other <- Others],
    {ok, [#{state := State} | _]} = erx_pcie_plan:plan(parsed(Snapshot), with_mode(Target, decoding)),
    [?assertEqual(identity, erx_pcie_plan:differs(parsed(Other), State)) || Other <- Others],
    ?assertEqual({error, gone}, erx_pcie_plan:plan(parsed(Snapshot), {root_port, root_target(closed)})).

%% A command write carries the register's other bits as they read, and a BAR write
%% its read-only type bits.
writes_carry_the_bits_no_field_names_test() ->
    Levels = #{io => 0, memory => 1, master => 1, intx => 0, msi => 0, msix => 0},
    Snapshot = put(endpoint(none, false, Levels, [bar0]), 16#04, 2, 16#0106),
    Target = {function, layout(none, false), #{mode => off, route => none, message => ?MESSAGE}},
    {ok, [#{writes := Descent}, #{writes := Data}]} = erx_pcie_plan:plan(parsed(Snapshot), Target),
    ?assertEqual([{16#04, 2, 16#0102}, {16#04, 2, 16#0502}, {16#04, 2, 16#0500}], Descent),
    ?assertEqual([{16#10, 4, ?BAR0 bor 4}], Data).

%% --- The root port, exhaustively -------------------------------------------------

%% A root port with MSI at 0x50 and its bus numbers and windows as root_target({16#10000000,
%% 16#101fffff}) decides them, except the groups in Differing; its window registers' low
%% nibbles read as a 64-bit prefetchable and a 32-bit I/O window's.
root_port(Levels, Differing) ->
    Differs = fun(Group) -> lists:member(Group, Differing) end,
    Command = flag(maps:get(io, Levels), 16#1) bor flag(maps:get(memory, Levels), 16#2)
        bor flag(maps:get(master, Levels), 16#4) bor flag(1 - maps:get(intx, Levels), 16#400),
    puts(blank(),
         [{16#00, 2, 16#1b36}, {16#02, 2, 16#000c}, {16#04, 2, Command}, {16#06, 2, 16#0010},
          {16#09, 3, 16#060400}, {16#0e, 1, 1}, {16#34, 1, 16#50},
          {16#18, 1, 0}, {16#19, 1, pick(Differs(buses), 2, 1)}, {16#1a, 1, 1},
          {16#1c, 1, pick(Differs(io), 16#01, 16#f1)}, {16#1d, 1, 16#01},
          {16#20, 2, pick(Differs(memory), 16#2000, 16#1000)}, {16#22, 2, 16#1010},
          {16#24, 2, pick(Differs(prefetch), 16#0001, 16#fff1)}, {16#26, 2, 16#0001},
          {16#28, 4, 0}, {16#2c, 4, 0}, {16#30, 2, 0}, {16#32, 2, 0},
          {16#50, 1, 16#05}, {16#51, 1, 0}, {16#52, 2, flag(maps:get(msi, Levels), 16#1)}]).

root_target(Window) ->
    #{buses => #{primary_bus => 0, secondary_bus => 1, subordinate_bus => 1}, window => Window}.

root_port_test_() ->
    {timeout, ?DEADLINE,
     fun() ->
             Groups = [buses, io, memory, prefetch],
             [check(root_port(Levels, Differing), {root_port, root_target(Window)})
              || Levels <- switch_states(true, false),
                 Differing <- [[]] ++ [[Group] || Group <- Groups] ++ [Groups],
                 Window <- [closed, {16#10000000, 16#101fffff}]]
     end}.
