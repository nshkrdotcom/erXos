%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_tty).
-moduledoc """
A session's ttys (docs/design-live.md, "The tty", "Where a tty lives", "Between
domains"), each with the command shell on it, and each driven by a terminal
relay of its own (erx_session_relay, docs/design-shell.md, "The terminal relay's
protocol"), which runs the tty's line discipline, carries its bytes to and from
its master in the six messages, and is read by its console on demand
(docs/design-shell.md, "The console reads on demand"):

* the session's console tty (start_link/0), whose master is the console facet
  that erx:cap(console) names; erx_session_sup starts it at boot, and it is the
  domain's line (erx_console:terminal/0), whose console holds the domain's
  `user`, so `user` lives as long as the line whichever other ttys end. Its
  relay alone is registered, under the name the runtime's own writers look
  for (erx_session_relay:start_link/3);
* a tty for each master in the session's own domain that asks for one with
  open/1, as a terminal on a display does (docs/design-display.md, "The
  terminal"), much as a program's posix_openpt makes a pseudo-terminal. Its
  relay holds no name: its console reaches it by pid, and every open names the
  relay that made it.

A tty is two processes. The groups that run its shells are driven by a console
of the session role (erx_console:start_link/1), unregistered, exactly as the
system domain's console drives its own: the command shell on the first group,
started again whenever it ends (as on the UART), and run_shell and write with
erx_console's meaning on the tty's terminal, erx_console:terminal(Console). The
relay is the console's line driver and ends with it.

A message from the master arrives as `{erx_origin, D, Msg}` when the master is
in another domain, and the relay takes the envelope off only when `D` is the
master's domain. A master in the session's own domain sends plain messages, and
its end is the tty's hangup, as a pseudo-terminal master's close is
(docs/design-programs.md, "The terminal"): the console ends the tty's shells and
then itself, its relay with it, and the session's other ttys run on.
""".

-export([start_link/0, start_link/1, open/1]).

-doc """
Starts the session's console tty, with the master erx:cap(console) names, as the
domain's line, whose console holds the domain's `user` and whose relay is
registered. Returns its console.
""".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_console(erx:cap(console), #{domain_line => true}).

-doc """
Starts a tty whose master is Master, a process of this domain, linked to the
caller. Returns its console; the master learns the tty, its relay, from its
`{tty_open, Tty}`.
""".
-spec start_link(pid()) -> {ok, pid()} | {error, term()}.
start_link(Master) when is_pid(Master), node(Master) =:= node() ->
    start_console(Master, #{user => none}).

-doc """
Opens a new tty of the session for Master, a process of this domain, under the
session's supervisor, which never restarts it: it ends with its master. Returns
its console.
""".
-spec open(pid()) -> {ok, pid()} | {error, term()}.
open(Master) when is_pid(Master), node(Master) =:= node() ->
    supervisor:start_child(erx_session_sup,
                           #{id => {?MODULE, make_ref()},
                             start => {?MODULE, start_link, [Master]},
                             restart => temporary,
                             type => worker,
                             modules => [?MODULE, erx_console, erx_session_relay]}).

%% A console of the session role driven by a relay for Master, the relay of the
%% domain's line when Options says the console is that line, and whose first
%% shell is the command shell on that console's own terminal.
start_console(Master, Options) ->
    RelayOptions = maps:with([domain_line], Options),
    erx_console:start_link(Options#{role => session,
                                    driver => fun(Console) ->
                                                      {ok, Pid} = erx_session_relay:start_link(Console, Master,
                                                                                               RelayOptions),
                                                      {ok, Pid, relay}
                                              end,
                                    first_shell => fun(Terminal) ->
                                                           {erx_shell, server, [{erx_shell_runner, Terminal}]}
                                                   end}).
