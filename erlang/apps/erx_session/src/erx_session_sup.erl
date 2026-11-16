%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_sup).
-moduledoc """
The session's supervisor. Its children are the session's pipe server
(erx_pipe_srv), which a crash restarts for later pipes; the session's command
server (erx_command_srv), which assigns process ids and spawns every program's
handler, and which nothing restarts, since a new one could give an id again: a
significant child, its end ends the supervisor and with it the session
(docs/design-programs.md, "The command server"); the session's console
tty (erx_session_tty:start_link/0), which ends normally only when its line has
hung up, with every shell on it, and then nothing restarts it; a tty for each
master of the session that opens one (erx_session_tty:open/1), which nothing
restarts; and the two grants of the session's export (erx_session_export),
which serve its fixed tree to the session's own domain: an `rx` grant, through
which a program's handler reaches `/bin`, and an `rw` grant, through which it
reaches `/dev` and `/etc` (docs/design-files.md, "Narrowing for a program"). A
crash restarts a grant, which then serves new files.
""".
-behaviour(supervisor).

-include("generated/erx_abi.hrl").

-export([start_link/0, init/1]).
-export([export_args/3]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Tty = #{id => erx_session_tty,
            start => {erx_session_tty, start_link, []},
            restart => transient,
            type => worker,
            modules => [erx_session_tty, erx_console, erx_session_relay]},
    Pipes = #{id => erx_pipe_srv,
              start => {erx_pipe_srv, start_link, []},
              restart => permanent,
              type => worker,
              modules => [erx_pipe_srv, erx_pipe]},
    Commands = #{id => erx_command_srv,
                 start => {erx_command_srv, start_link, []},
                 restart => temporary,
                 significant => true,
                 type => worker,
                 modules => [erx_command_srv, erx_command_core]},
    {Table, _Problems} = erx_shell_namespace:from_applications([erx_shell]),
    Args = export_args(os:getenv(binary_to_list(?ERX_PRINCIPAL_KEY_BYTES)), node(),
                       erx_shell_namespace:commands(Table)),
    Exports = [#{id => {erx_session_export, Rights},
                 start => {erx_fs, start_link, [erx_session_export, Args, Rights]},
                 restart => permanent,
                 type => worker,
                 modules => [erx_fs, erx_session_export]} || Rights <- [rx, rw]],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10, auto_shutdown => any_significant},
          [Pipes, Commands, Tty | Exports]}}.

-doc """
What the session's export starts from (erx_session_export:args/0): its
principal's number, Number, the value of the session's `principal` variable,
which the domain library sets when it plans the session; its login name, the
prefix of the session's node name Node, which the domain service makes as the
principal's session prefix, an underscore and a number
(erx_domain_core:session_prefix/3 and session_name/3), so `root` for the system
principal and the manifest's name for any other; and the names Commands that
`/bin` lists.
""".
-spec export_args(string(), node(), [binary()]) -> erx_session_export:args().
export_args(Number, Node, Commands) ->
    [Name, _Host] = string:split(atom_to_binary(Node), <<"@">>),
    [Prefix, _N] = string:split(Name, <<"_">>, trailing),
    #{principal => #{name => Prefix, number => list_to_integer(Number)}, commands => Commands}.
