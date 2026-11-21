%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pci_facet).
-moduledoc """
The `pci` facet (docs/design-pcie.md, "Facets"; abi/services/pci.txt): the
decoder of what a domain that drives a PCIe function asks of the device
service, and the facet's erx_facet callback, which the domain service mints
for each grantee of `pci` in front of itself.

A request is the term the funnel decoded from the grantee's frame, in safe
mode, and erx_facet has already held its encoding to the grant's
max_request. decode/1 answers `{Operation, Place}`, Operation `open`,
`master` or `reset` and Place `{Bridge, Bus, Device, Function}` within the
bounds of a place (a device row below 2^32, a bus below 256, a device below
32, a function below 8), or `{error, badarg}` for anything else, so the
core only ever sees erx_devices_pci_core:request()'s shape. It creates no
atom and never raises.

admit/3 forwards `{pci, Grantee, Request}`, with the grantee the facet was
minted for, so the request never names its source, to the erx_devices_pci
registered at that moment, so a facet outlives the process's restarts; with
none registered it refuses with `{error, unavailable}`. Whether Place is one
of the grantee's own rows is the process's to answer.
""".
-behaviour(erx_facet).

-export([decode/1]).
-export([init/1, admit/3, operation/1]).

-doc "Request when the interface takes it, or `{error, badarg}`.".
-spec decode(term()) -> {ok, {open | master | reset, erx_devices_pci_core:place()}} | {error, badarg}.
decode({Operation, {Bridge, Bus, Device, Function}} = Request)
  when (Operation =:= open orelse Operation =:= master orelse Operation =:= reset),
       is_integer(Bridge), Bridge >= 0, Bridge < 1 bsl 32, is_integer(Bus), Bus >= 0, Bus =< 255,
       is_integer(Device), Device >= 0, Device =< 31, is_integer(Function), Function >= 0, Function =< 7 ->
    {ok, Request};
decode(_Request) ->
    {error, badarg}.

-doc "The operation of a request decode/1 admits, its first element; error for any other term.".
-spec operation(term()) -> {ok, open | master | reset} | error.
operation(Request) ->
    case decode(Request) of
        {ok, {Operation, _Place}} -> {ok, Operation};
        {error, badarg} -> error
    end.

-spec init(erx_facet:grant()) -> {ok, #{grantee := pos_integer()}}.
init(#{grantee := Grantee}) ->
    {ok, #{grantee => Grantee}}.

admit(Request, _From, #{grantee := Grantee} = State) ->
    case {decode(Request), whereis(erx_devices_pci)} of
        {{error, badarg}, _Process} -> {refuse, badarg, State};
        {{ok, _Operation}, undefined} -> {refuse, unavailable, State};
        {{ok, Operation}, Process} -> {forward, Process, {pci, Grantee, Operation}, State}
    end.
