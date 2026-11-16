%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A facet row's parameters from the packed manifest to the mint
%% (docs/design-system.md, "Facets a configured domain serves"), run by
%% test/host/facet_parameters_test.rb: served/1, the host harness
%% test/fixtures/erx_domain_terms_harness.c, builds the domain library's boot
%% view from the manifest bytes in manifest.bin and turns it into the
%% services and grants erx_domain_lib:configured/0 returns, with the NIF's own
%% erx_domain_served_terms. The manifest is the display_domain suite's, its
%% client template's grant of the display stating pixels, windows and clipboard;
%% the grant's limits carry each by name, and erx_domain_mints charges the
%% display the pixel area the row asks for. Each refused-NAME.bin beside it
%% forges the grant's parameter rows, and the view refuses it.
-module(erx_facet_parameters_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([served/1]).
-on_load(load/0).

load() ->
    erlang:load_nif("./erx_domain_terms_harness", 0).

served(_Bytes) ->
    erlang:nif_error(not_loaded).

%% The display service and the client template's grant of it, from the manifest.
display() ->
    {ok, Bytes} = file:read_file("manifest.bin"),
    {ok, {Services, Grants}} = served(Bytes),
    [{Server, Name}] = [{Row, N} || {Row, N, ?ERX_SERVICE_WINDOWS} <- Services],
    [Grant] = [G || {{template, _}, N, S, _} = G <- Grants, N =:= Name, S =:= Server],
    {Services, Grants, Grant}.

the_grant_s_limits_carry_its_parameters_by_name_test() ->
    {_Services, _Grants, {_Grantee, _Name, _Server, Limits}} = display(),
    ?assertMatch(#{pixels := 4194304, windows := 2, clipboard := true}, Limits),
    ?assertEqual(lists:sort([max_request, in_flight, reductions, period_ns, max_heap_size, queue,
                             pixels, windows, clipboard]),
                 lists:sort(maps:keys(Limits))).

%% The mint core as the domain service makes it from those terms (erx_domain_srv:booted/1),
%% and a session of the template holding the row its plan gave it.
the_pixel_charge_follows_the_row_test() ->
    {Services, Grants, {{template, _Template}, Name, Server, Limits}} = display(),
    Mints = erx_domain_mints:new(#{services => [{S, N} || {S, N, _} <- Services, S =/= system],
                                   grants => [G || {_, _, S, _} = G <- Grants, S =/= system],
                                   windows => [Name], owner => fun(_) -> ok end}),
    ?assertEqual({4194304, 5}, erx_domain_mints:pair_area({5, {configured, Server}},
                                                         {6, {rows, [{Name, Server, Limits}]}}, Mints)).

forged_parameter_rows_are_refused_test() ->
    Forged = filelib:wildcard("refused-*.bin"),
    ?assertEqual(5, length(Forged)),
    [?assertMatch({File, {refused, _}}, {File, served(element(2, file:read_file(File)))}) || File <- Forged].
