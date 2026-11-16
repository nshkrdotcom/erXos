%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The clock facet (docs/design-time.md, "The clock facet" and "Verification and
%% testing", facet decode): every bound of decode/1 refused one past its edge and
%% admitted at it, for sample and set alike; operation/1 naming exactly what decode/1
%% admits; and the facet itself, through erx_facet, admitting only the operations its
%% grant lists, forwarding with the grantee as the source to the erx_clock registered at
%% each request, refusing unavailable with none, and outliving erx_clock's restart.
-module(erx_clock_facet_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").
-export([export/3, owner/1, start_link/0, init/1]).

-define(GRANTEE, 7).
-define(MAX, ?ERX_TIME_OFFSET_MAX).
-define(DISTANCE, ?ERX_CLOCK_DISTANCE_MAX_NS).
-define(SERVER, {192, 0, 2, 1}).
%% The wall offset whose set crashes the stand-in for erx_clock.
-define(CRASH, 13).

%% The facet's exports module: the export reaches the test, and every local caller is
%% the grantee's.
export(Pid, Rights, Peer) ->
    erx_clock_facet_tests ! {exported, Pid, Rights, Peer},
    ok.

owner(_Pid) ->
    ?GRANTEE.

admitted() ->
    [{sample, 0, 0, 1, {0, 0, 0, 0}}, {sample, ?MAX, ?DISTANCE - 1, 15, {255, 255, 255, 255}},
     {sample, 1, 20000000, 2, ?SERVER}, {set, 0}, {set, ?MAX}, {set, 1794787200000000000}].

refused() ->
    [{sample, ?MAX + 1, 0, 1, ?SERVER}, {sample, -1, 0, 1, ?SERVER}, {sample, 0, ?DISTANCE, 1, ?SERVER},
     {sample, 0, -1, 1, ?SERVER}, {sample, 0, 0, 0, ?SERVER}, {sample, 0, 0, 16, ?SERVER},
     {sample, 0, 0, 1, {256, 0, 0, 0}}, {sample, 0, 0, 1, {0, 0, 0, -1}}, {sample, 0, 0, 1, {0, 0, 0}},
     {sample, 0, 0, 1, {0, 0, 0, 0, 0}}, {sample, 0, 0, 1, {0, 0, 0, a}}, {sample, 0, 0, 1, [0, 0, 0, 0]},
     {sample, 1.0, 0, 1, ?SERVER}, {sample, 0, 0, 1}, {sample, 0, 0, 1, ?SERVER, x},
     {set, ?MAX + 1}, {set, -1}, {set, 1.0}, {set, <<0>>}, {set}, {set, 0, 0}, set, {write, []}, [], <<>>].

decode_test() ->
    [?assertEqual({ok, Request}, erx_clock_facet:decode(Request)) || Request <- admitted()],
    [?assertEqual({error, badarg}, erx_clock_facet:decode(Request)) || Request <- refused()].

%% operation/1 is decode/1's: the operation of each request it admits and error for each
%% it refuses, so the grant's check and admit/3 read one request one way.
operation_test() ->
    [?assertEqual({ok, element(1, Request)}, erx_clock_facet:operation(Request)) || Request <- admitted()],
    [?assertEqual(error, erx_clock_facet:operation(Request)) || Request <- refused()].

%% A facet granted Operations in front of Behind, as the domain service mints it in
%% front of erx_clock's supervisor.
facet(Operations, Behind) ->
    true = register(erx_clock_facet_tests, self()),
    {ok, Facet} =
        try
            erx_facet:start(erx_clock_facet, #{grantee => ?GRANTEE, ends_with => [Behind], operations => Operations},
                            #{exports => ?MODULE})
        after
            unregister(erx_clock_facet_tests)
        end,
    receive {exported, Facet, _, _} -> ok after 0 -> ok end,
    Facet.

%% The grantee's call of Request through Facet, in its envelope as the funnel delivers
%% it, and the facet's reply.
call(Facet, Request) ->
    Alias = alias(),
    Facet ! {erx_origin, ?GRANTEE, {'$gen_call', {self(), [alias | Alias]}, Request}},
    receive {[alias | Alias], Reply} -> Reply after 1000 -> none end.

%% The reply to Request through a facet granted Operations, in front of a stand-in
%% for erx_clock.
through(Operations, Request) ->
    {ok, Clock} = stand_in(),
    unlink(Clock),
    Facet = facet(Operations, Clock),
    Answer = call(Facet, Request),
    stop(Facet),
    stop(Clock),
    Answer.

%% Once Pid, killed, has ended, and with it its registered name.
stop(Pid) ->
    Monitor = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _Reason} -> ok end.

grant_admits_only_its_operations_test() ->
    ?assertEqual({ok, {set, ?GRANTEE, 5}}, through([set], {set, 5})),
    ?assertEqual({error, eperm}, through([set], {sample, 0, 0, 1, ?SERVER})),
    ?assertEqual({ok, {sample, ?GRANTEE, {sample, 0, 0, 1, ?SERVER}}},
                 through([sample], {sample, 0, 0, 1, ?SERVER})),
    ?assertEqual({error, eperm}, through([sample], {set, 5})),
    ?assertEqual({error, eperm}, through([], {set, 5})),
    ?assertEqual({error, badarg}, through([set], {set, ?MAX + 1})).

%% With no erx_clock registered, the facet refuses a request it admits as unavailable,
%% and a request it does not as badarg still.
no_clock_test() ->
    undefined = whereis(erx_clock),
    Facet = facet([set], self()),
    ?assertEqual({error, unavailable}, call(Facet, {set, 5})),
    ?assertEqual({error, badarg}, call(Facet, {set, -1})),
    exit(Facet, kill).

%% A stand-in for erx_clock, which crashes on a set to ?CRASH and answers every other
%% forwarded call {ok, Forwarded}, and its start under erx_clock_sup
%% (erx_service_sup:start_link/2).
start_link() ->
    stand_in().

stand_in() ->
    Pid = spawn_link(fun answer/0),
    true = register(erx_clock, Pid),
    {ok, Pid}.

answer() ->
    receive
        {'$gen_call', _From, {set, _Source, ?CRASH}} -> exit(crashed);
        {'$gen_call', From, Forwarded} -> gen:reply(From, {ok, Forwarded})
    end,
    answer().

%% A stand-in for kernel_safe_sup, one_for_one at its four restarts an hour, with the
%% one child Spec.
init({safe, Spec}) ->
    {ok, {#{strategy => one_for_one, intensity => 4, period => 3600}, [Spec]}}.

%% The design's restart (docs/design-time.md, "Concurrency and failure"): erx_clock
%% crashes, erx_clock_sup restarts it, and the facet minted before the crash reaches
%% the new one; no grant ends.
restart_test() ->
    {ok, Sup} = erx_service_sup:start_link(clock, ?MODULE),
    unlink(Sup),
    try
        ?assertEqual(Sup, server()),
        Facet = facet([set], server()),
        ?assertEqual({ok, {set, ?GRANTEE, 5}}, call(Facet, {set, 5})),
        Crashed = whereis(erx_clock),
        stop(Crashed),
        restarted(Crashed),
        ?assertEqual({ok, {set, ?GRANTEE, 6}}, call(Facet, {set, 6}))
    after
        %% An orderly stop ends the stand-in, and with it the name erx_clock, first.
        gen_server:stop(Sup),
        persistent_term:erase({erx, serves})
    end.

%% A crash loop (docs/design-time.md, "Concurrency and failure"): a request that
%% crashes erx_clock every time, sent again at each restart, ends erx_clock_sup once
%% past its intensity, and with it the facet, so date's next set finds no facet
%% (noproc, eagain's text: erx_cmd_date_tests). kernel_safe_sup, which holds
%% erx_clock_sup by erx_service_sup:child_spec(clock), neither restarts that end nor
%% counts it, so it and the system domain run on.
crash_loop_test() ->
    Spec = (erx_service_sup:child_spec(clock))#{start := {erx_service_sup, start_link,
                                                          [clock, ?MODULE]}},
    {ok, Safe} = supervisor:start_link(?MODULE, {safe, Spec}),
    unlink(Safe),
    try
        Sup = whereis(erx_clock_sup),
        SupDown = monitor(process, Sup),
        ?assertEqual(Sup, server()),
        Facet = facet([set], server()),
        FacetDown = monitor(process, Facet),
        %% Four crashes erx_clock_sup restarts; the fifth passes its intensity.
        [begin
             Crashed = whereis(erx_clock),
             ?assertEqual({error, failed}, call(Facet, {set, ?CRASH})),
             restarted(Crashed)
         end || _ <- lists:seq(1, 4)],
        %% The stand-in's link exit reaches erx_clock_sup, and its monitor the facet,
        %% before erx_clock_sup's own end does, so the facet answers before it ends.
        ?assertEqual({error, failed}, call(Facet, {set, ?CRASH})),
        receive {'DOWN', SupDown, process, Sup, _} -> ok end,
        receive {'DOWN', FacetDown, process, Facet, _} -> ok end,
        ?assert(is_process_alive(Safe)),
        ?assertEqual([], supervisor:which_children(Safe)),
        ?assertExit({noproc, _}, gen_server:call(Facet, {set, 5}))
    after
        stop(Safe),
        persistent_term:erase({erx, serves})
    end.

%% The server of clock, as the domain service reads it when it mints.
server() ->
    maps:get(clock, persistent_term:get({erx, serves})).

%% Once the supervisor has registered the erx_clock that replaces Crashed.
restarted(Crashed) ->
    case whereis(erx_clock) of
        Clock when is_pid(Clock), Clock =/= Crashed -> ok;
        _Down -> timer:sleep(1), restarted(Crashed)
    end.
