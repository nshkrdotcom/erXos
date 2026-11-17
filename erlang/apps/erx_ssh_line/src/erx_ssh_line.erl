%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_line).
-moduledoc """
The session's line to the SSH domain (docs/design-ssh.md, "Sessions, ttys
and shells"): the process through which the SSH domain's channels open the
session's ttys. The decisions are erx_ssh_line_core's; this process hears
the messages, carries out what the core decides and answers.

The line serves one peer, the SSH domain it was exported to, and none until
then. The session names the line to the domain service in its ready report
(erx_ssh_line_app), and the system domain, as a login of that domain starts
the session, introduces the two domains and calls the line with
`{export, Ssh}`: the line exports itself to domain Ssh with send and serves
Ssh from then on. The line takes that call only in the system domain's
envelope, so no other domain, and no process of the session, chooses who
reaches it (erx_domain:line/3).

From its peer it takes a request only as a call in the peer's envelope whose
caller and alias are names of the peer's, as erx_web_line does, so a reply
never goes to a third domain; anything else from another domain is dropped.

An open tty is a tty of the session's (erx_session_tty:open_channel/3) whose
master is the channel and on which Run runs. When what ran has ended and the
channel has taken the tty's last output, the tty's console tells the line how
it ended (erx_console:shell_ending/1) and ends, which the line sees through
its monitor; the line sends the channel that ending, `{exited, Status}`, or
`{signaled, sigint}` for an exec Ctrl-C ended, a signal of the signal set
ssh_line of abi/signals.txt, so every message the channel hears from the
session but the tty's own comes from the line.
""".

-export([start_link/1]).
-export([line_init/2]).

-export_type([config/0]).

%% system is the system domain's id. exports answers export/3 and owner/1,
%% erx_dist or a host test's stand-in, and open opens a channel's tty,
%% erx_session_tty:open_channel/3 or a host test's stand-in.
-type config() :: #{system => pos_integer(),
                    exports => module(),
                    open => fun((pid(), erx_session_tty:channel(),
                                 fun((erx_prog:status()) -> term())) ->
                                       {ok, pid()} | {error, term()})}.

-doc "Starts the line for Config, linked to the caller.".
-spec start_link(config()) -> {ok, pid()}.
start_link(Config) when is_map(Config) ->
    Defaults = #{exports => erx_dist, open => fun erx_session_tty:open_channel/3},
    proc_lib:start_link(?MODULE, line_init, [self(), maps:merge(Defaults, Config)]).

-doc false.
line_init(Parent, Config) ->
    process_flag(trap_exit, true),
    System = case Config of
                 #{system := Id} -> Id;
                 #{} -> erx_kernel_records:system_domain()
             end,
    proc_lib:init_ack(Parent, {ok, self()}),
    line(Parent, Config#{system => System}, erx_ssh_line_core:new()).

line(Parent, #{system := System, exports := Exports} = Config, Core) ->
    Peer = erx_ssh_line_core:peer(Core),
    receive
        {erx_origin, System, {'$gen_call', From, {export, Ssh}}} when is_integer(Ssh), Ssh > 0, Ssh =/= System ->
            {Reply, Next} = export(Ssh, Exports, Core),
            gen:reply(From, Reply),
            line(Parent, Config, Next);
        {erx_origin, Peer, {'$gen_call', {Caller, [alias | Alias]} = From, Request}} when is_pid(Caller), is_reference(Alias) ->
            case Exports:owner(Caller) =:= Peer andalso Exports:owner(Alias) =:= Peer of
                true -> line(Parent, Config, call(From, Request, Config, Core));
                false -> line(Parent, Config, Core)
            end;
        {?MODULE, ended, Tty, Ending} when is_pid(Tty) ->
            %% A tty's report, through the Notify call/4 gave it, for its channel.
            case erx_ssh_line_core:report(Tty, Core) of
                {send, Channel} -> Channel ! Ending;
                drop -> ok
            end,
            line(Parent, Config, Core);
        {'DOWN', _Ref, process, Tty, _Reason} ->
            line(Parent, Config, erx_ssh_line_core:ended(Tty, Core));
        {'EXIT', Parent, Reason} ->
            exit(Reason);
        _Other ->
            line(Parent, Config, Core)
    end.

%% The system domain's request to serve Ssh: the line exports itself to Ssh
%% with send alone and serves Ssh from then on. A refused export leaves the
%% peer as it was.
export(Ssh, Exports, Core) ->
    case Exports:export(self(), [send], Ssh) of
        ok -> {ok, erx_ssh_line_core:exported(Ssh, Core)};
        {error, Reason} -> {{error, Reason}, Core}
    end.

%% A request from the peer, answered as the core decides. A tty that cannot be
%% started, a session out of room, is answered `limited`, as a full line is. The
%% tty's console reports how its shell ended by calling Notify, which tells the line.
call(From, Request, #{exports := Exports, open := Open}, Core) ->
    Line = self(),
    Notify = fun(Ending) -> Line ! {?MODULE, ended, self(), Ending} end,
    case erx_ssh_line_core:request(Request, fun Exports:owner/1, Core) of
        {open_tty, Channel, Spec} ->
            case Open(Channel, Spec, Notify) of
                {ok, Tty} ->
                    _ = erlang:monitor(process, Tty),
                    gen:reply(From, ok),
                    erx_ssh_line_core:opened(Tty, Channel, Core);
                {error, _Reason} ->
                    gen:reply(From, {error, limited}),
                    Core
            end;
        {error, _Reason} = Error ->
            gen:reply(From, Error),
            Core
    end.
