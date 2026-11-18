%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_web_line).

-moduledoc """
The session's line to the web domain (docs/design-web.md, "Views on the
line"): the process through which the web domain opens views of this
session, each a process of this domain that queries the inspector through
the session's inspect facet (erx_inspector:inspect/1), so a browser sees
what the session's user may and the line holds no scope of its own
(docs/design-live.md, "How a query travels"; docs/design-web.md,
"Overview").

The line is an erx_session_line, which owns who reaches it: it serves one
peer, the web domain the system domain exported it to when the host opened
its `web` facet (erx_domain:line/3), and none until then, and it takes from
that peer only calls in the peer's envelope whose caller and alias are names
of the peer's, so a reply never goes to a third domain. The session names
the line to the domain service in its ready report (erx_web_line_app). This
module serves the calls the line admits (request/4) and the session's own
messages to the line (info/3). A view takes `next` and `stop` only in the
peer's envelope, as the peer was when the view opened; anything else from
another domain is dropped. A process of this session may call the line and
its views without an envelope, since it acts with the session's authority
anyway.

* `{open, Target}` starts a view and answers `{ok, View}`, the view's pid,
  which the reply hands out to the peer with send alone
  (docs/design-domains.md, "Exports"); `{error, busy}` past ?VIEWS views,
  and `{error, unsupported}` for a target this line does not serve. The
  line serves the record view of `{path, Names}`: Names are /proc entry
  names, read into the inspector's path one at a time as /proc reads them
  (erx_procfs_core:child/2), and names that name nothing are answered
  `{error, scope}`, as a path outside the scope is, so the open tells no
  more than the view would (docs/design-web.md, "URLs"). Which paths the
  view reaches is the inspector's to decide, at the session's facet's scope.
* A view belongs to the process that opened it, the caller of the open:
  it answers that process alone and ends when that process ends.

A view is one process with one query at a time. The open asks its first
update and each `next` one more: the view queries the inspector, projects
the record with erx_web_value and sends `{web_view, View, {record, Wire}}`
when the projection differs from the last one it sent, the first always;
otherwise it queries again after ?REQUERY_MS. A record that does not fit
one update, and a query the inspector refuses, end the view with
`{web_view_ended, View, Reason}`, Reason `too_large`, `scope`,
`unsupported` or `failed`. `stop` ends it. A view's crash ends that view
alone, which the web domain sees through its monitor.

The line holds one entry per open view; a view holds its last projection,
at most one update of 64 KiB (W8).
""".

-behaviour(erx_session_line).

-export([start_link/1]).
-export([init/1, request/4, info/3, view_init/1]).

-export_type([config/0]).

%% The line's keys, peer, system and exports, as erx_session_line:config() has them,
%% and inspect, which answers a path's record as the session may see it,
%% erx_inspector:inspect/1 or a host test's stand-in.
-type config() :: #{inspect => fun((list()) -> erx_inspector:answer()), atom() => term()}.

%% The views one line holds at once (docs/design-web.md, "Views on the line").
-define(VIEWS, 64).
%% How long a view that found nothing new waits before it queries again.
-define(REQUERY_MS, 2000).

