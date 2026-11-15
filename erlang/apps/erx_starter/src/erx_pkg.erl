%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg).
-moduledoc """
The package process (docs/design-packaging.md, "The package lifetime" and
"Boot and recovery"). One run of it is a lifetime: it begins with the
recovery, which reconciles the image's packages and the data partition's
`packages/` directory into each package's state, the path table and the
package set, and publishes the set to the start service.

`init/1` returns at once and the recovery runs in `handle_continue/2`, so a
recovery that crashes is a restart within erx_pkg_sup's intensity, never a
failed start of the start service's application. The recovery's decisions
are erx_pkg_plan's; this process carries out each action it gives: every
request on the packages through erx_pkg_io, named by this pid as its
lifetime, admission through `erx_app_admit:admit/3`, registration through
`erx_principal:register_app/2`, and the publication through
`erx_starter:packages/2`. A failed change stops the process, which ends the
lifetime: erx_pkg_io refuses every later request of it, and the next
lifetime's recovery starts again.

`packages/0` answers the scan and each package's record, which
`/proc/packages` shows; until the recovery is done the scan is `unknown`
and no package is listed.
""".
-behaviour(gen_server).

-export([start_link/1, packages/0]).
-export_type([config/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2]).

-doc """
The recovery's inputs: erx_pkg_plan's config and the manifest that
admission reads.
""".
-type config() :: #{images := [{binary(), <<_:256>>}],
                    signers := [{erx_pkg_header:signer(), <<_:256>>}],
                    max := pos_integer(),
                    manifest := erx_app_admit:manifest()}.

-doc "Start a lifetime of the package process.".
-spec start_link(config()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

-doc "The scan of `packages/` and each listed package's record.".
-spec packages() -> #{scan := erx_pkg_plan:scan(),
                      packages := #{{system | installed, binary()} => erx_pkg_plan:package_record()}}.
packages() ->
    gen_server:call(?MODULE, packages).

init(Config) ->
    {ok, #{config => Config, scan => unknown, packages => #{}}, {continue, recover}}.

handle_continue(recover, #{config := Config} = State) ->
    PlanConfig = maps:with([images, signers, max], Config),
    recover(erx_pkg_plan:recover(start, PlanConfig), State).

handle_call(packages, _From, #{scan := Scan, packages := Packages} = State) ->
    {reply, #{scan => Scan, packages => Packages}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

recover({{done, #{scan := Scan, packages := Packages}}, _Plan}, State) ->
    {noreply, State#{scan := Scan, packages := Packages}};
recover({{stop, Reason}, _Plan}, State) ->
    logger:error("packages: the recovery stops: ~0tp", [Reason]),
    {stop, {recovery, Reason}, State};
recover({Action, Plan}, State) ->
    recover(erx_pkg_plan:recover(effect(Action, State), Plan), State).

%% Each action of the plan, carried out; its answer goes back to the plan.
effect(begin_lifetime, _State) ->
    erx_pkg_io:request({begin_lifetime, self()});
effect({header, Place, File}, _State) ->
    erx_pkg_io:request({header, self(), Place, File});
effect(list, _State) ->
    erx_pkg_io:request({list, self()});
effect({delete, File}, _State) ->
    erx_pkg_io:request({delete, self(), File});
effect({path_entry, Place, File, Entry}, _State) ->
    erx_pkg_io:request({path_entry, self(), Place, File, Entry});
effect({admit, Checked}, #{config := #{manifest := Manifest}}) ->
    erx_app_admit:admit(Checked, Manifest, erx_principal:app_registry());
effect({register, Name, Admitted}, _State) ->
    erx_principal:register_app(Name, Admitted);
effect({publish, Set}, _State) ->
    erx_starter:packages(self(), Set).
