%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_irq_line (docs/design-shared-devices.md, "Verification" and "The owner"):
%% over a sample of sets of one to four drivers of one or two records each, drawn from shared and
%% direct lines, owners/1 gives each shared line one owner, named by the first record that names
%% it, and no direct line one; and start_owner/2 starts the owner at priority high.
%% test/host/erx_irq_line_test.rb runs them, and a seeded fault.

-module(erx_irq_line_tests).

-include_lib("eunit/include/eunit.hrl").

%% The records a driver may hold: two lines shared, one direct, given and physical forms.
records() ->
    [#{peripheral => pl011, window => stand_in, lines => Lines}
     || Lines <- [[{shared, 7}], [{shared, 7}, 3], [{shared, {object, 12}}], [4], [5, {shared, 7}]]].

every_set_of_drivers_gets_one_owner_per_shared_line_test() ->
    Records = records(),
    Drivers = [[{Name, Specs} || {Name, Specs} <- lists:zip(lists:sublist([a, b, c, d], N), Set)]
               || N <- [1, 2, 3, 4], Set <- sets_of(N, [[R] || R <- Records] ++ [[R, S] || R <- Records, S <- Records])],
    lists:foreach(fun check/1, Drivers).

a_drivers_two_records_on_one_line_give_one_owner_test() ->
    [First, Second | _] = records(),
    ?assertEqual([{First, 0}], erx_irq_line:owners([{a, [First, Second]}])).

a_direct_line_gets_no_owner_test() ->
    ?assertEqual([], erx_irq_line:owners([{a, [#{peripheral => pl011, window => stand_in, lines => [4, 5]}]}])).

%% The owner runs at priority high from its first step (docs/design-shared-devices.md, "The
%% owner"). A stand-in erx_device, loaded here because the stock emulator has none, refuses the
%% open with the priority it ran at, and start_owner/2 returns that refusal.
the_owner_runs_at_high_priority_test() ->
    false = code:is_loaded(erx_device),
    load_stand_in_device(),
    try
        ?assertEqual({error, {priority, high}}, erx_irq_line:start_owner(#{}, 0))
    after
        code:delete(erx_device), code:purge(erx_device)
    end.

load_stand_in_device() ->
    Open = "open(_) ->"
           "    {priority, P} = process_info(self(), priority),"
           "    {error, {priority, P}}.",
    Forms = [form(Text) || Text <- ["-module(erx_device).", "-export([open/1]).", Open]],
    {ok, erx_device, Beam} = compile:forms(Forms),
    {module, erx_device} = code:load_binary(erx_device, "erx_device.erl", Beam).

form(Text) ->
    {ok, Tokens, _} = erl_scan:string(Text),
    {ok, Form} = erl_parse:parse_form(Tokens),
    Form.

check(Drivers) ->
    Named = [{Line, {Spec, Index}} || {_, Specs} <- Drivers, Spec <- Specs,
                                      {Index, {shared, Line}} <- lists:enumerate(0, maps:get(lines, Spec))],
    Lines = lists:usort([Line || {Line, _} <- Named]),
    Owners = erx_irq_line:owners(Drivers),
    ?assertEqual(length(Lines), length(Owners), Drivers),
    [?assertEqual(proplists:get_value(Line, Named), Owner, Drivers)
     || {Line, Owner} <- lists:zip([line_of(Owner) || Owner <- Owners], Owners)],
    ?assertEqual(Lines, lists:usort([line_of(Owner) || Owner <- Owners]), Drivers).

line_of({#{lines := Lines}, Index}) ->
    {shared, Line} = lists:nth(Index + 1, Lines),
    Line.

%% Every list of N picks from Choices, with repeats, capped so the run stays short.
sets_of(0, _Choices) -> [[]];
sets_of(N, Choices) -> lists:sublist([[C | Rest] || C <- Choices, Rest <- sets_of(N - 1, Choices)], 2000).
