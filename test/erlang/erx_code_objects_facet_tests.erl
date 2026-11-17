%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The EUnit cases of the code_objects facet (erx_code_objects_facet;
%% docs/design-system.md, "Creating a domain", "The code_objects facet"): the
%% decoder takes the interface's two operations and nothing else, and admit/3
%% forwards each with the grantee the facet was minted for, never a session
%% the request could name.
-module(erx_code_objects_facet_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

decode_takes_the_two_operations_test() ->
    ?assertEqual({ok, {create, 4096}}, erx_code_objects_facet:decode({create, 4096})),
    ?assertEqual({ok, {create, (1 bsl 64) - 1}}, erx_code_objects_facet:decode({create, (1 bsl 64) - 1})),
    ?assertEqual({ok, {drop, 1}}, erx_code_objects_facet:decode({drop, 1})),
    ?assertEqual({ok, {drop, (1 bsl 32) - 1}}, erx_code_objects_facet:decode({drop, (1 bsl 32) - 1})).

decode_refuses_everything_else_test() ->
    Bad = [{create, 0}, {create, -1}, {create, 1 bsl 64}, {create, 1.0}, {create, <<"1">>},
           {drop, 0}, {drop, 1 bsl 32}, {drop, a}, {create, 1, 2}, {drop, 1, 2}, {create, 7, 3},
           create, {resize, 1}, [create, 1], #{create => 1}, {}],
    [?assertEqual({error, badarg}, erx_code_objects_facet:decode(Request)) || Request <- Bad].

admit_forwards_with_the_grantee_test() ->
    Behind = self(),
    {ok, State} = erx_code_objects_facet:init(#{grantee => 7, behind => Behind, ends_with => []}),
    ?assertEqual({forward, Behind, {code_object, 7, 8192}, State},
                 erx_code_objects_facet:admit({create, 8192}, self(), State)),
    ?assertEqual({forward, Behind, {code_drop, 7, 3}, State},
                 erx_code_objects_facet:admit({drop, 3}, self(), State)),
    %% A request that names another session is no operation of the interface.
    ?assertEqual({refuse, badarg, State}, erx_code_objects_facet:admit({create, 9, 8192}, self(), State)),
    ?assertEqual({refuse, badarg, State}, erx_code_objects_facet:admit({drop, 9, 3}, self(), State)).

%% The largest request a session can send, a create of a size below 2^64 with the
%% largest grantee, from a caller whose pid and alias, a reference of five words, the
%% most one has, each carry a node name of 255 bytes, the longest an atom holds, fits
%% the facet's max_request (abi/services/code_objects.txt), so erx_facet never drops a
%% request the interface takes.
largest_request_fits_max_request_test() ->
    Node = binary:copy(<<"n">>, 255),
    Pid = binary_to_term(<<131, 88, 119, 255, Node/binary, 0:32, 0:32, 16#ffffffff:32>>),
    Alias = binary_to_term(<<131, 90, 5:16, 119, 255, Node/binary, 16#ffffffff:32, 0:160>>),
    Envelope = {erx_origin, (1 bsl 32) - 1, {'$gen_call', {Pid, [alias | Alias]}, {create, (1 bsl 64) - 1}}},
    ?assertEqual(114 + 2 * 255, erlang:external_size(Envelope)),
    ?assert(erlang:external_size(Envelope) =< ?ERX_CODE_OBJECTS_MAX_REQUEST).
