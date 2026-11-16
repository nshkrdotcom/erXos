%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_link_sup).
-moduledoc """
The link processes' supervisor (docs/design-bluetooth.md, "Concurrency"), registered as
`erx_bt_link_sup`, first in the controller group: each link is a temporary child the
controller process starts at `link_up` and ends at `link_down`, never restarted, so a link
that ends is disconnected and the phone reconnects. It ends with the group, so no link
outlives the core that named it.
""".
-behaviour(supervisor).

-export([start_link/0, start_child/1, stop_link/1]).
-export([init/1]).

-doc "Starts the supervisor, registered as `erx_bt_link_sup`.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc "Starts a link with `erx_bt_link:start_link/1`'s argument.".
-spec start_child(map()) -> supervisor:startchild_ret().
start_child(Start) ->
    supervisor:start_child(?MODULE, [Start]).

-doc "Ends a link.".
-spec stop_link(pid()) -> ok | {error, not_found}.
stop_link(Link) ->
    supervisor:terminate_child(?MODULE, Link).

init([]) ->
    {ok, {#{strategy => simple_one_for_one, intensity => 0, period => 1},
          [#{id => erx_bt_link, start => {erx_bt_link, start_link, []}, restart => temporary,
             shutdown => 1000}]}}.
