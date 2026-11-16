%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_clock_facet).
-moduledoc """
The decoder of a request a clock facet admits (docs/design-time.md, "The
clock facet"): the one reader of what another domain sends the wall
clock's authority, pure. A request is the term the funnel decoded from the
grantee's frame, in safe mode, so every atom in it already existed, and
erx_facet has already held its encoding to the grant's max_request. The
interface has two operations:

* `{sample, W, Distance, Stratum, Server}`, ntpd's: W a wall offset in
  0..time_offset_max nanoseconds, the setter's own range; Distance in
  0..clock_distance_max_ns - 1; Stratum in 1..15; Server an IPv4 address,
  four integers of 0 to 255.
* `{set, W}`, the operator's, W in the same range.

decode/1 answers the request itself or `{error, badarg}` for anything else:
another operation or arity, a value outside its range or of another type.
It creates no atom and never raises.

It is also the clock facet's erx_facet callback, which the domain service
mints for each grantee of `clock` in front of erx_clock's supervisor.
operation/1 names the operation of what decode/1 admits and nothing else,
so the facet's check of the grant's operations and admit/3 cannot read one
request two ways: a grant of `sample` alone refuses a set with
`{error, eperm}` and a grant of `set` alone a sample. admit/3 forwards
`{sample, Grantee, Sample}` or `{set, Grantee, W}`, with the grantee the
facet was minted for, so the request never names its source, to the
erx_clock registered at that moment, so a facet outlives the service's
restarts; with none registered it refuses with `{error, unavailable}`.
""".
-behaviour(erx_facet).

-export([decode/1]).
-export([init/1, admit/3, operation/1]).

-include("generated/erx_abi.hrl").

-define(IS_OFFSET(W), (is_integer(W) andalso W >= 0 andalso W =< ?ERX_TIME_OFFSET_MAX)).

-doc "Request when the interface takes it, or `{error, badarg}`.".
-spec decode(term()) -> {ok, erx_clock_core:request()} | {error, badarg}.
decode({sample, W, Distance, Stratum, Server} = Sample)
  when ?IS_OFFSET(W), is_integer(Distance), Distance >= 0, Distance < ?ERX_CLOCK_DISTANCE_MAX_NS,
       is_integer(Stratum), Stratum >= 1, Stratum =< 15 ->
    case address(Server) of
        true -> {ok, Sample};
        false -> {error, badarg}
    end;
decode({set, W} = Set) when ?IS_OFFSET(W) ->
    {ok, Set};
decode(_Request) ->
    {error, badarg}.

-doc "The operation of a request decode/1 admits, its first element; error for any other term.".
-spec operation(term()) -> {ok, sample | set} | error.
operation(Request) ->
    case decode(Request) of
        {ok, Decoded} -> {ok, element(1, Decoded)};
        {error, badarg} -> error
    end.

-spec init(erx_facet:grant()) -> {ok, #{grantee := pos_integer()}}.
init(#{grantee := Grantee}) ->
    {ok, #{grantee => Grantee}}.

-spec admit(term(), pid(), #{grantee := pos_integer()}) ->
          {forward, pid(), {sample, pos_integer(), erx_clock_core:request()} | {set, pos_integer(), non_neg_integer()},
           map()}
        | {refuse, badarg | unavailable, map()}.
admit(Request, _From, #{grantee := Grantee} = State) ->
    case {decode(Request), whereis(erx_clock)} of
        {{error, badarg}, _Clock} -> {refuse, badarg, State};
        {{ok, _Decoded}, undefined} -> {refuse, unavailable, State};
        {{ok, {sample, _W, _Distance, _Stratum, _Server} = Sample}, Clock} ->
            {forward, Clock, {sample, Grantee, Sample}, State};
        {{ok, {set, W}}, Clock} -> {forward, Clock, {set, Grantee, W}, State}
    end.

address({A, B, C, D}) -> lists:all(fun(Byte) -> is_integer(Byte) andalso Byte >= 0 andalso Byte =< 255 end, [A, B, C, D]);
address(_Server) -> false.
