%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_sup).
-moduledoc """
The package process's supervisor (docs/design-packaging.md, "Where the
package process is supervised"). It restarts erx_pkg within its intensity,
each restart a new lifetime that begins with the recovery. It is a
temporary child of the start service's top supervisor, and not a
significant one, so its end past its intensity is not restarted and ends
nothing else: the package process stays down, and the start service keeps
the last set it was given. erx_pkg_io is not below it.
""".
-behaviour(supervisor).

-export([start_link/1, child_spec/1]).
-export([init/1]).

-define(INTENSITY, 3).
-define(PERIOD, 60).

-doc "Start the supervisor and its one child, erx_pkg, with Config.".
-spec start_link(erx_pkg:config()) -> supervisor:startlink_ret().
start_link(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

-doc "The supervisor as a temporary, non-significant child of the top supervisor.".
-spec child_spec(erx_pkg:config()) -> supervisor:child_spec().
child_spec(Config) ->
    #{id => ?MODULE, start => {?MODULE, start_link, [Config]},
      restart => temporary, significant => false, type => supervisor}.

init(Config) ->
    {ok, {#{strategy => one_for_one, intensity => ?INTENSITY, period => ?PERIOD},
          [#{id => erx_pkg, start => {erx_pkg, start_link, [Config]},
             restart => permanent, type => worker}]}}.
