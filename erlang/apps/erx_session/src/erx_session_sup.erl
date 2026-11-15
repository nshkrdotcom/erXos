%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_sup).
-moduledoc """
The session's supervisor. Its children are the session's pipe server
(erx_pipe_srv), which a crash restarts for later pipes; the session's console
tty (erx_session_tty:start_link/0), which ends normally only when its line has
hung up, with every shell on it, and then nothing restarts it; and a tty for
each master of the session that opens one (erx_session_tty:open/1), which
nothing restarts.
""".
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Tty = #{id => erx_session_tty,
            start => {erx_session_tty, start_link, []},
            restart => transient,
            type => worker,
            modules => [erx_session_tty, erx_console]},
    Pipes = #{id => erx_pipe_srv,
              start => {erx_pipe_srv, start_link, []},
              restart => permanent,
              type => worker,
              modules => [erx_pipe_srv, erx_pipe]},
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, [Pipes, Tty]}}.
