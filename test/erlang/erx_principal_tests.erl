%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_principal_tests).
-moduledoc """
The registry of app principals (docs/design-packaging.md, "An app's
principal"): a record is written into an entry no other name holds, keeps
its entry and signer for the boot, holds nothing but its entry, signer, memory,
kept rows and app's record, and is refused, never crashed on, when malformed.
test/host/erx_principal_test.rb runs it against erx_principal as it is and
against seeded faults.
""".

-include_lib("eunit/include/eunit.hrl").

-define(MIB, 1048576).

admitted(Entry, Signer, Memory) ->
    #{entry => Entry, signer => Signer, memory => Memory,
      rows => [0, 2], display => <<"display">>}.

-define(LAYOUT, #{image_offset => 4096, image_length => 8192, tree_offset => 12288,
                  tree_length => 4096, salt => <<0:256>>, root_hash => <<1:256>>}).
-define(START, {applications, [<<"kiosk">>]}).

%% A package the package process committed: installed unless named.
package(Name, Admitted) ->
    package(Name, installed, Admitted).

package(Name, Place, Admitted) ->
    #{name => Name, place => Place, admitted => Admitted,
      checked => #{header => #{name => Name, layout => ?LAYOUT, start => ?START},
                   signer => image, sha256 => <<0:256>>, extent => 1}}.

register(Name, Admitted, Apps) ->
    erx_principal:register(package(Name, Admitted), Apps).

%% The record `Name`'s registration as an installed package writes.
record(Name, Entry, Signer, Memory) ->
    #{entry => Entry, signer => Signer, memory => Memory, rows => [0, 2],
      app => #{place => <<"/packages/", Name/binary, ".app">>, layout => ?LAYOUT, start => ?START}}.

registered(Max, Records) ->
    lists:foldl(fun({Name, Admitted}, Apps) ->
                        {ok, Next} = register(Name, Admitted, Apps),
                        Next
                end, erx_principal:new(Max), Records).

registration_writes_the_record_admission_reads_test() ->
    Apps = registered(4, [{<<"kiosk">>, admitted(0, image, 32 * ?MIB)},
                          {<<"clock">>, admitted(1, <<"vendor">>, 64 * ?MIB)}]),
    ?assertEqual({ok, record(<<"clock">>, 1, <<"vendor">>, 64 * ?MIB)},
                 erx_principal:app(<<"clock">>, Apps)),
    ?assertEqual(#{<<"clock">> => #{entry => 1, signer => <<"vendor">>},
                   <<"kiosk">> => #{entry => 0, signer => image}},
                 erx_principal:registry(Apps)),
    ?assertEqual(error, erx_principal:app(<<"notes">>, Apps)).

%% AP2: no credential, nor anything else of the admission, enters the record.
a_record_holds_no_credentials_test() ->
    Given = (admitted(0, development, 8 * ?MIB))#{credentials => <<"secret">>, login => true},
    {ok, Apps} = register(<<"notes">>, Given, erx_principal:new(2)),
    ?assertEqual({ok, record(<<"notes">>, 0, development, 8 * ?MIB)},
                 erx_principal:app(<<"notes">>, Apps)).

a_name_registered_again_keeps_its_entry_and_signer_test() ->
    Apps = registered(4, [{<<"clock">>, admitted(0, <<"vendor">>, 64 * ?MIB)}]),
    {ok, Updated} = register(<<"clock">>, admitted(0, <<"vendor">>, 16 * ?MIB), Apps),
    ?assertEqual({ok, record(<<"clock">>, 0, <<"vendor">>, 16 * ?MIB)},
                 erx_principal:app(<<"clock">>, Updated)),
    ?assertEqual({error, {signer_changed, <<"clock">>}},
                 register(<<"clock">>, admitted(0, <<"other">>, 16 * ?MIB), Apps)),
    ?assertEqual({error, {entry, 3}},
                 register(<<"clock">>, admitted(3, <<"vendor">>, 16 * ?MIB), Apps)).

