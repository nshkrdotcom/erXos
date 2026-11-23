%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_code_facet).
-moduledoc """
The install facet (docs/design-live.md, "Code from the host", "One load, three
routes"): the erx_facet callback the domain service mints, in the system domain, for
each grantee of the `install` service, a service of the `code` interface
(abi/services/code.txt), in front of erx_code_sup. Through it a session's `load -s`
loads modules into the system domain with the exchange the host link's install facet
runs: `missing`, a `put` for each piece the store lacks, then `load`.

* **Its scope** is the system domain alone, which the request cannot name: a `load`
  carries a manifest and nothing else, and erx_code loads only into its own runtime.
* **Its operations.** operation/1 names a request's operation by its tag and arity
  alone, `{missing, _}`, `{put, _, _, _, _}` or `{load, _}`, and the code service's one
  reader of a request, erx_code_store:read_request/1, reads the rest and gives its own
  reason for what it refuses, as through the host link's install facet. `history`,
  which the inspector answers through an inspect facet, is no operation of the
  interface and is refused with `{error, badarg}`.
* **Its work.** admit/3 forwards the request whole, as erx_code:call/1 takes it, to
  the erx_code registered at that moment, so a facet outlives the service's restarts;
  with none registered it refuses with `{error, unavailable}`. The grant's one request
  in flight is the design's one load at a time for each facet.
""".
-behaviour(erx_facet).

-export([init/1, operation/1, admit/3]).

-spec init(erx_facet:grant()) -> {ok, #{}}.
init(#{}) ->
    {ok, #{}}.

-doc "The interface operation Request invokes, or `error` for anything else.".
-spec operation(term()) -> {ok, missing | put | load} | error.
operation(Request) ->
    case Request of
        {missing, _} -> {ok, missing};
        {put, _, _, _, _} -> {ok, put};
        {load, _} -> {ok, load};
        _ -> error
    end.

-spec admit(term(), pid(), map()) -> {forward, pid(), {request, term()}, map()} | {refuse, unavailable, map()}.
admit(Request, _From, State) ->
    case whereis(erx_code) of
        undefined -> {refuse, unavailable, State};
        Service -> {forward, Service, {request, Request}, State}
    end.
