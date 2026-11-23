%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_code_facet_tests).
-moduledoc """
EUnit cases of the install facet's callback, erx_code_facet (docs/design-live.md,
"Code from the host"): the operation it names for each request the code service's reader
admits, and its forward to the erx_code registered at the time.
""".

-include_lib("eunit/include/eunit.hrl").

-define(HASH, <<0:256>>).

operation_test() ->
    ?assertEqual({ok, missing}, erx_code_facet:operation({missing, [?HASH]})),
    ?assertEqual({ok, put}, erx_code_facet:operation({put, ?HASH, 3, 0, <<"abc">>})),
    ?assertEqual({ok, load}, erx_code_facet:operation({load, [{<<"m">>, ?HASH}]})),
    %% history is the inspector's, through an inspect facet, and no operation of the interface.
    ?assertEqual(error, erx_code_facet:operation({history, 4, <<"m">>})),
    %% A load names no domain: the facet loads into the system domain alone.
    ?assertEqual(error, erx_code_facet:operation({load, 5, [{<<"m">>, ?HASH}]})),
    %% The code service's reader gives the reason for a request of the right shape.
    ?assertEqual({ok, put}, erx_code_facet:operation({put, ?HASH, 3, 0, abc})),
    ?assertEqual(error, erx_code_facet:operation(load)).

admit_test() ->
    {ok, State} = erx_code_facet:init(#{grantee => 9}),
    Request = {missing, [?HASH]},
    ?assertEqual({refuse, unavailable, State}, erx_code_facet:admit(Request, self(), State)),
    {ok, Pid} = erx_code:start_link(#{limit => 1 bsl 20}),
    try
        ?assertEqual({forward, Pid, {request, Request}, State}, erx_code_facet:admit(Request, self(), State)),
        ?assertEqual({ok, [?HASH]}, gen_server:call(Pid, {request, Request}))
    after
        unlink(Pid),
        exit(Pid, kill)
    end.
