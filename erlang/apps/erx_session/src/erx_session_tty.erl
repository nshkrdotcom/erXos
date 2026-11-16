%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_tty).
-moduledoc """
A session's ttys (docs/design-live.md, "The tty", "Where a tty lives", "Between
domains"): each raw for as long as it lives, with the command shell on it, and
the six messages that carry its bytes to and from its master. Each master has a
tty of its own, and no tty is registered:

* the session's console tty (start_link/0), whose master is the console facet
  that erx:cap(console) names; erx_session_sup starts it at boot, and it is the
  domain's line (erx_console:terminal/0), whose console holds the domain's
  `user`, so `user` lives as long as the line whichever other ttys end;
* a tty for each master in the session's own domain that asks for one with
  open/1, as a terminal on a display does (docs/design-display.md, "The
  terminal"), much as a program's posix_openpt makes a pseudo-terminal.

A tty is two processes. The groups that run its shells are driven by a console of
the session role (erx_console:start_link/1), unregistered, exactly as the system
domain's console drives its own: the command shell on the first group, started
again whenever it ends (as on the UART), and run_shell and write with
erx_console's meaning on the tty's terminal, erx_console:terminal(Console). That
console's line driver is the tty itself, which turns the console's writes into
numbered outputs to the master and the master's messages into the console's
input, size and end of input, by the pure core erx_tty_link. The tty is raw,
since no program opens it: no line discipline runs, and the bytes the session's
writers hand it reach the master unchanged, as a program's output reaches a tty
on UNIX. The console, which shows them, applies its own receiver checks.

A message from the master arrives as `{erx_origin, D, Msg}` when the master is
in another domain, and the tty takes the envelope off only when `D` is the
master's domain. A master in the session's own domain sends plain messages, and
its end is the tty's hangup, as a pseudo-terminal master's close is
(docs/design-programs.md, "The terminal"): the tty ends its shells and then
itself, and the session's other ttys run on. With no master, erx_tty_link sends
nothing: the tty holds 4 KiB and its writers wait.
""".

-export([start_link/0, start_link/1, open/1]).
%% The tty's own process.
-export([start_tty/2, tty_init/3]).

-define(RESEND_MS, 1000).

-doc """
Starts the session's console tty, with the master erx:cap(console) names, as the
domain's line, whose console holds the domain's `user`. Returns its console.
""".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_console(fun() -> erx:cap(console) end, #{domain_line => true}).

-doc """
Starts a tty whose master is Master, a process of this domain, linked to the
caller. Returns its console; the master learns the tty from its `{tty_open, Tty}`.
""".
-spec start_link(pid()) -> {ok, pid()} | {error, term()}.
start_link(Master) when is_pid(Master), node(Master) =:= node() ->
    start_console(fun() -> Master end, #{user => none}).

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
                             modules => [?MODULE, erx_console]}).

%% A console of the session role whose line driver is the tty, and whose first shell is
%% the command shell on that console's own terminal.
start_console(MasterFun, Options) ->
    erx_console:start_link(Options#{role => session,
                                    driver => fun(Console) -> start_tty(Console, MasterFun) end,
                                    first_shell => fun(Terminal) ->
                                                           {erx_shell, server, [{erx_shell_runner, Terminal}]}
                                                   end}).

%%% The tty: erx_console's line driver, around erx_tty_link

-doc false.
-spec start_tty(pid(), fun(() -> pid() | undefined)) -> {ok, pid(), true}.
start_tty(Console, MasterFun) ->
    {ok, Pid} = proc_lib:start_link(?MODULE, tty_init, [self(), Console, MasterFun]),
    %% A person's terminal is at the master's end.
    {ok, Pid, true}.

-doc false.
-spec tty_init(pid(), pid(), fun(() -> pid() | undefined)) -> no_return().
tty_init(Parent, Console, MasterFun) ->
    %% The tty is its console's line and ends with it, whatever the reason.
    _ = erlang:monitor(process, Console),
    proc_lib:init_ack(Parent, {ok, self()}),
    Master = master(MasterFun()),
    ok = announce(Master),
    loop(#{console => Console, master => Master, link => erx_tty_link:new(presence(Master))}).

%% The master, if any, and where its messages come from: plain from a master in this
%% domain, which is watched, so that its end hangs the tty up; enveloped from one in
%% another domain, which says tty_hangup itself.
master(undefined) -> none;
master(Pid) when node(Pid) =:= node() -> {local, Pid, erlang:monitor(process, Pid)};
master(Pid) -> {domain, Pid, erx:owner(Pid)}.

presence(none) -> none;
presence(_Master) -> present.

%% The tty names itself to its master, the console facet that tells the console whose tty
%% it is (docs/design-live.md, "Between domains"), and again with each resend, which
%% erx_tty_link asks for: the facet drops a message past its limit in flight, and a
%% console that never had the tty's name answers none of its outputs. The master takes
%% the first and ignores the same again.
announce(none) -> ok;
announce({_Origin, Pid, _}) -> Pid ! {tty_open, self()}, ok.

%% How the master's messages arrive: plain, enveloped from domain D, or not at all.
origin(none) -> none;
origin({local, _Pid, _Ref}) -> local;
origin({domain, _Pid, D}) -> {domain, D}.

loop(Tty = #{link := Link, console := Console, master := Master}) ->
    Origin = origin(Master),
    receive
        {erx_console_output, From, Bytes} ->
            loop(effects(erx_tty_link:write(From, iolist_to_binary(Bytes), Link), Tty));
        {'DOWN', _Ref, process, Console, Reason} ->
            exit(Reason);
        {'DOWN', Ref, process, Pid, _Reason} when Master =:= {local, Pid, Ref} ->
            loop(effects(erx_tty_link:master(tty_hangup, Link), Tty));
        {erx_tty_resend, N} ->
            loop(effects(erx_tty_link:timeout(N, Link), Tty));
        {erx_origin, D, Message} when Origin =:= {domain, D} ->
            loop(effects(erx_tty_link:master(Message, Link), Tty));
        {erx_origin, _D, _Message} ->
            loop(Tty);
        Message when Origin =:= local ->
            loop(effects(erx_tty_link:master(Message, Link), Tty));
        _Other ->
            loop(Tty)
    end.

%% Every step ends here, so what it left held goes to the master once, after
%% its own actions (erx_tty_link:send/1).
effects({Actions, Link0}, Tty) ->
    {Sent, Link} = erx_tty_link:send(Link0),
    lists:foreach(fun(Action) -> effect(Action, Tty) end, Actions ++ Sent),
    Tty#{link := Link}.

effect({output, N, Bytes}, #{master := {_Origin, Pid, _}}) -> Pid ! {tty_output, N, Bytes};
effect(open, #{master := Master}) -> announce(Master);
effect({resend_after, N}, _Tty) -> erlang:send_after(?RESEND_MS, self(), {erx_tty_resend, N});
effect({done, From}, #{console := Console}) -> Console ! {erx_console_written, From};
effect({input, Bytes}, #{console := Console}) -> Console ! {erx_console_input, Bytes};
effect({size, Rows, Columns}, #{console := Console}) -> Console ! {erx_console_size, Columns, Rows};
effect(hangup, #{console := Console}) -> Console ! erx_console_eof.
