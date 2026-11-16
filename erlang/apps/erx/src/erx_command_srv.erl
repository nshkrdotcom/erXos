%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_command_srv).
-moduledoc """
The session's command server (docs/design-programs.md, "The command
server"), process id 1 of the session's process table: it assigns
process ids, spawns each program's handler outside every job, keeps the
table and finds the handlers of the processes a `kill` or a job names.
erx_command_core decides everything; this process performs each action
in order and turns each row's end, a monitor's `'DOWN'`, back into an
event.

erx_session_sup starts it, registered as erx_command_srv, and never
restarts it: a new server could not know which ids the old one gave, so
its end ends the session. A domain that runs no session has none, and
there handler/1 and reserve/1 answer `{error, enotsup}`, programs/0 and
read/2 answer `[]` and kill/2 and probe/2 `{error, esrch}`, since such a
domain starts no program; await/1 and job/2 there send nothing, so an
await is never answered.

The server answers from its table alone and waits on nothing, a spawn
included, so a handler that asks keeps serving its program meanwhile.
It does not check who calls it: every caller is a process of the
session, and a program reaches it only through its handler.
""".
-behaviour(gen_server).

-export([start_link/0, handler/2, reserve/1, programs/0, await/1, job/2, kill/4, probe/2, read/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-doc "Starts the session's command server, registered as erx_command_srv.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
A new program's handler, spawned by the server with the caller as the
process whose start it waits for and `Key`, a reference the caller made,
as the key that start carries (erx_prog_handler:serve/1), and the
process id the server gave the program: `{ok, Handler, Pid}`, or
`{error, Errno}`, `eagain` once every id has been given, `esrch` for a
program starter the table does not name, `enotsup` where no session
runs. The caller monitors the handler before it sends the start.
""".
-spec handler(erx_command_core:starter(), reference()) ->
          {ok, pid(), pos_integer()} | {error, atom()}.
handler(Starter, Key) ->
    call({handler, Starter, Key}, {error, enotsup}).

-doc """
A process id whose row the caller speaks for, as a command's stream relay
does: `{ok, Pid, Pgid}`, or `{error, Errno}` as handler/1. The row lasts
while the caller lives.
""".
-spec reserve(erx_command_core:starter()) -> {ok, pos_integer(), pos_integer()} | {error, atom()}.
reserve(Starter) ->
    call({reserve, Starter}, {error, enotsup}).

-doc "The table's rows, in process id order.".
-spec programs() -> [erx_command_core:row()].
programs() ->
    call(programs, []).

-doc """
Asks for `{programs_ended, Tag}`, sent to the caller once no row carries
`Tag`: at once when none does.
""".
-spec await(term()) -> ok.
await(Tag) ->
    gen_server:cast(?MODULE, {await, Tag, self()}).

-doc """
Sends `{erx_job, Action}`, `Action` being `pause`, `resume` or
`{signal, Signal}`, to the handler of each row of job `Tag`.
""".
-spec job(term(), pause | resume | {signal, atom()}) -> ok.
job(Tag, Action) ->
    gen_server:cast(?MODULE, {job, Tag, Action}).

-doc """
Sends `{erx_signal, Signal, Sender}` to the handler of the row `Target`
names within `Scope`, `session` or `{job, Tag}`: `ok`, or
`{error, esrch}` when no row is in scope, pid 1 included.
""".
-spec kill(erx_command_core:scope(), pos_integer(), atom(), pos_integer()) -> ok | {error, esrch}.
kill(Scope, Target, Signal, Sender) ->
    call({kill, Scope, Target, Signal, Sender}, {error, esrch}).

-doc "Answers as kill/4 with the same `Scope` and `Target` would, sending nothing.".
-spec probe(erx_command_core:scope(), pos_integer()) -> ok | {error, esrch}.
probe(Scope, Target) ->
    call({probe, Scope, Target}, {error, esrch}).

-doc """
The process table as `ps` and `/proc` read it, in the caller: each row,
with each of `Keys` as its handler answers it, or `missing` for a handler
that ends meanwhile or has not answered within `Timeout` milliseconds.
Each handler is asked `{erx_read, Alias, Keys}` at once and answers
`{erx_values, Alias, Handler, Values}`, a map, of which only `Keys` are
kept. Answers are keyed by handler, so every row one speaker speaks for
has the values it answered.
""".
-spec read([atom()], non_neg_integer()) -> [map()].
read(Keys, Timeout) when is_list(Keys), is_integer(Timeout), Timeout >= 0 ->
    Rows = programs(),
    Alias = alias(),
    Watches = maps:from_list([{monitor(process, H, [{tag, {erx_read_down, Alias}}]), H}
                              || #{handler := H} <- Rows]),
    [H ! {erx_read, Alias, Keys} || #{handler := H} <- Rows],
    Answers = collect(Alias, Watches, erlang:monotonic_time(millisecond) + Timeout, #{}),
    unalias(Alias),
    [demonitor(W, [flush]) || W := _ <- Watches],
    flush_answers(Alias),
    Missing = maps:from_keys(Keys, missing),
    [maps:merge(Row, maps:merge(Missing, maps:with(Keys, maps:get(H, Answers, #{}))))
     || #{handler := H} = Row <- Rows].

%% Each handler's answer until every handler has answered or ended, or
%% until Deadline.
collect(_Alias, Watches, _Deadline, Answers) when map_size(Watches) =:= 0 ->
    Answers;
collect(Alias, Watches, Deadline, Answers) ->
    Wait = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {erx_values, Alias, H, Values} when is_map(Values) ->
            collect(Alias, unwatch(Watches, H), Deadline, Answers#{H => Values});
        {{erx_read_down, Alias}, W, process, _, _} ->
            collect(Alias, maps:remove(W, Watches), Deadline, Answers)
    after Wait ->
        Answers
    end.

%% Watches without those of H, whose monitors are dropped.
unwatch(Watches, H) ->
    [demonitor(W, [flush]) || W := Watched <- Watches, Watched =:= H],
    maps:filter(fun(_, Watched) -> Watched =/= H end, Watches).

%% Answers that arrived before the alias went.
flush_answers(Alias) ->
    receive {erx_values, Alias, _, _} -> flush_answers(Alias)
    after 0 -> ok
    end.

%% A call of the server, or Absent where no session runs it.
call(Request, Absent) ->
    try
        gen_server:call(?MODULE, Request, infinity)
    catch
        exit:{noproc, _} -> Absent
    end.

init([]) ->
    {ok, erx_command_core:new()}.

handle_call(Call, {Caller, _} = From, T) ->
    {noreply, run(erx_command_core:step(T, {call, From, Caller, Call}))}.

handle_cast({await, _Tag, Awaiter} = Event, T) when is_pid(Awaiter) ->
    {noreply, run(erx_command_core:step(T, Event))};
handle_cast({job, _Tag, _Action} = Event, T) ->
    {noreply, run(erx_command_core:step(T, Event))};
handle_cast(_Msg, T) ->
    {noreply, T}.

handle_info({'DOWN', _, process, Speaker, _}, T) ->
    {noreply, run(erx_command_core:step(T, {down, Speaker}))};
handle_info(_Msg, T) ->
    {noreply, T}.

%% Performs the actions in order. A spawn steps the core with the new
%% handler at once, so its row exists before the server takes its next
%% message.
run({T, Actions}) ->
    lists:foldl(fun perform/2, T, Actions).

perform({spawn_handler, From, Init}, T) ->
    Handler = spawn(erx_prog_handler, serve, [Init]),
    run(erx_command_core:step(T, {spawned, From, Init, Handler}));
perform({monitor, Speaker}, T) ->
    _ = monitor(process, Speaker),
    T;
perform({reply, From, Answer}, T) ->
    gen_server:reply(From, Answer),
    T;
perform({send, To, Message}, T) ->
    To ! Message,
    T.
