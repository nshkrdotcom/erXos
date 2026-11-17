%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_code_objects_facet).
-moduledoc """
The code_objects facet (docs/design-system.md, "Creating a domain", "The
code_objects facet"; abi/services/code_objects.txt): the decoder of a request
a session sends for its code objects, and the facet's erx_facet callback,
which the domain service mints for every session it starts in front of
itself.

A request is the term the funnel decoded from the session's frame, in safe
mode, and erx_facet has already held its encoding to the grant's
max_request. The interface has two operations:

* `{create, Size}`, Size a positive integer below 2^64, the object's size
  in bytes;
* `{drop, Number}`, Number a positive integer below 2^32, an object's
  number, as the library numbers them.

decode/1 answers the operation, or `{error, badarg}` for anything else. The
request names no session: admit/3 forwards `{code_object, Grantee, Size}` or
`{code_drop, Grantee, Number}` with the grantee the facet was minted for, so
a session makes objects only from its own budget and drops only its own.
Whether Size fits the session's budget and whether Number is the session's
are the domain library's to answer. It implements erx_facet's callbacks
without naming the behaviour, as erx_domain_facet does.
""".

-export([decode/1]).
-export([init/1, admit/3]).

-type operation() :: {create, pos_integer()} | {drop, pos_integer()}.

-doc "The operation Request carries, or `{error, badarg}` for anything the interface does not take.".
-spec decode(term()) -> {ok, operation()} | {error, badarg}.
decode({create, Size} = Operation) when is_integer(Size), Size > 0, Size < 1 bsl 64 ->
    {ok, Operation};
decode({drop, Number} = Operation) when is_integer(Number), Number > 0, Number < 1 bsl 32 ->
    {ok, Operation};
decode(_Request) ->
    {error, badarg}.

init(#{grantee := Grantee, behind := Behind}) ->
    {ok, #{grantee => Grantee, behind => Behind}}.

admit(Request, _From, #{grantee := Grantee, behind := Behind} = State) ->
    case decode(Request) of
        {ok, {create, Size}} -> {forward, Behind, {code_object, Grantee, Size}, State};
        {ok, {drop, Number}} -> {forward, Behind, {code_drop, Grantee, Number}, State};
        {error, badarg} -> {refuse, badarg, State}
    end.