%% A new name takes the lowest free entry, the one admission gave it.
a_new_name_takes_the_entry_admission_gives_test() ->
    Apps = registered(4, [{<<"clock">>, admitted(0, <<"vendor">>, 8 * ?MIB)}]),
    ?assertEqual({error, {entry, 2}},
                 register(<<"notes">>, admitted(2, development, 8 * ?MIB), Apps)),
    ?assertMatch({ok, _}, register(<<"notes">>, admitted(1, development, 8 * ?MIB), Apps)).

%% PK9: no entry is freed within a boot. Every entry held, a new name finds
%% none: not one another name holds, nor one past max; and nothing removes a
%% name, so a removed app's entry stays its own until the next boot.
no_entry_is_freed_within_a_boot_test() ->
    Apps = registered(2, [{<<"clock">>, admitted(0, <<"vendor">>, 8 * ?MIB)},
                          {<<"notes">>, admitted(1, development, 8 * ?MIB)}]),
    ?assertEqual({error, apps_full},
                 register(<<"chess">>, admitted(0, <<"vendor">>, 8 * ?MIB), Apps)),
    ?assertEqual({error, apps_full},
                 register(<<"chess">>, admitted(2, <<"vendor">>, 8 * ?MIB), Apps)),
    ?assertEqual([{app, 2}, {app_registry, 0}, {fetch_name, 2}, {module_info, 0}, {module_info, 1}, {new, 1},
                  {register, 2}, {register_app, 1}, {registry, 1}],
                 lists:sort(erx_principal:module_info(exports))).

without_an_apps_row_nothing_registers_test() ->
    ?assertEqual({error, apps_full},
                 register(<<"clock">>, admitted(0, image, 8 * ?MIB), erx_principal:new(0))).

malformed_input_is_refused_test() ->
    Apps = erx_principal:new(2),
    [?assertEqual({error, badarg}, register(Name, Given, Apps))
     || {Name, Given} <- [{clock, admitted(0, image, ?MIB)},
                          {<<"clock">>, [entry]},
                          {<<"clock">>, maps:remove(memory, admitted(0, image, ?MIB))},
                          {<<"clock">>, maps:remove(signer, admitted(0, image, ?MIB))},
                          {<<"clock">>, maps:remove(rows, admitted(0, image, ?MIB))},
                          {<<"clock">>, (admitted(0, image, ?MIB))#{rows := x}},
                          {<<"clock">>, admitted(-1, image, ?MIB)},
                          {<<"clock">>, admitted(zero, image, ?MIB)},
                          {<<"clock">>, admitted(0, image, 0)}]],
    Package = package(<<"clock">>, admitted(0, image, ?MIB)),
    [?assertEqual({error, badarg}, erx_principal:register(Given, Apps))
     || Given <- [maps:remove(checked, Package),
                  Package#{place := elsewhere},
                  Package#{checked := #{header => #{start => ?START}}},
                  Package#{checked := #{header => #{layout => ?LAYOUT}}},
                  maps:remove(admitted, Package),
                  Package#{admitted := [entry]},
                  x]].

%% The record keeps the app's record its sessions' ready answers hand them:
%% the file's place under the session's `packages` grant, the image's for a
%% system package and the installed tree's for an installed one, with the
%% header's layout and start; fetch_name/2 answers the name in an entry.
the_record_keeps_the_app_record_with_its_place_test() ->
    {ok, Image} = erx_principal:register(package(<<"kiosk">>, system, admitted(0, image, ?MIB)),
                                         erx_principal:new(2)),
    {ok, Apps} = register(<<"clock">>, admitted(1, development, ?MIB), Image),
    {ok, #{app := Kiosk}} = erx_principal:app(<<"kiosk">>, Apps),
    ?assertEqual(#{place => <<"/pkg/kiosk.app">>, layout => ?LAYOUT, start => ?START}, Kiosk),
    {ok, #{app := Clock}} = erx_principal:app(<<"clock">>, Apps),
    ?assertEqual(#{place => <<"/packages/clock.app">>, layout => ?LAYOUT, start => ?START}, Clock),
    ?assertEqual(<<"kiosk">>, erx_principal:fetch_name(0, Apps)),
    ?assertEqual(<<"clock">>, erx_principal:fetch_name(1, Apps)).
