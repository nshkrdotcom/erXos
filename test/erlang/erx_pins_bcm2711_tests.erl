%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_pins_bcm2711's planner (docs/design-pinctrl.md, "The plan" and "Verification"),
%% over readings and erx_pins_model. test/host/erx_pins_test.rb runs these cases and,
%% for each seeded fault, the case that must fail.
-module(erx_pins_bcm2711_tests).

-include_lib("eunit/include/eunit.hrl").

-define(K, erx_pins_bcm2711).
-define(ROUNDS, 3000).

base() ->
    {ok, Registers} = ?K:registers(lists:seq(0, 57)),
    maps:from_list([{Register, 0} || Register <- Registers] ++
                   [{gpeds0, 0}, {gpeds1, 0}]).

alt(N) -> #{function => N}.
out(Level) -> #{function => out, level => Level}.

applied(Read, Wanted) ->
    {ok, Steps} = ?K:plan(Read, Wanted),
    erx_pins_model:reading(erx_pins_model:apply(erx_pins_model:new(Read), Steps)).

uart0() -> [{Pin, alt(3)} || Pin <- [30, 31, 32, 33]].

%% The board's GPFSEL3 at boot, 0x00000fc0, with GPIO 34 to 39 given fields of their own.
uart0_from_the_board_reading_test() ->
    Read = (base())#{gpfsel3 => 16#00000fc0 bor 16#3ffff000},
    ?assertEqual({ok, [{field, [30, 31], gpfsel3, 16#3f, 16#3f}]}, ?K:plan(Read, uart0())),
    ?assertEqual(16#3fffffff, maps:get(gpfsel3, applied(Read, uart0()))).

alternate_codes_test() ->
    Read = base(),
    ?assertEqual({ok, [{field, [14, 15], gpfsel1, 16#3f000, 16#12000}]},
                 ?K:plan(Read, [{14, alt(5)}, {15, alt(5)}])),
    ?assertEqual({ok, [{field, [22], gpfsel2, 16#1c0, 16#c0}]}, ?K:plan(Read, [{22, alt(4)}])).

refused_plan_returns_no_step_test() ->
    Read = base(),
    ?assertEqual({error, {58, no_such_pin}}, ?K:plan(Read, [{20, out(1)}, {58, out(1)}])),
    ?assertEqual({error, {20, out_without_level}}, ?K:plan(Read, [{20, #{function => out}}])),
    ?assertEqual({error, {20, level_without_out}}, ?K:plan(Read, [{20, #{function => in, level => 1}}])),
    ?assertEqual({error, {21, bad_function}}, ?K:plan(Read, [{20, alt(1)}, {21, alt(6)}])),
    ?assertEqual({error, {20, twice}}, ?K:plan(Read, [{20, alt(1)}, {20, alt(2)}])),
    ?assertEqual({error, {20, {unread, gpfsel2}}}, ?K:plan(maps:remove(gpfsel2, Read), [{20, alt(1)}])).

check_by_planning_again_test() ->
    Read = base(),
    {ok, Steps} = ?K:plan(Read, uart0()),
    Applied = erx_pins_model:reading(erx_pins_model:apply(erx_pins_model:new(Read), Steps)),
    ?assertEqual({ok, []}, erx_pins_core:unset(?K, Applied, uart0())),
    Dropped = erx_pins_model:new(Read, #{drop => {gpfsel3, 31, 3, 3}}),
    ?assertEqual({ok, [31]}, erx_pins_core:unset(?K, erx_pins_model:reading(erx_pins_model:apply(Dropped, Steps)),
                                                 uart0())),
    Held = erx_pins_model:new(Read, #{wire => #{20 => 0}}),
    {ok, Out} = ?K:plan(Read, [{20, out(1)}]),
    ?assertEqual({ok, [20]}, erx_pins_core:unset(?K, erx_pins_model:reading(erx_pins_model:apply(Held, Out)),
                                                 [{20, out(1)}])).

idempotent_test() ->
    Wanted = [{20, out(1)}, {21, alt(4)}, {34, #{function => 3, pull => none}}],
    Applied = applied(base(), Wanted),
    ?assertEqual({ok, []}, ?K:plan(Applied, Wanted)).

level_is_a_command_test() ->
    Read = (base())#{gplev0 => 16#ffffffff},
    ?assertEqual({ok, [{command, [20], gpset0, 1 bsl 20}, {field, [20], gpfsel2, 16#7, 16#1}]},
                 ?K:plan(Read, [{20, out(1)}])),
    AlreadyOut = Read#{gpfsel2 => 16#1},
    ?assertEqual({ok, []}, ?K:plan(AlreadyOut, [{20, out(1)}])),
    ?assertEqual({ok, [{command, [20], gpclr0, 1 bsl 20}]}, ?K:plan(AlreadyOut, [{20, out(0)}])).

events_acknowledge_own_pins_test() ->
    Read = (base())#{gpeds0 => (1 bsl 15) bor (1 bsl 20) bor (1 bsl 21)},
    {ok, Fired, Ack} = ?K:events(Read, [20, 21, 22]),
    ?assertEqual([20, 21], Fired),
    ?assertEqual([{command, [20, 21], gpeds0, (1 bsl 20) bor (1 bsl 21)}], Ack),
    After = erx_pins_model:reading(erx_pins_model:apply(erx_pins_model:new(Read), Ack)),
    ?assertEqual(1 bsl 15, maps:get(gpeds0, After)),
    ?assertMatch({ok, [20], _}, ?K:events(After#{gpeds0 => (1 bsl 15) bor (1 bsl 20)}, [20, 21])).

wifi_pulls_test() ->
    Read = (base())#{pup_pdn2 => 16#50aaa95a},
    Wanted = [{34, #{function => 3, pull => none}} | [{Pin, #{function => 3, pull => up}} || Pin <- lists:seq(35, 39)]],
    {ok, [Pull | _]} = ?K:plan(Read, Wanted),
    ?assertEqual({field, [34, 37, 38, 39], pup_pdn2, 16#fff0 band bnot 16#3c0, 16#5400}, Pull),
    ?assertEqual(16#50aa554a, maps:get(pup_pdn2, applied(Read, Wanted))).

no_pull_written_without_one_test() ->
    Read = (base())#{pup_pdn1 => 16#a0aaaaaa},
    {ok, Steps} = ?K:plan(Read, [{20, alt(4)}, {21, out(0)}]),
    ?assertEqual([], [Step || {field, _, Register, _, _} = Step <- Steps,
                              lists:member(Register, [pup_pdn0, pup_pdn1, pup_pdn2, pup_pdn3])]).

pulls_up_and_down_test() ->
    Read = (base())#{pup_pdn1 => 0},
    ?assertEqual({ok, [{field, [20, 21], pup_pdn1, 16#f00, 16#900}]},
                 ?K:plan(Read, [{20, #{function => in, pull => up}}, {21, #{function => in, pull => down}}])).

write_order_test() ->
    Read = (base())#{pup_pdn1 => 2 bsl 8},
    Wanted = [{20, #{function => out, level => 1, pull => up}}],
    {ok, Steps} = ?K:plan(Read, Wanted),
    ?assertEqual([pup_pdn1, gpset0, gpfsel2], [element(3, Step) || Step <- Steps]),
    {_, Glitches} = erx_pins_model:apply_sampled(erx_pins_model:new(Read), Steps, Wanted),
    ?assertEqual([], Glitches).

edges_test() ->
    Read = base(),
    ?assertEqual({ok, [{field, [20], gpfen0, 1 bsl 20, 1 bsl 20}, {field, [20], gpren0, 1 bsl 20, 1 bsl 20}]},
                 ?K:plan(Read#{gpfsel2 => 0}, [{20, #{function => in, edge => both}}])),
    Idle = erx_pins_core:idle(),
    ?assertEqual({ok, [{field, [20], gpren0, 1 bsl 20, 0}]},
                 ?K:plan(Read#{gpren0 => 1 bsl 20}, [{20, Idle}])).

%% A pin's edge setting gives its bit in all six detect enables, in both banks: idle clears
%% every one, and rising leaves GPREN's bit alone set.
every_detect_enable_test() ->
    Enables = [{Register, 20} || Register <- [gpren0, gpfen0, gphen0, gplen0, gparen0, gpafen0]] ++
              [{Register, 40} || Register <- [gpren1, gpfen1, gphen1, gplen1, gparen1, gpafen1]],
    Read = maps:merge((base())#{gpfsel2 => 0, gpfsel4 => 0},
                      maps:from_list([{Register, 1 bsl (Pin rem 32)} || {Register, Pin} <- Enables])),
    Idle = erx_pins_core:idle(),
    ?assertEqual({ok, [{field, [Pin], Register, 1 bsl (Pin rem 32), 0} || {Register, Pin} <- lists:sort(Enables)]},
                 ?K:plan(Read, [{20, Idle}, {40, Idle}])),
    ?assertEqual({ok, [{field, [20], Register, 1 bsl 20, 0} || {Register, 20} <- lists:sort(Enables),
                                                                Register =/= gpren0]},
                 ?K:plan(Read, [{20, #{function => in, edge => rising}}])).

%% A setting that names no edge is edge none: a device's pin detects nothing, whatever
%% enable the firmware or an earlier holder left set.
no_edge_is_none_test() ->
    Read = (base())#{gpfsel2 => 0, gphen0 => 1 bsl 20, gpren0 => 1 bsl 20},
    {ok, Steps} = ?K:plan(Read, [{20, alt(4)}]),
    ?assertEqual([{field, [20], gphen0, 1 bsl 20, 0}, {field, [20], gpren0, 1 bsl 20, 0}],
                 [Step || {field, _, Register, _, _} = Step <- Steps, Register =/= gpfsel2]).

%% A reading names the edge its six enables give, the enables set where no edge gives
%% them, and unknown where the reading lacks one of them.
setting_test() ->
    Read = (base())#{gpfsel1 => 16#12000, pup_pdn0 => 3 bsl 28, gplev0 => 1 bsl 14},
    ?assertEqual({ok, #{function => 5, pull => 3, level => 1, edge => none}}, ?K:setting(Read, 14)),
    ?assertEqual({ok, #{function => in, pull => none, level => unknown, edge => none}},
                 ?K:setting(maps:remove(gplev0, Read), 12)),
    ?assertMatch({ok, #{edge := both}}, ?K:setting(Read#{gpren0 => 1 bsl 14, gpfen0 => 1 bsl 14}, 14)),
    ?assertMatch({ok, #{edge := [gplen]}}, ?K:setting(Read#{gplen0 => 1 bsl 14}, 14)),
    ?assertMatch({ok, #{edge := unknown}}, ?K:setting(maps:remove(gpafen0, Read), 14)).

%% A pin past 57, or a setting key the kind does not know, is refused by every entry the
%% way a plan refuses, never raised on or ignored.
refused_pins_and_keys_test() ->
    ?assertEqual({error, {58, no_such_pin}}, ?K:registers([20, 58])),
    ?assertEqual({error, {58, no_such_pin}}, ?K:setting(base(), 58)),
    ?assertEqual({error, {58, no_such_pin}}, ?K:events(base(), [20, 58])),
    ?assertEqual({error, {gpio, no_such_pin}}, ?K:events(base(), [gpio])),
    ?assertEqual({error, {20, {unknown_key, pul}}}, ?K:plan(base(), [{20, #{function => in, pul => up}}])).

%% Total over any reading: for random words, missing registers and words that are not
%% words, the plan returns; its writes touch only the wanted pins' fields and bits; and
%% applied to the model, it leaves nothing to plan.
total_over_any_reading_test_() ->
    {timeout, 120, fun() ->
                           rand:seed(exsss, {20, 26, 1123}),
                           Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), one_round() =:= accepted]),
                           ?assert(Accepted >= ?ROUNDS div 2)
                   end}.

one_round() ->
    Read = reading(),
    Wanted = wanted(),
    case catch_plan(Read, Wanted) of
        {ok, Steps} ->
            Allowed = allowed(Wanted),
            [?assertEqual({Step, 0}, {Step, masks(Step) band bnot maps:get(element(3, Step), Allowed, 0)})
             || Step <- Steps],
            [?assertEqual({Step, 0}, {Step, Bits band bnot Mask}) || {field, _, _, Mask, Bits} = Step <- Steps],
            After = erx_pins_model:reading(erx_pins_model:apply(erx_pins_model:new(Read), Steps)),
            ?assertEqual({Read, Wanted, {ok, []}}, {Read, Wanted, ?K:plan(After, Wanted)}),
            accepted;
        {error, {_Pin, _Reason}} ->
            refused
    end.

catch_plan(Read, Wanted) ->
    try ?K:plan(Read, Wanted)
    catch Class:Reason -> error({raised, Read, Wanted, Class, Reason})
    end.

masks({field, _, _, Mask, Bits}) -> Mask bor Bits;
masks({command, _, _, Bits}) -> Bits.

%% Each register's bits that the wanted pins have fields or bits in.
allowed(Wanted) ->
    lists:foldl(fun({Pin, _}, Acc) ->
                        Fields = [{element(Pin div 10 + 1, {gpfsel0, gpfsel1, gpfsel2, gpfsel3, gpfsel4, gpfsel5}),
                                   7 bsl (3 * (Pin rem 10))},
                                  {element(Pin div 16 + 1, {pup_pdn0, pup_pdn1, pup_pdn2, pup_pdn3}),
                                   3 bsl (2 * (Pin rem 16))}] ++
                                 [{element(Pin div 32 + 1, Bank), 1 bsl (Pin rem 32)}
                                  || Bank <- [{gpren0, gpren1}, {gpfen0, gpfen1}, {gphen0, gphen1},
                                              {gplen0, gplen1}, {gparen0, gparen1}, {gpafen0, gpafen1},
                                              {gpset0, gpset1}, {gpclr0, gpclr1}]],
                        lists:foldl(fun({R, M}, A) -> A#{R => maps:get(R, A, 0) bor M} end, Acc, Fields)
                end, #{}, Wanted).

reading() ->
    maps:filtermap(fun(_, _) ->
                           case rand:uniform(400) of
                               1 -> false;
                               2 -> {true, lists:nth(rand:uniform(3), [-1, 1 bsl 32, junk])};
                               _ -> {true, rand:uniform(1 bsl 32) - 1}
                           end
                   end, base()).

wanted() ->
    Pins = lists:usort([rand:uniform(58) - 1 || _ <- lists:seq(1, rand:uniform(6))]),
    [{Pin, setting()} || Pin <- Pins].

setting() ->
    Function = lists:nth(rand:uniform(8), [in, out, 0, 1, 2, 3, 4, 5]),
    Level = case Function of out -> #{level => rand:uniform(2) - 1}; _ -> #{} end,
    Pull = case rand:uniform(4) of 1 -> #{}; N -> #{pull => element(N - 1, {none, up, down})} end,
    Edge = case rand:uniform(5) of 1 -> #{}; E -> #{edge => element(E - 1, {none, rising, falling, both})} end,
    maps:merge(maps:merge(#{function => Function}, Level), maps:merge(Pull, Edge)).
