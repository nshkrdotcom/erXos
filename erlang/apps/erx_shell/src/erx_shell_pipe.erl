%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_pipe).
-moduledoc """
A pipe between Erlang stages of the command shell (docs/design-shell.md,
"Pipelines"): one process holding the bytes a stage wrote and its reader
has not yet taken, in the order they were written.

Bounds. At most 64 KiB are in flight, the size of a pipe's first ring
(docs/design-pipes.md). A writer's bytes enter as room opens, and its
put/2 returns once the last of them has entered, so a writer never runs
more than 64 KiB ahead of its reader; put_async/2 keeps that bound when its
caller keeps one write unanswered (Requests, below). A reader takes whatever bytes are in
flight, get_bytes/1, or a line, get/1, of at most 64 KiB with its newline:
bytes that fill the pipe without a newline answer `line_too_long`, so no
input makes a reader gather without bound, and a reader waiting for a
line always finds the newline or a full pipe.

Ends. The runner that makes a pipe attaches each stage to the end it
holds, and the pipe monitors every holder. A holder lets go of its end
when it ends or when it closes it, close/1, which an SSH job's relay
does at the channel's end of input while it goes on running. When every
writer has let go, a reader that drained the pipe gets `eof`; when every
reader has, what was in flight is dropped and every writer, waiting or
not, gets `epipe`, as a write on a pipe with no reader does. An end that
nothing ever attached stays open: the runner stops every pipe it made
once the request that made it is done, and a pipe also ends with the
process that made it, so no pipe outlives its line.

Requests. put/2, get/1 and get_bytes/1 wait for their answer. A process
that must not wait, as a job's relay serving its channel, asks with
put_async/2 or get_bytes_async/2 instead: the answer comes later as the
message `{Ref, Reply}`, Reply what the waiting form returns, or, if the
pipe is gone first, as its `{'DOWN', Ref, process, _, _}`, which means
`{error, epipe}` to a write and `eof` to a read. Ref is the request's
monitor, removed by either answer, so neither answer outlives the other.
A request cannot be withdrawn, and the pipe holds every request sent, so
the bound on what waits in the pipe is the caller's: it keeps at most one
write and one read unanswered, as the waiting forms do by waiting.

`from_binary/1` and `from_file/1` make a pipe a pump process fills, for
a here document and for `<`, so every input an Erlang command reads is a
pipe and has the same bounds.
""".

-export([new/0, attach/3, close/1, put/2, get/1, get_bytes/1, stop/1,
         put_async/2, get_bytes_async/2, from_binary/1, from_file/1]).

-compile({no_auto_import, [put/2, get/1]}).

%% The bytes in flight, and so the longest line a reader takes, newline
%% included.
-define(CAPACITY, 1 bsl 16).

-type end_() :: read | write.
%% What a reader asks for: a line, or the bytes in flight up to a maximum.
-type mode() :: line | {bytes, pos_integer()}.

