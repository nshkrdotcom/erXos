%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_job).
-moduledoc """
The job relay (docs/design-ssh.md, "Sessions, ttys and shells"): one
process of the session that runs `rc -c Command` for an SSH channel with no
pseudo-terminal and relays the job to the channel with the job messages.
erx_ssh_job_core decides every step; this module carries out its actions.

The channel starts the relay (start/2) and makes an alias of its own for
the job, which only the two of them are given. Every job message is tagged
with it both ways: the relay sends `{Alias, Message}` to the alias, and
takes from the channel only `{Alias, Message}`. So no other process of the
session can send either side a job message, by mistake or by naming its
pid.

The job's standard input, output and error are three of the command shell's
message pipes (erx_shell_pipe), which the relay makes and so ends with. The
relay holds standard input's writing end and the reading ends of the other
two, and rc the opposite ends. It never waits on a pipe: each write and
read is an asynchronous request whose answer is a message, so the relay
always hears its channel. At the core's `close_input` it lets go of
standard input's writing end, and rc reads end of file.

rc runs linked to the relay (erx_shell_script:job/4), so rc ends whenever
the relay does. The relay watches rc and the channel with monitors: rc's
end gives the job's status (erx_console:shell_ending/1), and the channel's
end is `job_hangup`.

The relay is also the job's group leader. Output requests are written to
standard error without holding it, so the stream still ends with rc, one
at a time, in the order they arrive, each answered once written, so a job
that prints faster than its channel takes waits in its own requests; a
process that waits for its answer, as io's functions do, has at most one
waiting. Every other request is answered `{error,
enotsup}`, and a `requests` list with any other request in it `{error,
request}`. A `put_chars` that names a function to call is taken only for
io_lib's format/2 and fwrite/2, io:format's, so no job process makes the
relay run its code. rc ends only once an empty output request of its own
is answered (erx_shell_script:job/4), so every output request the job made
before it has entered standard error before the stream ends.

Every other message, rc's exit signal among them, is dropped.
""".

-export([start/2]).
-export_type([tag/0]).

-include("generated/erx_abi.hrl").

-doc "The alias of the channel's that tags the job messages between it and the relay.".
-type tag() :: reference().

%% An output request of the job's group: who asked, its reply tag and the request.
-type io_request() :: {pid(), term(), term()}.

%% The answer each outstanding pipe request is waiting for, by its reference.
-type pending() :: write | {read, erx_ssh_job_core:stream()} | {io, pid(), term()}.

%% job: the core's state; alias: the channel's tag; channel_ref and rc_ref: the
%% monitors of the channel and of rc; stdin, stdout and stderr: the pipes; pending:
%% the outstanding pipe requests; io: idle, or writing one output request of the
%% group with the ones that arrived since waiting in order.
-record(relay, {job :: erx_ssh_job_core:job(),
                alias :: tag(),
                channel_ref :: reference(),
                rc_ref :: reference(),
                stdin :: pid(),
                stdout :: pid(),
                stderr :: pid(),
                pending = #{} :: #{reference() => pending()},
                io = idle :: idle | {writing, queue:queue(io_request())}}).

