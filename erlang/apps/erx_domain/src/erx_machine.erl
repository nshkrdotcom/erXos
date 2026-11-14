%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_machine).
-moduledoc """
The coordinator of the machine's end (docs/design-system.md, "Shutting
down" and "A session's request"), a process of the domain service. Every
request for an end reaches it through its one entry, request/2, with the
end, `reset` or `off`, and the principal that asked: the name the `machine`
grant was minted with for a session's request (erx_machine_fs), or
`system` for the system domain's own callers, the system shell's `reboot`
and `halt` among them.

The coordinator takes requests one at a time. The first one it accepts is
the machine's end: it writes the one log line, at `critical`, `rebooted
by P` for `reset` or `powered off by P` for `off`, where P is the
principal's name and `root` for the system principal, answers `ok`, and
asks init to stop. Every later request, whatever its source, is answered
`busy` and logs nothing. The request it accepted stands in for the
ending record until erx_dom_end_begin keeps one (TODO.md, the ordered
end).

The decision is pure, decide/3; the log line, the answer and init's stop
are the effects, and a test hands start_link/1 a stand-in for the stop.
""".
-behaviour(gen_server).

-export([start_link/0, start_link/1, request/2]).
-export([decide/3]).
-export([init/1, handle_call/3, handle_cast/2]).
-export_type(['end'/0, principal/0]).

-doc "An end a request asks for: a reset or a power-off.".
-type 'end'() :: reset | off.
-doc "Who asked: the system principal, or the name of a grant's principal.".
-type principal() :: system | binary().
-doc "The request the coordinator accepted, or none yet.".
-type ending() :: none | {'end'(), binary()}.

-doc "Starts the coordinator, registered as erx_machine, linked to the caller.".
-spec start_link() -> {ok, pid()}.
start_link() ->
    start_link(#{}).

-doc """
As start_link/0, with a test's stand-in for init's stop under `stop`, a
fun of the accepted end.
""".
-spec start_link(#{stop => fun(('end'()) -> ok)}) -> {ok, pid()}.
start_link(Args) when is_map(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

-doc """
Asks for the machine's end End on behalf of Principal: `ok` once the
request is accepted and the end has begun, which cannot be undone, or
`busy` when an earlier request was accepted. A caller whose coordinator
has ended exits, as any call to an ended process does.
""".
-spec request('end'(), principal()) -> ok | busy.
request(End, Principal) when (End =:= reset orelse End =:= off),
                             (Principal =:= system orelse is_binary(Principal)) ->
    gen_server:call(?MODULE, {request, End, Principal}, infinity).

-doc """
The coordinator's decision on a request for End by Principal, given the
request it accepted before, Ending: `busy` once one was accepted, and
otherwise the request to keep and the log line it writes.
""".
-spec decide(ending(), 'end'(), principal()) -> busy | {accept, {'end'(), binary()}, iodata()}.
decide({_End, _Name}, _Requested, _Principal) ->
    busy;
decide(none, End, Principal) ->
    Name = name(Principal),
    {accept, {End, Name}, [verb(End), <<" by ">>, Name]}.

name(system) -> <<"root">>;
name(Name) when is_binary(Name) -> Name.

verb(reset) -> <<"rebooted">>;
verb(off) -> <<"powered off">>.

-doc false.
init(Args) ->
    {ok, #{ending => none, stop => maps:get(stop, Args, fun stop/1)}}.

%% The answer goes before init's stop, which returns at once while init shuts the node
%% down, so the requester hears ok even as the machine starts to end. The log line is
%% written by the system domain whoever asked; a principal name came from the domain
%% service's own records, so no text a session wrote reaches the log.
-doc false.
handle_call({request, End, Principal}, From, #{ending := Ending, stop := Stop} = State) ->
    case decide(Ending, End, Principal) of
        busy ->
            {reply, busy, State};
        {accept, Accepted, Line} ->
            logger:critical("~ts", [Line]),
            gen_server:reply(From, ok),
            ok = Stop(End),
            {noreply, State#{ending := Accepted}}
    end.

-doc false.
handle_cast(_Message, State) ->
    {noreply, State}.

stop(reset) -> init:reboot();
stop(off) -> init:stop().
