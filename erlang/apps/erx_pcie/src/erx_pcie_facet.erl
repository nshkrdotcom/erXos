%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_facet).
-moduledoc """
The `pcie` facet (docs/design-pcie.md, "Facets"; abi/services/pcie.txt): what
the system domain's device service asks of the enumerator once it has
answered that incarnation's report. The PCIe domain serves it under the
service `pcie`, which the manifest grants to the system domain alone, and
its mint refuses a grant to any other grantee, the decision the
driver-control facet's mint makes (erx_driver_ctl:mint_request/3).

The facet admits the two requests erx_pcie_enumerator's set/3 and reset/2
make, and forwards each to the enumerator, which it finds by its
registered name:

* `{set, Key, Setting}`, Key a function's bridge row and place, and
  Setting a map the codec encodes as an `erx_pcie_setting`;
* `{reset, Key}`.

Any other request, and one whose Key or Setting is not of that shape, is
refused with `badarg` before the enumerator sees it (well_formed/1), so no
request of the grantee's can end the enumerator by its shape. The facet
has no operation/1: its manifest row lists no operations, as a configured
domain's service names none on Fiasco (docs/design-time.md, "On Fiasco"),
and the grantee may invoke both. A request that finds no
enumerator registered, before the domain row's `-eval` has started it,
is refused with `unavailable`.

The mint (start_link/0) is a process of its own, not the enumerator, for
two reasons: the mint must be named before init's ready report, while
the enumerator starts only after it, once the ready answer has brought
its `pci_bus` facet; and the enumerator is waiting for the answer to its
report while the system domain mints the grant, which the device
service awaits before it answers. Both run below erx_pcie_sup, which
ends the other when either ends, so no mint outlives its enumerator. A
facet ends with its mint, so no facet outlives the mint either.
""".

-behaviour(erx_facet).

-export([start_link/0]).
-export([mint_init/1]).
-export([init/1, admit/3]).

-include("generated/erx_abi.hrl").

-doc """
Starts the mint of `pcie`, linked to the caller, erx_pcie_sup, and names it
the service's mint with erx_facet:provide/2 before it returns, so before
init's ready report.
""".
-spec start_link() -> {ok, pid()}.
start_link() ->
    proc_lib:start_link(?MODULE, mint_init, [self()]).

-doc false.
mint_init(Parent) ->
    ok = erx_facet:provide(pcie, self()),
    proc_lib:init_ack(Parent, {ok, self()}),
    mint(erx_kernel_records:system_domain()).

mint(System) ->
    receive
        Message ->
            _ = case erx_driver_ctl:mint_request(System, pcie, Message) of
                    {grant, Tag, Limits} ->
                        Grant = Limits#{grantee => System, ends_with => [self()]},
                        erx_facet:minted(Tag, erx_facet:start(?MODULE, Grant, #{}));
                    {refuse, Tag} ->
                        erx_facet:minted(Tag, {error, eperm});
                    unknown ->
                        ok
                end,
            mint(System)
    end.

-doc false.
init(_Grant) ->
    {ok, none}.

-doc false.
admit(Request, _From, State) ->
    case {well_formed(Request), whereis(erx_pcie_enumerator)} of
        {false, _Enumerator} -> {refuse, badarg, State};
        {true, undefined} -> {refuse, unavailable, State};
        {true, Enumerator} -> {forward, Enumerator, Request, State}
    end.

well_formed({set, Key, Setting}) -> key(Key) andalso setting(Setting);
well_formed({reset, Key}) -> key(Key);
well_formed(_Request) -> false.

key({Bridge, Bus, Device, Function}) ->
    is_integer(Bridge) andalso Bridge >= 0 andalso is_integer(Bus) andalso Bus >= 0 andalso Bus =< 255
        andalso is_integer(Device) andalso Device >= 0 andalso Device =< ?ERX_PCIE_DEVICE_MAX
        andalso is_integer(Function) andalso Function >= 0 andalso Function =< ?ERX_PCIE_FUNCTION_MAX;
key(_Key) ->
    false.

%% A setting the codec encodes is one the enumerator's planner takes: its
%% mode and route members of their enums and its message in range.
setting(Setting) when is_map(Setting) ->
    try erx_abi_layout:encode(erx_pcie_setting, Setting) of
        _Bytes -> true
    catch
        error:_ -> false
    end;
setting(_Setting) ->
    false.