-doc """
Starts the relay of a job for the calling process, its channel: `rc -c
Command` with the first variables Vars, from the working directory Cwd.
Answers the relay and the alias of the caller's that tags the job messages
(the module documentation). The relay is not linked to the caller; it ends
when the job has ended and its ending is sent, or at the channel's hangup or
end.
""".
-spec start(binary(), #{vars := erx_shell_script:vars(), cwd := binary()}) -> {pid(), tag()}.
start(Command, #{vars := Vars, cwd := Cwd}) when is_binary(Command) ->
    Channel = self(),
    Alias = alias(),
    {spawn(fun() -> init(Channel, Alias, Command, Vars, Cwd) end), Alias}.

init(Channel, Alias, Command, Vars, Cwd) ->
    process_flag(trap_exit, true),
    [Stdin, Stdout, Stderr] = [erx_shell_pipe:new() || _ <- [stdin, stdout, stderr]],
    Rc = erx_shell_script:job(Command, Vars, Cwd,
                              #{0 => {pipe, Stdin}, 1 => {pipe, Stdout}, 2 => {pipe, Stderr}}),
    %% rc ends only after the loop answers its last output request, unless an
    %% exit signal ends it sooner; then the monitor reports noproc, which
    %% erx_console:shell_ending/1 takes as status 1.
    RcRef = monitor(process, Rc),
    %% rc may write before its ends are attached, since a pipe takes writes
    %% from anyone and counts its holders only to tell when a stream has
    %% ended.
    ok = erx_shell_pipe:attach(Stdin, write, self()),
    ok = erx_shell_pipe:attach(Stdin, read, Rc),
    ok = erx_shell_pipe:attach(Stdout, read, self()),
    ok = erx_shell_pipe:attach(Stdout, write, Rc),
    ok = erx_shell_pipe:attach(Stderr, read, self()),
    ok = erx_shell_pipe:attach(Stderr, write, Rc),
    Relay = #relay{job = erx_ssh_job_core:new(), alias = Alias,
                   channel_ref = monitor(process, Channel), rc_ref = RcRef,
                   stdin = Stdin, stdout = Stdout, stderr = Stderr},
    %% A new job has both readers reading (erx_ssh_job_core:new/0).
    loop(act([{read, stdout}, {read, stderr}], Relay)).

loop(#relay{pending = Pending, alias = Alias, channel_ref = ChannelRef, rc_ref = RcRef} = Relay) ->
    receive
        {Ref, Reply} when is_map_key(Ref, Pending) ->
            loop(answered(Ref, Reply, Relay));
        {'DOWN', Ref, process, _, _} when is_map_key(Ref, Pending) ->
            loop(answered(Ref, gone, Relay));
        {'DOWN', ChannelRef, process, _, _} ->
            loop(step({channel, job_hangup}, Relay));
        {'DOWN', RcRef, process, _, Reason} ->
            loop(step({ended, status(erx_console:shell_ending(Reason))}, Relay));
        {Alias, Message} ->
            loop(step({channel, Message}, Relay));
        {io_request, From, ReplyAs, Request} when is_pid(From) ->
            loop(io_request({From, ReplyAs, Request}, Relay));
        _Other ->
            loop(Relay)
    end.

%% A pipe's answer to an outstanding request, or `gone` when the pipe went
%% first, which a write takes as written, its bytes with nowhere to go, and a
%% read as the end of the stream.
answered(Ref, Reply, #relay{pending = Pending} = Relay) ->
    {Waiting, Pending1} = maps:take(Ref, Pending),
    Relay1 = Relay#relay{pending = Pending1},
    case {Waiting, Reply} of
        {write, _OkOrEpipe} -> step(written, Relay1);
        {{read, Stream}, {bytes, Bytes}} -> step({read, Stream, Bytes}, Relay1);
        {{read, Stream}, _EofOrGone} -> step({read, Stream, eof}, Relay1);
        {{io, From, ReplyAs}, ok} -> io_written(From, ReplyAs, ok, Relay1);
        {{io, From, ReplyAs}, _EpipeOrGone} -> io_written(From, ReplyAs, {error, epipe}, Relay1)
    end.

%% A job's status. The relay sends rc no interrupt, so rc ends by a signal
%% only if some other process of the session sent it one; that is a failure.
status({exited, Status}) -> Status;
status({signaled, _Signal}) -> 1.

step(Event, #relay{job = Job} = Relay) ->
    {Job1, Actions} = erx_ssh_job_core:step(Event, Job),
    act(Actions, Relay#relay{job = Job1}).

act(Actions, Relay) ->
    lists:foldl(fun action/2, Relay, Actions).

action({write, Bytes}, #relay{stdin = Stdin} = Relay) ->
    request(erx_shell_pipe:put_async(Stdin, Bytes), write, Relay);
action(close_input, #relay{stdin = Stdin} = Relay) ->
    ok = erx_shell_pipe:close(Stdin),
    Relay;
action({read, Stream}, Relay) ->
    Ref = erx_shell_pipe:get_bytes_async(pipe(Stream, Relay), ?ERX_SSH_LINE_DATA_MAX),
    request(Ref, {read, Stream}, Relay);
action({send, Message}, #relay{alias = Alias} = Relay) ->
    Alias ! {Alias, Message},
    Relay;
%% The relay's end ends rc, which ends every process of the job
%% (erx_shell_script:job/4), and the pipes, which the relay made.
action(hangup, _Relay) ->
    exit({shutdown, hangup});
action(stop, _Relay) ->
    exit(normal).

pipe(stdout, #relay{stdout = Stdout}) -> Stdout;
pipe(stderr, #relay{stderr = Stderr}) -> Stderr.

request(Ref, Waiting, #relay{pending = Pending} = Relay) ->
    Relay#relay{pending = Pending#{Ref => Waiting}}.

%%% The job's group

%% An output request is written at once when none is being written, and waits
%% its turn otherwise.
io_request(Request, #relay{io = idle} = Relay) ->
    io_start(Request, queue:new(), Relay);
io_request(Request, #relay{io = {writing, Waiting}} = Relay) ->
    Relay#relay{io = {writing, queue:in(Request, Waiting)}}.

%% The request being written is answered, and the next waiting one starts.
io_written(From, ReplyAs, Reply, #relay{io = {writing, Waiting}} = Relay) ->
    io_reply(From, ReplyAs, Reply),
    io_next(Waiting, Relay).

io_next(Waiting, Relay) ->
    case queue:out(Waiting) of
        {{value, Request}, Rest} -> io_start(Request, Rest, Relay);
        {empty, _} -> Relay#relay{io = idle}
    end.

%% Starts writing Request, or answers its refusal at once and goes on to the
%% next waiting one.
io_start({From, ReplyAs, Request}, Waiting, #relay{stderr = Stderr} = Relay) ->
    case output(Request) of
        {ok, Bytes} ->
            Ref = erx_shell_pipe:put_async(Stderr, Bytes),
            request(Ref, {io, From, ReplyAs}, Relay#relay{io = {writing, Waiting}});
        {error, _} = Refused ->
            io_reply(From, ReplyAs, Refused),
            io_next(Waiting, Relay)
    end.

io_reply(From, ReplyAs, Reply) ->
    From ! {io_reply, ReplyAs, Reply},
    ok.

%% The bytes an output request writes, as UTF-8, or why it is refused.
output({put_chars, Encoding, Chars}) ->
    encode(Chars, Encoding);
output({put_chars, Encoding, io_lib, Function, [_Format, _Data] = Args})
  when Function =:= format; Function =:= fwrite ->
    try apply(io_lib, Function, Args) of
        Chars -> encode(Chars, Encoding)
    catch
        _:_ -> {error, put_chars}
    end;
output({put_chars, Chars}) ->
    encode(Chars, latin1);
output({requests, Requests}) when is_list(Requests) ->
    Outputs = [output(Request) || Request <- Requests],
    case [Bytes || {ok, Bytes} <- Outputs] of
        All when length(All) =:= length(Outputs) -> {ok, iolist_to_binary(All)};
        _Refused -> {error, request}
    end;
output(_InputOrOptions) ->
    {error, enotsup}.

encode(Chars, Encoding) when Encoding =:= unicode; Encoding =:= latin1 ->
    try unicode:characters_to_binary(Chars, Encoding, utf8) of
        Bytes when is_binary(Bytes) -> {ok, Bytes};
        _ErrorOrIncomplete -> {error, put_chars}
    catch
        error:badarg -> {error, put_chars}
    end;
encode(_Chars, _Encoding) ->
    {error, put_chars}.