-doc "Starts the line for Config, linked to the caller.".
-spec start_link(config()) -> {ok, pid()}.
start_link(Config) when is_map(Config) ->
    erx_session_line:start_link(?MODULE, maps:merge(#{inspect => fun erx_inspector:inspect/1}, Config)).

%% The line's state: Inspect, which every view queries, and the open views, each by
%% its pid. An export changes whom the line serves, never what its views read: they
%% read through the session's inspect facet before it and after it alike.
-doc false.
init(#{inspect := Inspect}) ->
    #{inspect => Inspect, views => #{}}.

%% A call from the peer Peer, which the line admitted. It takes the same path,
%% serve/4, as a call from a process of the session's own (info/3).
-doc false.
request(From, Request, Peer, State) ->
    serve(From, Request, Peer, State).

%% The session's own messages to the line: a call from one of its processes, and the
%% end of a view the line linked.
-doc false.
info({'$gen_call', {Caller, _Tag} = From, Request}, Peer, State) when is_pid(Caller), node(Caller) =:= node() ->
    serve(From, Request, Peer, State);
info({'EXIT', View, _Reason}, _Peer, #{views := Views} = State) ->
    State#{views := maps:remove(View, Views)};
info(_Message, _Peer, State) ->
    State.

%% A call the line serves, from its peer or from the session: open/4 decides it.
serve({Caller, _Tag} = From, Request, Peer, State) ->
    {Reply, Next} = open(Request, Caller, Peer, State),
    gen:reply(From, Reply),
    State#{views := Next}.

%% A request: what it is answered and the views the line then holds. A view answers
%% Caller and takes its requests in Peer's envelope.
open({open, _Target}, _Caller, _Peer, #{views := Views}) when map_size(Views) >= ?VIEWS ->
    {{error, busy}, Views};
open({open, {path, Names}}, Caller, Peer, #{inspect := Inspect, views := Views}) ->
    case inspector_path([], Names) of
        {ok, Path} ->
            View = proc_lib:spawn_link(?MODULE, view_init, [#{conn => Caller, peer => Peer, inspect => Inspect,
                                                               path => Path, last => none}]),
            {{ok, View}, Views#{View => Path}};
        error ->
            {{error, scope}, Views}
    end;
open({open, _Target}, _Caller, _Peer, #{views := Views}) ->
    {{error, unsupported}, Views};
open(_Request, _Caller, _Peer, #{views := Views}) ->
    {{error, badarg}, Views}.

%% Reads Names, untrusted /proc entry names, one at a time into the inspector's
%% path below Path; `error` at the first name that names nothing there, or when
%% Names is not a proper list of binaries. erx_procfs_core bounds each name before
%% it reads it and makes no atom, and the schema's bound on a path's segments ends
%% the walk.
inspector_path(Path, []) ->
    {ok, Path};
inspector_path(Path, [Name | Names]) ->
    case erx_procfs_core:child(Path, Name) of
        {ok, Child} -> inspector_path(Child, Names);
        error -> error
    end;
inspector_path(_Path, _Names) ->
    error.

%%% A record view.

-doc false.
view_init(#{conn := Conn} = View) ->
    _ = erlang:monitor(process, Conn),
    %% The open is the first request.
    view(answer(View)).

view(View) ->
    receive
        Message ->
            case asked(Message, View) of
                next -> view(answer(View));
                stop -> exit(normal);
                other -> view(View)
            end
    end.

%% What a message asks of the view: one more update, its end, or nothing.
asked({erx_origin, Peer, next}, #{peer := Peer}) -> next;
asked(next, #{}) -> next;
asked({erx_origin, Peer, stop}, #{peer := Peer}) -> stop;
asked(stop, #{}) -> stop;
asked({'DOWN', _Ref, process, Conn, _Reason}, #{conn := Conn}) -> stop;
asked(_Message, #{}) -> other.

%% Queries until there is something new to send, sends it and returns the view
%% with it as the last answer; ends the view when the query cannot be answered.
%% While it waits to query again it takes only its end.
answer(#{conn := Conn, path := Path, inspect := Inspect, last := Last} = View) ->
    case body(Inspect(Path)) of
        {ok, Last} ->
            wait(erlang:start_timer(?REQUERY_MS, self(), requery), View);
        {ok, Body} ->
            Conn ! {web_view, self(), Body},
            View#{last := Body};
        {error, Reason} ->
            Conn ! {web_view_ended, self(), Reason},
            exit(normal)
    end.

wait(Timer, View) ->
    receive
        {timeout, Timer, requery} ->
            answer(View);
        Message ->
            case asked(Message, View) of
                stop -> exit(normal);
                _ -> wait(Timer, View)
            end
    end.

%% The update body of an inspector's answer, or why the view ends.
body({ok, Record}) ->
    case erx_web_value:project(Record) of
        {ok, Wire} -> {ok, {record, Wire}};
        {error, too_large} -> {error, too_large}
    end;
body({error, Reason}) when Reason =:= scope; Reason =:= unsupported ->
    {error, Reason};
body({error, _Reason}) ->
    {error, failed}.
