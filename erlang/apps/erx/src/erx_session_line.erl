%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_line).
-moduledoc """
A session's line to a front-end domain (docs/design-web.md, "Views on the
line"; docs/design-ssh.md, "Sessions, ttys and shells"): the process a
front-end domain reaches the session through, erx_web_line's for the web
domain and erx_ssh_line's for the SSH domain. This module owns who reaches
the line from another domain; the callback module owns what the line does
with an admitted request and with its own domain's messages.

The line serves one peer, the domain it was exported to, and none until then
unless its config names one. The session names the line to the domain
service in its ready report, and the system domain, as it introduces the two
domains (erx_domain:line/3), calls the line with `{export, Peer}`: the line
exports itself to domain Peer with send alone and serves Peer from then on,
in place of any peer before it. A refused export leaves the peer as it was.
The line takes that call only in the system domain's envelope and only for
a Peer that is another domain, so no other domain, and no process of the
session, chooses who reaches it.

From its peer the line takes a request only as a call in the peer's envelope
whose caller and alias are names of the peer's (erx:call_from/3, as
erx_facet checks a grantee's calls), so a reply never goes to a third
domain, and hands it to the callback's request/4. Anything else in an
envelope, from the peer or any other domain, is dropped here: no message
of another domain reaches the
callback but an admitted request. Every message not in an envelope, which
is a message of the session's own domain, goes to the callback's info/3,
the 'EXIT' of a linked process among them, since the line traps exits; the
parent's 'EXIT' ends the line.
""".

-export([start_link/2]).
-export([line_init/3]).

-export_type([config/0]).

-doc """
The callback's state for the line's Config, before the line serves anyone.
Config holds the line's own keys and the callback's.
""".
-callback init(Config :: config()) -> State :: term().

-doc """
A request the peer Peer made, admitted: its caller and alias are Peer's. The
callback answers From and returns its next state.
""".
-callback request(From :: gen_server:from(), Request :: term(), Peer :: pos_integer(), State :: term()) ->
    NextState :: term().

-doc """
A message of the session's own domain, Peer the domain the line serves or
none; the callback takes its own shapes and returns its next state.
""".
-callback info(Message :: term(), Peer :: pos_integer() | none, State :: term()) -> NextState :: term().

%% peer is the domain the line serves, none until the system domain has the line
%% exported, and system the system domain's id. exports answers export/3 and owner/1,
%% erx_dist or a host test's stand-in. The callback's own keys ride beside them.
-type config() :: #{peer => pos_integer() | none, system => pos_integer(), exports => module(),
                    atom() => term()}.

-doc "Starts the line of callback Module for Config, linked to the caller.".
-spec start_link(module(), config()) -> {ok, pid()}.
start_link(Module, Config) when is_atom(Module), is_map(Config) ->
    Defaults = #{peer => none, exports => erx_dist},
    proc_lib:start_link(?MODULE, line_init, [self(), Module, maps:merge(Defaults, Config)]).

-doc false.
line_init(Parent, Module, Config) ->
    process_flag(trap_exit, true),
    %% ps names the line after its callback module, as a gen_server's process is named.
    put('$initial_call', {Module, init, 1}),
    System = case Config of
                 #{system := Id} -> Id;
                 #{} -> erx_kernel_records:system_domain()
             end,
    Full = Config#{system => System},
    State = Module:init(Full),
    proc_lib:init_ack(Parent, {ok, self()}),
    line(Parent, Module, maps:with([peer, system, exports], Full), State).

line(Parent, Module, #{peer := Peer, system := System, exports := Exports} = Line, State) ->
    receive
        {erx_origin, System, {'$gen_call', From, {export, Domain}}}
          when is_integer(Domain), Domain > 0, Domain =/= System ->
            {Reply, Next} = export(Domain, Line),
            gen:reply(From, Reply),
            line(Parent, Module, Next, State);
        {erx_origin, Peer, {'$gen_call', From, Request}} ->
            case erx:call_from(Peer, From, fun Exports:owner/1) of
                true -> line(Parent, Module, Line, Module:request(From, Request, Peer, State));
                false -> line(Parent, Module, Line, State)
            end;
        {erx_origin, _Domain, _Message} ->
            line(Parent, Module, Line, State);
        {'EXIT', Parent, Reason} ->
            exit(Reason);
        Message ->
            line(Parent, Module, Line, Module:info(Message, Peer, State))
    end.

%% The system domain's request to serve Domain: the line exports itself to Domain
%% with send alone, as encoding its name in a frame for Domain would.
export(Domain, #{exports := Exports} = Line) ->
    case Exports:export(self(), [send], Domain) of
        ok -> {ok, Line#{peer := Domain}};
        {error, Reason} -> {{error, Reason}, Line}
    end.