-doc "A new, empty pipe, which ends when its maker does.".
-spec new() -> pid().
new() ->
    Maker = self(),
    spawn(fun() ->
                  monitor(process, Maker),
                  loop(#{maker => Maker, buffer => <<>>, putters => queue:new(),
                         getters => queue:new(), holders => #{},
                         held => #{read => 0, write => 0},
                         seen => #{read => false, write => false}})
          end).

-doc "Makes Pid a holder of the pipe's End.".
-spec attach(pid(), end_(), pid()) -> ok.
attach(Pipe, End, Pid) when End =:= read; End =:= write ->
    Pipe ! {attach, End, Pid},
    ok.

-doc """
The calling process lets go of the end it holds, without ending; the
pipe then acts as if it had ended. It must have attached itself, so that
the pipe has its attach before its close. A writer's writes sent before
enter first and are read before the end of the stream.
""".
-spec close(pid()) -> ok.
close(Pipe) ->
    Pipe ! {detach, self()},
    ok.

-doc """
Writes bytes, waiting until the last of them has entered the pipe: `ok`,
or `{error, epipe}` when no reader is left or the pipe is gone.
""".
-spec put(pid(), binary()) -> ok | {error, epipe}.
put(_Pipe, <<>>) -> ok;
put(Pipe, Bytes) when is_binary(Bytes) -> call(Pipe, {put, Bytes}, {error, epipe}).

-doc """
The next line, with its newline unless it is the last and has none;
`eof` once every writer has ended and the pipe is drained, or the pipe is
gone; `{error, line_too_long}` when 64 KiB hold no newline.
""".
-spec get(pid()) -> {line, binary()} | eof | {error, line_too_long}.
get(Pipe) -> call(Pipe, {get, line}, eof).

-doc "The bytes in flight, at most 64 KiB, or `eof`.".
-spec get_bytes(pid()) -> {bytes, binary()} | eof.
get_bytes(Pipe) -> call(Pipe, {get, {bytes, ?CAPACITY}}, eof).

-doc """
Asks for put/2 without waiting; the answer comes as the module
documentation's Requests say.
""".
-spec put_async(pid(), binary()) -> reference().
put_async(Pipe, Bytes) when is_binary(Bytes) -> request(Pipe, {put, Bytes}).

-doc """
Asks without waiting for the bytes in flight, at most Max of them, or
`eof`; the answer comes as the module documentation's Requests say.
""".
-spec get_bytes_async(pid(), pos_integer()) -> reference().
get_bytes_async(Pipe, Max) when is_integer(Max), Max > 0 ->
    request(Pipe, {get, {bytes, Max}}).

-doc "Ends the pipe and whatever pumps it.".
-spec stop(pid()) -> ok.
stop(Pipe) ->
    exit(Pipe, kill),
    ok.

-doc "A pipe holding Bytes and then its end, for a here document.".
-spec from_binary(binary()) -> pid().
from_binary(Bytes) ->
    Pipe = new(),
    spawn(fun() -> pump_start(Pipe, fun() -> _ = put(Pipe, Bytes), ok end) end),
    Pipe.

-doc """
A pipe that a pump fills from the file at Path, opened before this
returns so that a file that cannot be read is an error of the caller.
""".
-spec from_file(binary()) -> {ok, pid()} | {error, file:posix() | badarg}.
from_file(Path) ->
    Pipe = new(),
    Caller = self(),
    Ref = make_ref(),
    {_Pump, PumpRef} =
        spawn_monitor(fun() ->
                              case file:open(Path, [read, raw, binary]) of
                                  {ok, Fd} ->
                                      Caller ! {Ref, ok},
                                      pump_start(Pipe, fun() -> pump_file(Pipe, Fd) end);
                                  {error, Reason} ->
                                      Caller ! {Ref, {error, Reason}}
                              end
                      end),
    receive
        {Ref, ok} ->
            demonitor(PumpRef, [flush]),
            {ok, Pipe};
        {Ref, {error, Reason}} ->
            demonitor(PumpRef, [flush]),
            stop(Pipe),
            {error, Reason};
        {'DOWN', PumpRef, process, _, _} ->
            stop(Pipe),
            {error, badarg}
    end.

%%% The pumps

%% A pump holds the write end and ends with the pipe.
pump_start(Pipe, Fill) ->
    monitor(process, Pipe),
    attach(Pipe, write, self()),
    Fill().

pump_file(Pipe, Fd) ->
    case file:read(Fd, ?CAPACITY) of
        {ok, Bytes} ->
            case put(Pipe, Bytes) of
                ok -> pump_file(Pipe, Fd);
                {error, epipe} -> ok
            end;
        _EofOrError ->
            ok
    end.

%%% Calls

call(Pipe, Request, Gone) ->
    Ref = request(Pipe, Request),
    receive
        {Ref, Reply} -> Reply;
        {'DOWN', Ref, process, _, _} -> Gone
    end.

%% Sends Request answered to a monitor alias of the pipe: the pipe replies to
%% the alias, and the reply removes the monitor, so no answer outlives its
%% request.
request(Pipe, Request) ->
    Ref = monitor(process, Pipe, [{alias, reply_demonitor}]),
    Pipe ! {Request, Ref, Ref},
    Ref.

%%% The pipe's process

loop(State) ->
    receive
        {{put, Bytes}, From, Ref} ->
            loop(serve(offer({From, Ref, Bytes}, State)));
        {{get, Mode}, From, Ref} ->
            #{getters := Getters} = State,
            loop(serve(State#{getters := queue:in({From, Ref, Mode}, Getters)}));
        {attach, End, Pid} ->
            loop(attach_holder(End, Pid, State));
        {detach, Pid} ->
            loop(serve(detach_holder(Pid, State)));
        {'DOWN', _, process, Pid, _} ->
            case State of
                #{maker := Pid} -> exit(normal);
                _ -> loop(serve(detach_holder(Pid, State)))
            end
    end.

attach_holder(End, Pid, #{holders := Holders, held := Held, seen := Seen} = State) ->
    monitor(process, Pid),
    State#{holders := Holders#{Pid => End},
           held := Held#{End := maps:get(End, Held) + 1},
           seen := Seen#{End := true}}.

detach_holder(Pid, #{holders := Holders, held := Held} = State) ->
    case maps:take(Pid, Holders) of
        {End, Holders1} ->
            State1 = State#{holders := Holders1,
                            held := Held#{End := maps:get(End, Held) - 1}},
            case End =:= read andalso closed(read, State1) of
                true -> refuse_writers(State1);
                false -> State1
            end;
        error ->
            State
    end.

%% An end is closed once something held it and nothing holds it now.
closed(End, #{held := Held, seen := Seen}) ->
    maps:get(End, Seen) andalso maps:get(End, Held) =:= 0.

%% No reader is left: what was in flight is dropped and every writer told.
refuse_writers(#{putters := Putters} = State) ->
    [From ! {Ref, {error, epipe}} || {From, Ref, _} <- queue:to_list(Putters)],
    State#{buffer := <<>>, putters := queue:new()}.

offer({From, Ref, _Bytes} = Put, #{putters := Putters} = State) ->
    case closed(read, State) of
        true ->
            From ! {Ref, {error, epipe}},
            State;
        false ->
            State#{putters := queue:in(Put, Putters)}
    end.

%% Moves waiting writers' bytes in as room allows, then answers every
%% reader it can, until neither can move.
serve(State) ->
    State1 = answer(admit(State)),
    case State1 =:= State of
        true -> State;
        false -> serve(State1)
    end.

%% The first waiting writer's bytes enter as far as there is room; it is
%% answered once the last of them has entered, and the next one may start.
admit(#{putters := Putters, buffer := Buffer} = State) ->
    Room = ?CAPACITY - byte_size(Buffer),
    case queue:out(Putters) of
        {{value, {From, Ref, Bytes}}, Rest} when byte_size(Bytes) =< Room ->
            From ! {Ref, ok},
            admit(State#{putters := Rest, buffer := <<Buffer/binary, Bytes/binary>>});
        {{value, {From, Ref, Bytes}}, Rest} when Room > 0 ->
            <<Now:Room/binary, Later/binary>> = Bytes,
            State#{putters := queue:in_r({From, Ref, Later}, Rest),
                   buffer := <<Buffer/binary, Now/binary>>};
        _FullOrNone ->
            State
    end.

answer(#{getters := Getters} = State) ->
    case queue:out(Getters) of
        {{value, {From, Ref, Mode}}, Rest} ->
            case take(Mode, State) of
                {Reply, State1} ->
                    From ! {Ref, Reply},
                    answer(State1#{getters := Rest});
                wait ->
                    State
            end;
        {empty, _} ->
            State
    end.

%% What a reader in Mode gets from the pipe, or wait. A line is copied out
%% of the buffer, so a reader that keeps its lines, as `sort` does, holds
%% only their bytes and never a reference to the whole buffer, which the
%% stage's heap limit would charge in full.
-spec take(mode(), map()) -> {term(), map()} | wait.
take(_Mode, #{buffer := <<>>} = State) ->
    case drained(State) of
        true -> {eof, State};
        false -> wait
    end;
take({bytes, Max}, #{buffer := Buffer} = State) when byte_size(Buffer) =< Max ->
    {{bytes, Buffer}, State#{buffer := <<>>}};
take({bytes, Max}, #{buffer := Buffer} = State) ->
    <<Bytes:Max/binary, After/binary>> = Buffer,
    {{bytes, Bytes}, State#{buffer := After}};
take(line, #{buffer := Buffer} = State) ->
    case binary:match(Buffer, <<"\n">>) of
        {At, 1} ->
            <<Line:(At + 1)/binary, After/binary>> = Buffer,
            {{line, binary:copy(Line)}, State#{buffer := After}};
        nomatch ->
            %% The last line may have no newline; it is whole once no
            %% writer is left and no writer's bytes wait to enter.
            case drained(State) of
                true -> {{line, Buffer}, State#{buffer := <<>>}};
                false when byte_size(Buffer) >= ?CAPACITY -> {{error, line_too_long}, State};
                false -> wait
            end
    end.

%% No writer is left and none of their bytes wait to enter.
drained(#{putters := Putters} = State) ->
    closed(write, State) andalso queue:is_empty(Putters).
