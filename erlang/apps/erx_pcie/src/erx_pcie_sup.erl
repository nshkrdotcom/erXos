%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_sup).
-moduledoc """
The PCIe domain's application, erx_pcie, and its one supervisor
(docs/design-pcie.md, "Processes"), over the domain's two processes:

* the mint of the `pcie` facet (erx_pcie_facet), which the boot script
  starts, so that it names itself the service's mint before init's ready
  report and the system domain can be granted `pcie` at all;
* the enumerator (erx_pcie_enumerator), registered under its module's
  name, which the domain row's `-eval ok=erx_pcie_sup:start_enumerator()`
  starts once init holds the ready answer's facets, `pci_bus` among them.

The supervisor is one_for_all with intensity 0: the end of either process
ends the other and the supervisor, so the permanent application stops and
the domain with it, and the domain service's restart is the recovery. No
mint outlives its enumerator, and no enumerator runs without its mint.
""".
-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1]).
-export([start_enumerator/0]).
-export([start_link/0, init/1]).

-doc "The application's start: the supervisor and the mint below it.".
start(_Type, _Args) ->
    start_link().

stop(_State) ->
    ok.

-doc "Starts the supervisor, registered under its module's name, with the mint below it.".
-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc """
Starts the enumerator below the supervisor, for the domain row's `-eval`;
any other answer than `ok` fails the eval and so the domain's boot.
""".
-spec start_enumerator() -> ok.
start_enumerator() ->
    {ok, _Enumerator} = supervisor:start_child(?MODULE, #{id => enumerator,
                                                          start => {erx_pcie_enumerator, start_link, []}}),
    ok.

init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 0, period => 1},
          [#{id => mint, start => {erx_pcie_facet, start_link, []}}]}}.
