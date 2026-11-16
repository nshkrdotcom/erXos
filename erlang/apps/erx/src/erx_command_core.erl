%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_command_core).
-moduledoc """
The decisions of the session's command server (docs/design-programs.md,
"The command server"): one pure state machine, step/2, over the
session's process table, from an event to the next table and the
actions erx_command_srv performs, in order.

The table holds the next process id, from 2, and a row for each process
the table names, while the session process that speaks for it lives: a
program's handler, or the caller of `{reserve, Starter}`, such as a
command's stream relay. A row's process id, parent and job are fixed
when it is made. A process id is given at most once in the table's
life: the next id only grows, and once 2^31 - 1 (`ERX_PROG_PID_MAX`) has
been given every reservation is `eagain`. So an id that ever named a
program, and with it that program's pipe ends at the pipe server, never
names another, however late the pipe server reads the old program's
gone.

A row's parent is the program that started it, or 1, the command
server, for a program a session process started; its job is its
parent's job, or the job tag of the session process that started it;
its group is the group of the rows its job already has, or its own id
when it has none, so a job's rows share one group while any of them
lives.

Events:

* `{call, From, Caller, Call}`, a call the server answers with
  `{reply, From, Answer}`: `{handler, Starter, Key}`,
  `{reserve, Starter}`, `programs`, `{kill, Scope, Target, Signal,
  Sender}` and `{probe, Scope, Target}`, each as the design's table has
  it; `Key` is a reference the caller made, which the new handler takes
  its start with, so no other process can start it;
* `{spawned, From, Init, Handler}`, the handler the server spawned for
  the action `{spawn_handler, From, Init}`, which makes its row and
  answers the call;
* `{down, Speaker}`, the end of a row's handler, which drops its rows;
* `{await, Tag, Awaiter}`, answered `{programs_ended, Tag}` once no row
  carries `Tag`;
* `{job, Tag, Action}`, sent on to the handler of each row of `Tag`.

Actions: `{spawn_handler, From, Init}`, `{monitor, Speaker}`,
`{reply, From, Answer}` and `{send, To, Message}`, `Message` a
`to_speaker()` or `{programs_ended, Tag}`.
""".

-include("generated/erx_abi.hrl").

-export([new/0, new/1, step/2, rows/1]).
-export_type([table/0, event/0, action/0, row/0, init/0, starter/0, scope/0,
              to_speaker/0]).

-type id() :: ?ERX_PROG_PID_MIN..?ERX_PROG_PID_MAX.
%% A job's tag, which the table only compares.
-type tag() :: term().
-type starter() :: {program, id()} | {process, tag()}.
-type scope() :: session | {job, tag()}.
-type job_action() :: pause | resume | {signal, atom()}.

%% A row's fixed values, before a speaker is given it.
-type place() :: #{pid := id(), ppid := 1 | id(), job := tag(),
                   pgid := id()}.
-type row() :: #{pid := id(), ppid := 1 | id(), job := tag(), pgid := id(),
                 handler := pid()}.
%% What a new handler starts from: its row's fixed values, the process
%% whose start it waits for and the key that start carries.
-type init() :: #{pid := id(), ppid := 1 | id(), job := tag(), pgid := id(),
                  starter := pid(), key := reference()}.
%% What the server sends a row's speaker: a job's action, a signal and its
%% sender's process id.
-type to_speaker() :: {erx_job, job_action()}
                    | {erx_signal, Signal :: atom(), Sender :: id()}.

-type call() :: {handler, starter(), Key :: reference()}
              | {reserve, starter()}
              | programs
              | {kill, scope(), id(), Signal :: atom(), Sender :: id()}
              | {probe, scope(), id()}.
-type event() :: {call, From :: term(), Caller :: pid(), call()}
               | {spawned, From :: term(), init(), Handler :: pid()}
               | {down, Speaker :: pid()}
               | {await, tag(), Awaiter :: pid()}
               | {job, tag(), job_action()}.
-type action() :: {spawn_handler, From :: term(), init()}
                | {monitor, pid()}
                | {reply, From :: term(), term()}
                | {send, pid(), to_speaker() | {programs_ended, tag()}}.

