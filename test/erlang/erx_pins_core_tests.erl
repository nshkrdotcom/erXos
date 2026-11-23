%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_pins_core's decisions (docs/design-pinctrl.md, "At start", "States at run time" and
%% "Verification") over a Raspberry Pi 4 table in the pins record's form, with
%% erx_pins_bcm2711 as its kind and erx_pins_model as its registers.
%% test/host/erx_pins_test.rb runs these cases and, for each seeded fault, the case that
%% must fail.
-module(erx_pins_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(C, erx_pins_core).
-define(K, erx_pins_bcm2711).

-define(UART0, 3).      % the Bluetooth line, used by a domain outside rescue
-define(HOST_LINK, 5).  % the host link's UART, the system release's
-define(PHY, 7).        % a device with a second state, whose driver selects
-define(I2C, 9).        % a device no domain holds

row(Pin, Owner, State, Setting) -> #{pin => Pin, owner => Owner, state => State, setting => Setting}.

table() ->
    #{kind => ?K,
      rows => [row(Pin, ?UART0, default, #{function => 3}) || Pin <- [30, 31, 32, 33]] ++
              [row(4, ?HOST_LINK, default, #{function => 4, pull => none}),
               row(5, ?HOST_LINK, default, #{function => 4, pull => up}),
               row(26, ?PHY, default, #{function => out, level => 1}),
               row(26, ?PHY, reset, #{function => out, level => 0}),
               row(2, ?I2C, default, #{function => 0, pull => none}),
               row(6, gpio, default, #{})],
      uses => #{?UART0 => normal, ?HOST_LINK => rescue, ?I2C => none}}.

base() ->
    {ok, Registers} = ?K:registers(lists:seq(0, 57)),
    maps:from_list([{Register, 0} || Register <- Registers]).

%% A start over the model: its plan applied, with one pin's field write dropped when
%% Drop names one, and the reading its check takes.
started(Drop) ->
    {ok, Steps} = ?K:plan(base(), ?C:start_wanted(table())),
    Options = case Drop of none -> #{}; _ -> #{drop => Drop} end,
    erx_pins_model:reading(erx_pins_model:apply(erx_pins_model:new(base(), Options), Steps)).

states_test() ->
    ?assertEqual({ok, [{26, #{function => out, level => 0}}]}, ?C:wanted(table(), ?PHY, reset)),
    ?assertEqual({error, enoent}, ?C:wanted(table(), ?PHY, sleep)),
    ?assertEqual({ok, [{Pin, #{function => 3}} || Pin <- [30, 31, 32, 33]]}, ?C:wanted(table(), ?UART0, default)).

state_read_from_the_registers_test() ->
    Out = (base())#{gpfsel2 => 1 bsl 18},
    ?assertEqual(default, ?C:state_of(table(), ?PHY, Out#{gplev0 => 1 bsl 26})),
    ?assertEqual(reset, ?C:state_of(table(), ?PHY, Out)),
    ?assertEqual(unset, ?C:state_of(table(), ?PHY, base())).

start_plan_test() ->
    Wanted = ?C:start_wanted(table()),
    ?assertEqual([2, 4, 5, 6, 30, 31, 32, 33], [Pin || {Pin, _} <- Wanted]),
    ?assertEqual(?C:idle(), proplists:get_value(6, Wanted)),
    ?assertEqual(false, lists:keymember(26, 1, Wanted)).

a_clean_start_boots_normal_test() ->
    Read = started(none),
    ?assertEqual({ok, []}, ?C:start_verdict(table(), normal, Read)),
    ?assertEqual(normal, ?C:configuration([?C:start_verdict(table(), normal, Read)])).

a_device_only_normal_uses_left_unset_test() ->
    Read = started({gpfsel3, 31, 3, 3}),
    Normal = ?C:start_verdict(table(), normal, Read),
    ?assertMatch({error, {unset, [#{pin := 31, owner := ?UART0, uses := normal,
                                   wanted := #{function := 3}, read := #{function := in}}]}}, Normal),
    ?assertMatch({ok, [#{pin := 31}]}, ?C:start_verdict(table(), rescue, Read)),
    ?assertEqual(rescue, ?C:configuration([Normal])).

a_device_rescue_uses_left_unset_test() ->
    Read = started({gpfsel0, 5, 15, 3}),
    Normal = ?C:start_verdict(table(), normal, Read),
    ?assertMatch({error, {unset, [#{pin := 5, owner := ?HOST_LINK}]}}, Normal),
    ?assertMatch({error, {unset, _}}, ?C:start_verdict(table(), rescue, Read)),
    ?assertEqual(none, ?C:configuration([Normal])).

a_device_for_no_one_and_a_gpio_pin_cost_the_report_test() ->
    Read = started({gpfsel0, 2, 6, 3}),
    ?assertMatch({ok, [#{pin := 2, owner := ?I2C, uses := none}]}, ?C:start_verdict(table(), normal, Read)),
    ?assertMatch({ok, [#{pin := 2}]}, ?C:start_verdict(table(), rescue, Read)),
    Gpio = (started(none))#{gpren0 => 1 bsl 6},
    ?assertMatch({ok, [#{pin := 6, owner := gpio, uses := none}]}, ?C:start_verdict(table(), normal, Gpio)).

a_device_without_a_uses_value_fails_the_start_test() ->
    Read = started({gpfsel3, 31, 3, 3}),
    Table = table(),
    ?assertError({badkey, ?UART0},
                 ?C:start_verdict(Table#{uses := maps:remove(?UART0, maps:get(uses, Table))}, normal, Read)).

a_refused_plan_leaves_no_configuration_test() ->
    Refused = ?C:start_verdict(table(), normal, maps:remove(gpfsel3, base())),
    ?assertMatch({error, {refused, {30, {unread, gpfsel3}}}}, Refused),
    ?assertEqual(none, ?C:configuration([{ok, []}, Refused])).

configuration_test() ->
    OnlyNormal = {error, {unset, [#{pin => 31, owner => ?UART0, uses => normal, wanted => #{}, read => #{}}]}},
    Rescue = {error, {unset, [#{pin => 5, owner => ?HOST_LINK, uses => rescue, wanted => #{}, read => #{}}]}},
    ?assertEqual(normal, ?C:configuration([{ok, []}, {ok, [#{}]}])),
    ?assertEqual(rescue, ?C:configuration([{ok, []}, OnlyNormal])),
    ?assertEqual(none, ?C:configuration([OnlyNormal, Rescue])).
