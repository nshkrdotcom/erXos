%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_line).
-moduledoc """
The session's line to the SSH domain (docs/design-ssh.md, "Sessions, ttys
and shells"): the process through which the SSH domain's channels open the
session's ttys. The decisions are erx_ssh_line_core's; this module hears the
messages, carries out what the core decides and answers.

The line is an erx_session_line, which owns who reaches it: it serves one
peer, the SSH domain the system domain exported it to as a login of that
domain starts the session (erx_domain:line/3), and it
takes from that peer only calls in the peer's envelope whose caller and alias
are names of the peer's, so a reply never goes to a third domain. The
session names the line to the domain service in its ready report
(erx_ssh_line_app). This module serves the calls the line admits (request/4)
and the session's own messages to the line (info/3).

An open tty is a tty of the session's (erx_session_tty:open_channel/3) whose
master is the channel and on which Run runs. When what ran has ended and the
channel has taken the tty's last output, the tty's console tells the line how
it ended (erx_console:shell_ending/1) and ends, which the line sees through
its monitor; the line sends the channel that ending, `{exited, Status}`, or
`{signaled, sigint}` for an exec Ctrl-C ended, a signal of the signal set
ssh_line of abi/signals.txt, so every message the channel hears from the
session but the tty's own comes from the line.
""".

-behaviour(erx_session_line).

-export([start_link/1]).
-export([init/1, request/4, info/3]).

-export_type([config/0]).

%% The line's keys, peer, system and exports, as erx_session_line:config() has them,
%% and open, which opens a channel's tty, erx_session_tty:open_channel/3 or a host
%% test's stand-in.
-type config() :: #{open => fun((pid(), erx_session_tty:channel(),
                                 fun((erx_prog:status()) -> term())) ->
                                       {ok, pid()} | {error, term()}),
                    atom() => term()}.

-doc "Starts the line for Config, linked to the caller.".
-spec start_link(config()) -> {ok, pid()}.
start_link(Config) when is_map(Config) ->
    erx_session_line:start_link(?MODULE, maps:merge(#{open => fun erx_session_tty:open_channel/3}, Config)).

%% The line's state: Owner, the domain of a pid as the export table answers it, the
%% tty opener and the core.
-doc false.
init(#{exports := Exports, open := Open}) ->
    #{owner => fun Exports:owner/1, open => Open, core => erx_ssh_line_core:new()}.

%% A request from the peer, answered as the core decides. A tty that cannot be
%% started, a session out of room, is answered `limited`, as a full line is. The
%% tty's console reports how its shell ended by calling Notify, which tells the line.
-doc false.
request(From, Request, Peer, #{owner := Owner, open := Open, core := Core} = State) ->
    Line = self(),
    Notify = fun(Ending) -> Line ! {?MODULE, ended, self(), Ending} end,
    case erx_ssh_line_core:request(Request, Peer, Owner, Core) of
        {open_tty, Channel, Spec} ->
            case Open(Channel, Spec, Notify) of
                {ok, Tty} ->
                    _ = erlang:monitor(process, Tty),
                    gen:reply(From, ok),
                    State#{core := erx_ssh_line_core:opened(Tty, Channel, Core)};
                {error, _Reason} ->
                    gen:reply(From, {error, limited}),
                    State
            end;
        {error, _Reason} = Error ->
            gen:reply(From, Error),
            State
    end.

%% The session's own messages to the line: a tty's report, through the Notify
%% request/4 gave it, for its channel, and the end of a tty the line monitors.
-doc false.
info({?MODULE, ended, Tty, Ending}, _Peer, #{core := Core} = State) when is_pid(Tty) ->
    case erx_ssh_line_core:report(Tty, Core) of
        {send, Channel} -> Channel ! Ending;
        drop -> ok
    end,
    State;
info({'DOWN', _Ref, process, Tty, _Reason}, _Peer, #{core := Core} = State) ->
    State#{core := erx_ssh_line_core:ended(Tty, Core)};
info(_Message, _Peer, State) ->
    State.