-record(table, {next = 2 :: pos_integer(),
                rows = #{} :: #{id() => row()},
                awaits = #{} :: #{tag() => [pid()]}}).
-opaque table() :: #table{}.

-doc "An empty table whose first process id is the first a program may have, `ERX_PROG_PID_MIN`.".
-spec new() -> table().
new() ->
    new(?ERX_PROG_PID_MIN).

-doc """
An empty table whose next process id is `Next`, the tests' seam for the
ids near `ERX_PROG_PID_MAX`.
""".
-spec new(id()) -> table().
new(Next) when is_integer(Next), Next >= ?ERX_PROG_PID_MIN, Next =< ?ERX_PROG_PID_MAX ->
    #table{next = Next}.

-doc "The table's rows, in process id order.".
-spec rows(table()) -> [row()].
rows(#table{rows = Rows}) ->
    [Row || _ := Row <- maps:iterator(Rows, ordered)].

-doc "One event's next table and the actions to perform, in order.".
-spec step(table(), event()) -> {table(), [action()]}.
step(T, {call, From, Caller, Call}) ->
    call(T, From, Caller, Call);
step(T, {spawned, From, #{pid := Id} = Init, Handler}) ->
    {add(T, Init, Handler), [{monitor, Handler}, {reply, From, {ok, Handler, Id}}]};
step(#table{rows = Rows} = T, {down, Speaker}) ->
    Gone = [Id || Id := #{handler := H} <- Rows, H =:= Speaker],
    ended(lists:foldl(fun drop/2, T, Gone));
step(#table{awaits = Awaits} = T, {await, Tag, Awaiter}) ->
    case carried(T, Tag) of
        true ->
            {T#table{awaits = Awaits#{Tag => [Awaiter | maps:get(Tag, Awaits, [])]}}, []};
        false ->
            {T, [{send, Awaiter, {programs_ended, Tag}}]}
    end;
step(T, {job, Tag, Action}) ->
    {T, [{send, H, {erx_job, Action}} || #{job := J, handler := H} <- rows(T), J =:= Tag]}.

call(T, From, Caller, {handler, Starter, Key}) when is_reference(Key) ->
    case reserve(T, Starter) of
        {ok, Place, T1} ->
            {T1, [{spawn_handler, From, Place#{starter => Caller, key => Key}}]};
        {error, _} = Refused ->
            {T, [{reply, From, Refused}]}
    end;
call(T, From, Caller, {reserve, Starter}) ->
    case reserve(T, Starter) of
        {ok, #{pid := Id, pgid := Pgid} = Place, T1} ->
            {add(T1, Place, Caller), [{monitor, Caller}, {reply, From, {ok, Id, Pgid}}]};
        {error, _} = Refused ->
            {T, [{reply, From, Refused}]}
    end;
call(T, From, _Caller, programs) ->
    {T, [{reply, From, rows(T)}]};
call(T, From, _Caller, {kill, Scope, Target, Signal, Sender}) ->
    case named(T, Scope, Target) of
        [] ->
            {T, [{reply, From, {error, esrch}}]};
        Named ->
            Sends = [{send, H, {erx_signal, Signal, Sender}} || #{handler := H} <- Named],
            {T, Sends ++ [{reply, From, ok}]}
    end;
call(T, From, _Caller, {probe, Scope, Target}) ->
    case named(T, Scope, Target) of
        [] -> {T, [{reply, From, {error, esrch}}]};
        _ -> {T, [{reply, From, ok}]}
    end;
call(T, From, _Caller, _Unknown) ->
    {T, [{reply, From, {error, einval}}]}.

%% The next process id with its row's place, and the table that has given
%% it; esrch for a program starter the table does not name, einval for a
%% starter of another form, eagain once every id has been given.
reserve(#table{next = Next}, _Starter) when Next > ?ERX_PROG_PID_MAX ->
    {error, eagain};
reserve(#table{next = Next} = T, Starter) ->
    case placement(T, Starter) of
        {ok, Parent, Job} ->
            Place = #{pid => Next, ppid => Parent, job => Job, pgid => group(T, Job, Next)},
            {ok, Place, T#table{next = Next + 1}};
        {error, _} = Refused ->
            Refused
    end.

%% A row's parent and job, from the starter that asks for it.
placement(_T, {process, Tag}) ->
    {ok, 1, Tag};
placement(#table{rows = Rows}, {program, Parent}) ->
    case Rows of
        #{Parent := #{job := Job}} -> {ok, Parent, Job};
        #{} -> {error, esrch}
    end;
placement(_T, _Starter) ->
    {error, einval}.

%% The group of the rows Job already has, or Id when it has none.
group(T, Job, Id) ->
    case [Pgid || #{job := J, pgid := Pgid} <- rows(T), J =:= Job] of
        [Pgid | _] -> Pgid;
        [] -> Id
    end.

%% The row of a place, or of an init, spoken for by Speaker.
-spec add(table(), place() | init(), pid()) -> table().
add(#table{rows = Rows} = T, #{pid := Id, ppid := Ppid, job := Job, pgid := Pgid}, Speaker) ->
    Row = #{pid => Id, ppid => Ppid, job => Job, pgid => Pgid, handler => Speaker},
    T#table{rows = Rows#{Id => Row}}.

drop(Id, #table{rows = Rows} = T) ->
    T#table{rows = maps:remove(Id, Rows)}.

carried(T, Tag) ->
    lists:any(fun(#{job := J}) -> J =:= Tag end, rows(T)).

%% The rows Target names within Scope: the row of that process id when
%% the scope reaches it; pid 1, the server, has none.
named(#table{rows = Rows}, Scope, Target) ->
    case Rows of
        #{Target := #{job := Job} = Row} when Scope =:= session; Scope =:= {job, Job} -> [Row];
        #{} -> []
    end.

%% After rows are dropped: the answer to each awaiter of a tag no row
%% carries any more, in tag order and each tag's awaiters in arrival order.
ended(#table{awaits = Awaits} = T) ->
    Ended = maps:filter(fun(Tag, _) -> not carried(T, Tag) end, Awaits),
    Answers = [{send, A, {programs_ended, Tag}}
               || Tag := Awaiters <- maps:iterator(Ended, ordered), A <- lists:reverse(Awaiters)],
    {T#table{awaits = maps:without(maps:keys(Ended), Awaits)}, Answers}.
