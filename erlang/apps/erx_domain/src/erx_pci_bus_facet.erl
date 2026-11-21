%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pci_bus_facet).
-moduledoc """
The `pci_bus` facet (docs/design-pcie.md, "Facets"; abi/services/pci_bus.txt):
the decoder of what the PCIe domain's enumerator asks of the device service,
and the facet's erx_facet callback, which the domain service mints for the
PCIe domain in front of itself.

A request is the term the funnel decoded from the grantee's frame, in safe
mode, held to the grant's max_request. decode/1 answers:

* `targets`;
* `{report, Functions}`, Functions a proper list of maps, each
  `#{record := Record, kept := boolean()}` with no other key, Record a map
  whose `bridge`, `bus`, `device` and `function` lie within a place's bounds,
  which the device service matches a function by; the rest of Record is the
  library's intake's to judge, which refuses the bridge's report whole on a
  record that does not encode;
* `{firmware, Bridge}`, Bridge a device row below 2^32;

or `{error, badarg}` for anything else. It creates no atom and never raises.

admit/3 forwards `{pci_bus, Grantee, Request}`, with the grantee the facet
was minted for, the PCIe incarnation whose report it is, to the
erx_devices_pci registered at that moment; with none registered it refuses
with `{error, unavailable}`.
""".
-behaviour(erx_facet).

-export([decode/1]).
-export([init/1, admit/3, operation/1]).

-define(IS_ROW(R), (is_integer(R) andalso R >= 0 andalso R < 1 bsl 32)).

-doc "Request when the interface takes it, or `{error, badarg}`.".
-spec decode(term()) -> {ok, targets | {report, [map()]} | {firmware, non_neg_integer()}} | {error, badarg}.
decode(targets) ->
    {ok, targets};
decode({report, Functions} = Request) ->
    case is_list(Functions) andalso lists:all(fun reported/1, proper(Functions)) of
        true -> {ok, Request};
        false -> {error, badarg}
    end;
decode({firmware, Bridge} = Request) when ?IS_ROW(Bridge) ->
    {ok, Request};
decode(_Request) ->
    {error, badarg}.

%% Functions' elements, with a non-element standing for an improper tail.
proper([Head | Tail]) -> [Head | proper(Tail)];
proper([]) -> [];
proper(_Tail) -> [improper].

reported(#{record := #{bridge := Bridge, bus := Bus, device := Device, function := Function}, kept := Kept} = Reported)
  when map_size(Reported) =:= 2, is_boolean(Kept), ?IS_ROW(Bridge), is_integer(Bus), Bus >= 0, Bus =< 255,
       is_integer(Device), Device >= 0, Device =< 31, is_integer(Function), Function >= 0, Function =< 7 ->
    true;
reported(_Element) ->
    false.

-doc "The operation of a request decode/1 admits; error for any other term.".
-spec operation(term()) -> {ok, targets | report | firmware} | error.
operation(Request) ->
    case decode(Request) of
        {ok, targets} -> {ok, targets};
        {ok, {Operation, _Argument}} -> {ok, Operation};
        {error, badarg} -> error
    end.

-spec init(erx_facet:grant()) -> {ok, #{grantee := pos_integer()}}.
init(#{grantee := Grantee}) ->
    {ok, #{grantee => Grantee}}.

admit(Request, _From, #{grantee := Grantee} = State) ->
    case {decode(Request), whereis(erx_devices_pci)} of
        {{error, badarg}, _Process} -> {refuse, badarg, State};
        {{ok, _Operation}, undefined} -> {refuse, unavailable, State};
        {{ok, Operation}, Process} -> {forward, Process, {pci_bus, Grantee, Operation}, State}
    end.
