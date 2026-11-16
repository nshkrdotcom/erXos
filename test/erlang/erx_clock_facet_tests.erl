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
-export([export/3, owner/1, init/1, stand_in/0]).

-define(GRANTEE, 7).
-define(MAX, ?ERX_TIME_OFFSET_MAX).
-define(DISTANCE, ?ERX_CLOCK_DISTANCE_MAX_NS).
-define(SERVER, {192, 0, 2, 1}).

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

%% The supervisor of a stand-in for erx_clock, which answers each forwarded call
%% {ok, Forwarded}, as erx_clock's is the server of clock.
init(stand_in) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [#{id => erx_clock, start => {?MODULE, stand_in, []}}]}}.

stand_in() ->
    Pid = spawn_link(fun answer/0),
    true = register(erx_clock, Pid),
    {ok, Pid}.

answer() ->
    receive {'$gen_call', From, Forwarded} -> gen:reply(From, {ok, Forwarded}) end,
    answer().

%% The design's restart (docs/design-time.md, "Concurrency and failure"): erx_clock
%% crashes, its supervisor restarts it, and the facet minted before the crash reaches
%% the new one; no grant ends.
restart_test() ->
    {ok, Sup} = supervisor:start_link(?MODULE, stand_in),
    unlink(Sup),
    try
        Facet = facet([set], Sup),
        ?assertEqual({ok, {set, ?GRANTEE, 5}}, call(Facet, {set, 5})),
        Crashed = whereis(erx_clock),
        stop(Crashed),
        restarted(Crashed),
        ?assertEqual({ok, {set, ?GRANTEE, 6}}, call(Facet, {set, 6}))
    after
        %% The stand-in ends with it, and with it the name erx_clock.
        stop(Sup)
    end.

%% Once the supervisor has registered the erx_clock that replaces Crashed.
restarted(Crashed) ->
    case whereis(erx_clock) of
        Clock when is_pid(Clock), Clock =/= Crashed -> ok;
        _Down -> timer:sleep(1), restarted(Crashed)
    end.
