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

The line is an erx_session_line, which owns who reaches it: the web domain
reaches it only through the facet the line mints when the system domain asks
for it (erx_domain:line/4), as the host opens its `web` facet, and the facet
forwards each of its grantee's calls with the grantee's caller and the facet
itself. The session names the line to the domain service in its ready report
(erx_web_line_app). This module serves the forwarded calls (request/4) and
the session's own messages to the line (info/2).

* `{open, Target}` starts a view and answers `{ok, View}`, the view's pid,
  which the facet's reply hands out to the grantee with send alone
  (docs/design-domains.md, "Exports"); `{error, busy}` past ?VIEWS views,
  and `{error, unsupported}` for a target this line does not serve. The
  line serves the record view of `{path, Names}`: Names are /proc entry
  names, read into the inspector's path one at a time as /proc reads them
  (erx_procfs_core:child/2), and names that name nothing are answered
  `{error, scope}`, as a path outside the scope is, so the open tells no
  more than the view would (docs/design-web.md, "URLs"). Which paths the
  view reaches is the inspector's to decide, at the session's facet's scope.
  Any other request is `{error, badarg}`.
* A view acts for the grantee of the facet it was opened through: it
  answers the grantee's caller of the open alone, takes `next` and `stop` in
  the grantee's envelope alone, and ends when that caller ends or that facet
  does, so a replaced facet's views never serve the new grantee. It runs
  with its heap limited to ?ERX_WEB_LINE_VIEW_HEAP_MAX words, killed at the
  limit with the binaries it references counted, and with its message queue
  on its heap, so what waits unread counts toward the same limit.

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
-export([init/1, request/4, info/2, view_init/1]).

-export_type([config/0]).

-include("generated/erx_abi.hrl").

%% The line's keys, as erx_session_line:config() has them, and inspect, which answers
%% a path's record as the session may see it, erx_inspector:inspect/1 or a host test's
%% stand-in.
-type config() :: #{inspect => fun((list()) -> erx_inspector:answer()), atom() => term()}.

%% The views one line holds at once (docs/design-web.md, "Views on the line").
-define(VIEWS, 64).
%% How long a view that found nothing new waits before it queries again.
-define(REQUERY_MS, 2000).
%% How a view is spawned: linked to the line, its heap limited by its interface's
%% declared bound, killed at it with the binaries it references counted, and its queue
%% on that heap (docs/design-system.md, "A session's lines", "Views and ttys").
-define(VIEW_SPAWN, [link, {message_queue_data, on_heap},
                     {max_heap_size, #{size => ?ERX_WEB_LINE_VIEW_HEAP_MAX, kill => true,
                                       include_shared_binaries => true}}]).

-doc "Starts the line for Config, linked to the caller.".
-spec start_link(config()) -> {ok, pid()}.
start_link(Config) when is_map(Config) ->
    erx_session_line:start_link(?MODULE, maps:merge(#{name => web_line, inspect => fun erx_inspector:inspect/1},
                                                    Config)).

%% The line's state: Inspect, which every view queries, and the open views, each by
%% its pid. Whom the line serves changes with its facet, never what its views read:
%% they read through the session's inspect facet whoever the grantee is.
-doc false.
init(#{inspect := Inspect}) ->
    #{inspect => Inspect, views => #{}}.

%% A request the line's facet forwarded: open/3 decides it.
-doc false.
request(From, Request, Forward, #{views := Views} = State) ->
    {Reply, Next} = open(Request, Forward, State),
    gen:reply(From, Reply),
    State#{views := maps:merge(Views, Next)}.

%% The session's own message to the line that it acts on: the end of a view it linked.
-doc false.
info({'EXIT', View, _Reason}, #{views := Views} = State) ->
    State#{views := maps:remove(View, Views)};
info(_Message, State) ->
    State.

%% A request: what it is answered and the view it opened, if any. A view answers the
%% grantee's caller, takes its requests in the grantee's envelope, and ends with the
%% caller and with the facet.
open({open, _Target}, _Forward, #{views := Views}) when map_size(Views) >= ?VIEWS ->
    {{error, busy}, #{}};
open({open, {path, Names}}, #{grantee := Grantee, caller := Caller, facet := Facet}, #{inspect := Inspect}) ->
    case inspector_path([], Names) of
        {ok, Path} ->
            View = proc_lib:spawn_opt(?MODULE, view_init, [#{conn => Caller, peer => Grantee, facet => Facet,
                                                              inspect => Inspect, path => Path, last => none}],
                                      ?VIEW_SPAWN),
            {{ok, View}, #{View => Path}};
        error ->
            {{error, scope}, #{}}
    end;
open({open, _Target}, _Forward, _State) ->
    {{error, unsupported}, #{}};
open(_Request, _Forward, _State) ->
    {{error, badarg}, #{}}.

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
view_init(#{conn := Conn, facet := Facet} = View) ->
    _ = erlang:monitor(process, Conn),
    _ = erlang:monitor(process, Facet),
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

%% What a message asks of the view: one more update, its end, or nothing. Only the
%% grantee asks, and the end of the caller or of the facet ends the view.
asked({erx_origin, Peer, next}, #{peer := Peer}) -> next;
asked({erx_origin, Peer, stop}, #{peer := Peer}) -> stop;
asked({'DOWN', _Ref, process, Conn, _Reason}, #{conn := Conn}) -> stop;
asked({'DOWN', _Ref, process, Facet, _Reason}, #{facet := Facet}) -> stop;
asked(_Message, #{}) -> other.

%% Queries until there is something new to send, sends it and returns the view
%% with it as the last answer; ends the view when the query cannot be answered.
%% While it waits to query again it takes only its end, its facet's among them.
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
