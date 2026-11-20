%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the pcie facet, erx_pcie_facet, and of erx_pcie_sup, the supervisor of
%% its mint and the enumerator. A facet started as its mint starts one, granted to the
%% system domain, forwards to a stand-in enumerator registered as erx_pcie_enumerator,
%% which answers each call with what it took and tells the test. A well-formed set or
%% reset reaches the enumerator and its answer the grantee; a request of another shape,
%% or with a key or setting out of shape, is refused with badarg and reaches no
%% enumerator; one that finds no enumerator registered is refused with unavailable. The
%% mint refuses a grant to any grantee but the system domain, and the supervisor ends
%% the mint with the enumerator and the enumerator with the mint. As in
%% erx_driver_ctl_tests, this module stands in for the export table, and the test's own
%% calls in the envelope are the system domain's.
-module(erx_pcie_facet_tests).
-include_lib("eunit/include/eunit.hrl").
-export([export/3, owner/1]).

-define(SYSTEM, 4).

export(_Pid, _Rights, _Peer) -> ok.

owner(_Name) -> ?SYSTEM.

%% A facet in front of a stand-in enumerator; ends both after Test(Facet).
%% The name is unregistered before the kill, since a killed process keeps its name
%% until it has gone, so the next case finds it free.
with_facet(Test) ->
    Self = self(),
    Enumerator = spawn(fun() -> receive go -> enumerator(Self) end end),
    true = register(erx_pcie_enumerator, Enumerator),
    Enumerator ! go,
    try
        with_bare_facet(Test)
    after
        unregister(erx_pcie_enumerator),
        exit(Enumerator, kill)
    end.

%% A facet with no enumerator registered; ends it after Test(Facet).
with_bare_facet(Test) ->
    Mint = spawn(fun() -> receive after infinity -> ok end end),
    Grant = #{grantee => ?SYSTEM, ends_with => [Mint]},
    {ok, Facet} = erx_facet:start(erx_pcie_facet, Grant, #{exports => ?MODULE}),
    try
        Test(Facet)
    after
        exit(Mint, kill)
    end.

enumerator(Test) ->
    receive
        {'$gen_call', From, Request} ->
            Test ! {enumerator, Request},
            gen:reply(From, {took, Request}),
            enumerator(Test)
    end.

%% A gen_server call of Request to Facet in the system domain's envelope.
call(Facet, Request) ->
    Alias = alias(),
    Facet ! {erx_origin, ?SYSTEM, {'$gen_call', {self(), [alias | Alias]}, Request}},
    receive {[alias | Alias], Reply} -> Reply after 2000 -> none end.

%% Whether the enumerator took a request within Wait ms.
took(Wait) ->
    receive {enumerator, Request} -> {took, Request} after Wait -> nothing end.

-define(KEY, {7, 0, 2, 0}).
setting() -> #{mode => mastering, route => msi, message => #{address => 16#8020040, data => 80}}.

a_set_and_a_reset_reach_the_enumerator_test() ->
    with_facet(fun(Facet) ->
                       Set = {set, ?KEY, setting()},
                       ?assertEqual({took, Set}, call(Facet, Set)),
                       ?assertEqual({took, Set}, took(0)),
                       ?assertEqual({took, {reset, ?KEY}}, call(Facet, {reset, ?KEY})),
                       ?assertEqual({took, {reset, ?KEY}}, took(0))
               end).

a_request_out_of_shape_reaches_no_enumerator_test() ->
    Refused = [{set, {7, 0, 32, 0}, setting()},
               {set, {7, 256, 2, 0}, setting()},
               {set, {-1, 0, 2, 0}, setting()},
               {set, {7, 0, 2, 8}, setting()},
               {set, ?KEY, (setting())#{mode := running}},
               {set, ?KEY, (setting())#{route := wired}},
               {set, ?KEY, maps:remove(message, setting())},
               {set, ?KEY, not_a_map},
               {reset, {7, 0, 2}},
               {reset, ?KEY, extra},
               {open, ?KEY}],
    with_facet(fun(Facet) ->
                       [?assertEqual({error, badarg}, call(Facet, Request)) || Request <- Refused],
                       ?assertEqual(nothing, took(100))
               end).

a_request_with_no_enumerator_is_unavailable_test() ->
    with_bare_facet(fun(Facet) ->
                            ?assertEqual({error, unavailable}, call(Facet, {reset, ?KEY}))
                    end).

%% The mint's answer to a mint request for Grantee, as the system domain's domain pid
%% takes it.
minted_for(Mint, Grantee) ->
    persistent_term:put({erx, domain_pid}, self()),
    try
        Mint ! {erx_origin, ?SYSTEM, {erx_facet_mint, 9, pcie, Grantee, <<"system">>, #{in_flight => 1}}},
        receive {erx_facet_minted, 9, Reply} -> Reply after 2000 -> none end
    after
        persistent_term:erase({erx, domain_pid})
    end.

%% erx_pcie_sup started by a process that traps exits, as the application master
%% does; ends it after Test(Sup, Mint).
with_sup(Test) ->
    Trap = process_flag(trap_exit, true),
    {ok, Sup} = erx_pcie_sup:start_link(),
    [Mint] = [Pid || {mint, Pid, worker, _} <- supervisor:which_children(Sup)],
    try
        Test(Sup, Mint)
    after
        exit(Sup, kill),
        receive {'EXIT', Sup, _} -> ok end,
        persistent_term:erase({erx, provides}),
        process_flag(trap_exit, Trap)
    end.

the_mint_is_provided_and_refuses_another_grantee_test() ->
    with_sup(fun(_Sup, Mint) ->
                     ?assertEqual(#{pcie => Mint}, persistent_term:get({erx, provides})),
                     ?assertEqual(refused, minted_for(Mint, ?SYSTEM + 1))
             end).

the_end_of_the_mint_ends_the_supervisor_test() ->
    with_sup(fun(Sup, Mint) ->
                     Ref = monitor(process, Sup),
                     exit(Mint, kill),
                     ?assertEqual(ok, receive {'DOWN', Ref, process, Sup, _} -> ok after 2000 -> none end)
             end).

%% On the host the domain's facet registry is empty, so erx:cap(pci_bus) finds no
%% facet, bus/1 answers {error, no_facet}, and the enumerator
%% the -eval starts ends at its first pci_bus call, as a domain that holds none does,
%% and takes the mint and the supervisor with it.
the_end_of_the_enumerator_ends_the_mint_test() ->
    with_sup(fun(Sup, Mint) ->
                     Refs = [monitor(process, Pid) || Pid <- [Sup, Mint]],
                     #{level := Level} = logger:get_primary_config(),
logger:set_primary_config(level, none),
                     try
                         ?assertEqual(ok, erx_pcie_sup:start_enumerator()),
                         [?assertEqual(ok, receive {'DOWN', R, process, _, _} -> ok after 2000 -> none end)
                          || R <- Refs]
                     after
                         logger:set_primary_config(level, Level)
                     end
             end).
