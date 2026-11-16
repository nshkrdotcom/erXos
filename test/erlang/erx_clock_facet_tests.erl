%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The clock facet (docs/design-time.md, "The clock facet" and "Verification and
%% testing", facet decode): every bound of decode/1 refused one past its edge and
%% admitted at it, for sample and set alike; operation/1 naming exactly what decode/1
%% admits; and the facet itself, through erx_facet, admitting only the operations its
%% grant lists and forwarding with the grantee as the source.
-module(erx_clock_facet_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").
-export([export/3, owner/1]).

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

%% A facet granted Operations, in front of the test, and the reply to Request through
%% it: what the test, standing for erx_clock, received is answered {ok, Forwarded}.
through(Operations, Request) ->
    Behind = self(),
    true = register(erx_clock_facet_tests, self()),
    {ok, Facet} =
        try
            erx_facet:start(erx_clock_facet, #{grantee => ?GRANTEE, ends_with => [Behind], behind => Behind,
                                               operations => Operations}, #{exports => ?MODULE})
        after
            unregister(erx_clock_facet_tests)
        end,
    receive {exported, Facet, _, _} -> ok after 0 -> ok end,
    %% The grantee's call, in its envelope as the funnel delivers it.
    Alias = alias(),
    Facet ! {erx_origin, ?GRANTEE, {'$gen_call', {self(), [alias | Alias]}, Request}},
    Answer = reply(Alias),
    exit(Facet, kill),
    Answer.

%% The facet's reply to the call tagged Alias, answering what it forwards meanwhile.
reply(Alias) ->
    receive
        {'$gen_call', From, Forwarded} -> gen:reply(From, {ok, Forwarded}), reply(Alias);
        {[alias | Alias], Reply} -> Reply
    after 1000 -> none
    end.

grant_admits_only_its_operations_test() ->
    ?assertEqual({ok, {set, ?GRANTEE, 5}}, through([set], {set, 5})),
    ?assertEqual({error, eperm}, through([set], {sample, 0, 0, 1, ?SERVER})),
    ?assertEqual({ok, {sample, ?GRANTEE, {sample, 0, 0, 1, ?SERVER}}},
                 through([sample], {sample, 0, 0, 1, ?SERVER})),
    ?assertEqual({error, eperm}, through([sample], {set, 5})),
    ?assertEqual({error, eperm}, through([], {set, 5})),
    ?assertEqual({error, badarg}, through([set], {set, ?MAX + 1})).
