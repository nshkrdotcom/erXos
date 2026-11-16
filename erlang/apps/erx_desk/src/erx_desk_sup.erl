%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_desk_sup).
-moduledoc """
The desktop programs' supervisor (docs/design-desktop-programs.md, "The
construction" and "Shipping and starting"): one temporary child per open
window, erx_desk_window, which performs its inspections through
erx:inspect/2. A window that crashes ends with its UI, and the supervisor
does not restart it: the command opens a fresh one.
""".
-behaviour(supervisor).

-export([start_link/0, start_window/1, windows/0]).
-export([init/1]).

-doc "Starts the supervisor, registered as erx_desk_sup.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc """
Opens a window of Program, answering once its UI is open: `{ok, Pid}`, or
the toolkit's `{error, Reason}`.
""".
-spec start_window(erx_desk_window:program()) -> {ok, pid()} | {error, term()}.
start_window(Program) ->
    supervisor:start_child(?MODULE, [Program]).

-doc "The windows open now.".
-spec windows() -> [pid()].
windows() ->
    [Pid || {_Id, Pid, _Type, _Modules} <- supervisor:which_children(?MODULE), is_pid(Pid)].

-doc false.
init([]) ->
    Window = #{id => erx_desk_window,
               start => {erx_desk_window, start_link, [fun erx:inspect/2]},
               restart => temporary,
               type => worker,
               modules => [erx_desk_window]},
    {ok, {#{strategy => simple_one_for_one}, [Window]}}.
