%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_job).
-moduledoc """
The job relay (docs/design-ssh.md, "Sessions, ttys and shells"): one
process of the session that runs `rc -c Command` for an SSH channel with no
pseudo-terminal and relays the job to the channel with the job messages.
erx_ssh_job_core decides every step; this module carries out its actions.

The job's standard input, output and error are three of the command shell's
message pipes (erx_shell_pipe), which the relay makes and so ends with. The
relay holds standard input's writing end and the reading ends of the other
two, and rc the opposite ends. It never waits on a pipe: each write and
read is an asynchronous request whose answer is a message, so the relay
always hears its channel. At the core's `close_input` it lets go of
standard input's writing end, and rc reads end of file.

rc runs linked to the relay (erx_shell_script:job/4), so the relay hears
its end as an exit signal, whose reason gives the status
(erx_console:shell_ending/1), and rc ends whenever the relay does. The
channel's end is `job_hangup`: the relay watches it.

The relay is also the job's group leader. Output requests are written to
standard error without holding it, so the stream still ends with rc, one
at a time, each answered once written, so a job that prints faster than
its channel takes waits in its own requests. Every other request is
answered `{error, enotsup}`, and a `requests` list with any other request
in it `{error, request}`. A `put_chars` that names a function to call is
taken only for io_lib's format/2 and fwrite/2, io:format's, so no job
process makes the relay run its code. rc ends only once an empty output
request of its own is answered (erx_shell_script:job/4), so every output
request the job made before it has entered standard error before the
stream ends.

Every message the relay does not expect is the channel's and goes to the
core, which ignores what it does not take.
""".

-export([start/3]).

-include("generated/erx_abi.hrl").

%% The answer each outstanding pipe request is waiting for, by its reference.
-type pending() :: write | {read, erx_ssh_job_core:stream()} | {io, pid(), term()}.

-record(relay, {job :: erx_ssh_job_core:job(),
                channel :: pid(),
                channel_ref :: reference(),
                stdin :: pid(),
                stdout :: pid(),
                stderr :: pid(),
                rc :: pid(),
                pending = #{} :: #{reference() => pending()},
                %% Whether an output request of the job's group is being written.
                io = idle :: idle | writing}).

-doc """
Starts the relay of a job for Channel: `rc -c Command` with the first
variables Vars, from the working directory Cwd. The relay is not linked to
the caller; it ends when the job has ended and its ending is sent, or at the
channel's hangup or end.
""".
-spec start(pid(), binary(), #{vars := erx_shell_script:vars(), cwd := binary()}) -> pid().
start(Channel, Command, #{vars := Vars, cwd := Cwd}) when is_pid(Channel), is_binary(Command) ->
    spawn(fun() -> init(Channel, Command, Vars, Cwd) end).

init(Channel, Command, Vars, Cwd) ->
    process_flag(trap_exit, true),
    [Stdin, Stdout, Stderr] = [erx_shell_pipe:new() || _ <- [stdin, stdout, stderr]],
    Rc = erx_shell_script:job(Command, Vars, Cwd,
                              #{0 => {pipe, Stdin}, 1 => {pipe, Stdout}, 2 => {pipe, Stderr}}),
    %% rc may write before its ends are attached, since a pipe takes writes
    %% from anyone and counts its holders only to tell when a stream has
    %% ended; and if rc has ended already, its attach closes that end at
    %% once, as the pipe's monitor of a dead holder fires at once.
    ok = erx_shell_pipe:attach(Stdin, write, self()),
    ok = erx_shell_pipe:attach(Stdin, read, Rc),
    ok = erx_shell_pipe:attach(Stdout, read, self()),
    ok = erx_shell_pipe:attach(Stdout, write, Rc),
    ok = erx_shell_pipe:attach(Stderr, read, self()),
    ok = erx_shell_pipe:attach(Stderr, write, Rc),
    Relay = #relay{job = erx_ssh_job_core:new(), channel = Channel,
                   channel_ref = monitor(process, Channel),
                   stdin = Stdin, stdout = Stdout, stderr = Stderr, rc = Rc},
    %% A new job has both readers reading (erx_ssh_job_core:new/0).
    loop(act([{read, stdout}, {read, stderr}], Relay)).

loop(#relay{pending = Pending, channel_ref = ChannelRef, rc = Rc, io = Io} = Relay) ->
    receive
        {Ref, Reply} when is_map_key(Ref, Pending) ->
            loop(answered(Ref, Reply, Relay));
        {'DOWN', Ref, process, _, _} when is_map_key(Ref, Pending) ->
            loop(answered(Ref, gone, Relay));
        {'DOWN', ChannelRef, process, _, _} ->
            loop(step({channel, job_hangup}, Relay));
        {'EXIT', Rc, Reason} ->
            loop(step({ended, status(erx_console:shell_ending(Reason))}, Relay));
        {'EXIT', _Other, _Reason} ->
            loop(Relay);
        {io_request, From, ReplyAs, Request} when is_pid(From), Io =:= idle ->
            loop(io_request(From, ReplyAs, Request, Relay));
        Message ->
            loop(step({channel, Message}, Relay))
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
        {{io, From, ReplyAs}, ok} -> io_reply(From, ReplyAs, ok, Relay1#relay{io = idle});
        {{io, From, ReplyAs}, _EpipeOrGone} -> io_reply(From, ReplyAs, {error, epipe}, Relay1#relay{io = idle})
    end.

%% A job's status. The relay sends rc no interrupt, so rc ends by a signal
%% only if some other process of the session forged one; that is a failure.
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
action({send, Message}, #relay{channel = Channel} = Relay) ->
    Channel ! Message,
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

io_request(From, ReplyAs, Request, #relay{stderr = Stderr} = Relay) ->
    case output(Request) of
        {ok, Bytes} ->
            Ref = erx_shell_pipe:put_async(Stderr, Bytes),
            request(Ref, {io, From, ReplyAs}, Relay#relay{io = writing});
        {error, _} = Refused -> io_reply(From, ReplyAs, Refused, Relay)
    end.

io_reply(From, ReplyAs, Reply, Relay) ->
    From ! {io_reply, ReplyAs, Reply},
    Relay.

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
