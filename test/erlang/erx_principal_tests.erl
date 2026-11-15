%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_principal_tests).
-moduledoc """
The registry of app principals (docs/design-packaging.md, "An app's
principal"): a record is written into an entry no other name holds, keeps
its entry and signer for the boot, holds nothing but its entry, signer and
memory, and is refused, never crashed on, when malformed.
test/host/erx_principal_test.rb runs it against erx_principal as it is and
against seeded faults.
""".

-include_lib("eunit/include/eunit.hrl").

-define(MIB, 1048576).

admitted(Entry, Signer, Memory) ->
    #{entry => Entry, signer => Signer, memory => Memory,
      rows => [0, 2], display => <<"display">>}.

registered(Max, Records) ->
    lists:foldl(fun({Name, Admitted}, Apps) ->
                        {ok, Next} = erx_principal:register(Name, Admitted, Apps),
                        Next
                end, erx_principal:new(Max), Records).

registration_writes_the_record_admission_reads_test() ->
    Apps = registered(4, [{<<"kiosk">>, admitted(0, image, 32 * ?MIB)},
                          {<<"clock">>, admitted(1, <<"vendor">>, 64 * ?MIB)}]),
    ?assertEqual({ok, #{entry => 1, signer => <<"vendor">>, memory => 64 * ?MIB}},
                 erx_principal:app(<<"clock">>, Apps)),
    ?assertEqual(#{<<"clock">> => #{entry => 1, signer => <<"vendor">>},
                   <<"kiosk">> => #{entry => 0, signer => image}},
                 erx_principal:registry(Apps)),
    ?assertEqual(error, erx_principal:app(<<"notes">>, Apps)).

%% AP2: no credential, nor anything else of the admission, enters the record.
a_record_holds_no_credentials_test() ->
    Given = (admitted(0, development, 8 * ?MIB))#{credentials => <<"secret">>, login => true},
    {ok, Apps} = erx_principal:register(<<"notes">>, Given, erx_principal:new(2)),
    ?assertEqual({ok, #{entry => 0, signer => development, memory => 8 * ?MIB}},
                 erx_principal:app(<<"notes">>, Apps)).

a_name_registered_again_keeps_its_entry_and_signer_test() ->
    Apps = registered(4, [{<<"clock">>, admitted(0, <<"vendor">>, 64 * ?MIB)}]),
    {ok, Updated} = erx_principal:register(<<"clock">>, admitted(0, <<"vendor">>, 16 * ?MIB), Apps),
    ?assertEqual({ok, #{entry => 0, signer => <<"vendor">>, memory => 16 * ?MIB}},
                 erx_principal:app(<<"clock">>, Updated)),
    ?assertEqual({error, {signer_changed, <<"clock">>}},
                 erx_principal:register(<<"clock">>, admitted(0, <<"other">>, 16 * ?MIB), Apps)),
    ?assertEqual({error, {entry, 3}},
                 erx_principal:register(<<"clock">>, admitted(3, <<"vendor">>, 16 * ?MIB), Apps)).

%% A new name takes the lowest free entry, the one admission gave it.
a_new_name_takes_the_entry_admission_gives_test() ->
    Apps = registered(4, [{<<"clock">>, admitted(0, <<"vendor">>, 8 * ?MIB)}]),
    ?assertEqual({error, {entry, 2}},
                 erx_principal:register(<<"notes">>, admitted(2, development, 8 * ?MIB), Apps)),
    ?assertMatch({ok, _}, erx_principal:register(<<"notes">>, admitted(1, development, 8 * ?MIB), Apps)).

%% PK9: no entry is freed within a boot. Every entry held, a new name finds
%% none: not one another name holds, nor one past max; and nothing removes a
%% name, so a removed app's entry stays its own until the next boot.
no_entry_is_freed_within_a_boot_test() ->
    Apps = registered(2, [{<<"clock">>, admitted(0, <<"vendor">>, 8 * ?MIB)},
                          {<<"notes">>, admitted(1, development, 8 * ?MIB)}]),
    ?assertEqual({error, apps_full},
                 erx_principal:register(<<"chess">>, admitted(0, <<"vendor">>, 8 * ?MIB), Apps)),
    ?assertEqual({error, apps_full},
                 erx_principal:register(<<"chess">>, admitted(2, <<"vendor">>, 8 * ?MIB), Apps)),
    ?assertEqual([{app, 2}, {app_registry, 0}, {module_info, 0}, {module_info, 1}, {new, 1},
                  {register, 3}, {register_app, 2}, {registry, 1}],
                 lists:sort(erx_principal:module_info(exports))).

without_an_apps_row_nothing_registers_test() ->
    ?assertEqual({error, apps_full},
                 erx_principal:register(<<"clock">>, admitted(0, image, 8 * ?MIB), erx_principal:new(0))).

malformed_input_is_refused_test() ->
    Apps = erx_principal:new(2),
    [?assertEqual({error, badarg}, erx_principal:register(Name, Given, Apps))
     || {Name, Given} <- [{clock, admitted(0, image, ?MIB)},
                          {<<"clock">>, [entry]},
                          {<<"clock">>, maps:remove(memory, admitted(0, image, ?MIB))},
                          {<<"clock">>, maps:remove(signer, admitted(0, image, ?MIB))},
                          {<<"clock">>, admitted(-1, image, ?MIB)},
                          {<<"clock">>, admitted(zero, image, ?MIB)},
                          {<<"clock">>, admitted(0, image, 0)}]].
