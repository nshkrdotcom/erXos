%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_job_core).
-moduledoc """
The job relay's decisions, pure (docs/design-ssh.md, "Sessions, ttys and
shells"): how a session relays a job, a program run on three pipes for an
SSH channel with no pseudo-terminal, to that channel with the job
messages, and what a channel accepts of them.

The relay's side, step/2. The relay holds standard input's writing end and
the reading ends of standard output and error. Its events are the
channel's messages, each untrusted, the input writer's `written`, a
reader's `{read, Stream, Bytes | eof}` and the job's `{ended, Status}`;
step/2 answers the relay's next state and the actions to carry out, in
order:

* input: a `job_input` is checked as the design's table has it, a binary
  of at most ssh_line_data_max bytes with no other `job_input` unanswered
  and no `job_eof` before it, and is written (`{write, Bytes}`); once
  written, the channel hears `job_written`. A `job_input` that fails the
  check ends the job as `job_hangup` does. `job_eof` closes standard
  input's writing end (`close_input`) once what came before it is written,
  and a second `job_eof` changes nothing.
* output: a reader's bytes go to the channel as `{job_output, Stream,
  Bytes}` when no other `job_output` is unanswered, and wait otherwise,
  their reader not reading until they are sent. Since the reader whose
  piece is unanswered is not reading either, at most one piece waits.
  `job_sent` answers the unanswered piece, the waiting one goes next, and
  the reader whose piece was answered reads again (`{read, Stream}`). A
  `job_sent` with none unanswered is a late repeat and changes nothing.
* the ending: `{exited, Status}` goes once the job has ended, both readers
  have met the end of their streams and nothing waits or is unanswered, so
  it arrives after every byte of output; then `stop`.
* `job_hangup` ends the job at once: `hangup`, the relay closing every end
  and ending the job's programs. Any other message changes nothing.

After `stop` or `hangup` the relay is over and every event changes
nothing, so nothing a channel sends later reaches the job.

The channel's side, heard/2: the checks a channel makes of the line's
messages for its job, each heard from the session, given which of its own
messages are unanswered. A message that fails its check closes the
channel.
""".

-export([new/0, step/2, heard/2]).
-export_type([job/0, event/0, action/0, stream/0, unanswered/0]).

-include("generated/erx_abi.hrl").

-type stream() :: stdout | stderr.

%% phase: running until stop or hangup; input: whether a job_input is being
%% written; eof: whether the channel has sent job_eof, and whether standard input
%% is closed; sent: the stream of the one unanswered job_output; waiting: the one
%% reader's piece held until it can go; open: the streams whose readers have not
%% met their end; status: the job's exit status once it has ended.
-opaque job() :: #{phase := running | over,
                   input := idle | writing,
                   eof := none | pending | closed,
                   sent := none | stream(),
                   waiting := none | {stream(), binary()},
                   open := [stream()],
                   status := running | 0..255}.

-type event() :: {channel, term()}
               | written
               | {read, stream(), binary() | eof}
               | {ended, 0..255}.

-type action() :: {write, binary()}
                | close_input
                | {send, job_written
                       | {job_output, stream(), binary()}
                       | {exited, 0..255}}
                | {read, stream()}
                | hangup
                | stop.

%% A channel's own messages that the line has not answered yet.
-type unanswered() :: #{input := boolean(), output := boolean()}.

-doc "A job just started: no input, both readers reading, still running.".
-spec new() -> job().
new() ->
    #{phase => running, input => idle, eof => none, sent => none,
      waiting => none, open => [stdout, stderr], status => running}.

-doc """
The relay's next state and actions, in order, for Event (see the module
documentation). A reader's bytes are at most ssh_line_data_max, as the
relay reads them.
""".
-spec step(event(), job()) -> {job(), [action()]}.
step(_Event, #{phase := over} = Job) ->
    {Job, []};
step({channel, {job_input, Bytes}}, #{input := idle, eof := none} = Job)
  when is_binary(Bytes), byte_size(Bytes) =< ?ERX_SSH_LINE_DATA_MAX ->
    {Job#{input := writing}, [{write, Bytes}]};
step({channel, {job_input, _}}, Job) ->
    over(Job, [hangup]);
step({channel, job_eof}, #{eof := none, input := writing} = Job) ->
    {Job#{eof := pending}, []};
step({channel, job_eof}, #{eof := none} = Job) ->
    {Job#{eof := closed}, [close_input]};
step({channel, job_sent}, #{sent := Stream} = Job) when Stream =/= none ->
    next(Job#{sent := none}, [{read, Stream}]);
step({channel, job_hangup}, Job) ->
    over(Job, [hangup]);
step({channel, _Other}, Job) ->
    {Job, []};
step(written, #{input := writing, eof := pending} = Job) ->
    {Job#{input := idle, eof := closed}, [{send, job_written}, close_input]};
step(written, #{input := writing} = Job) ->
    {Job#{input := idle}, [{send, job_written}]};
step({read, Stream, eof}, #{open := Open} = Job) ->
    finish(Job#{open := lists:delete(Stream, Open)}, []);
step({read, Stream, Bytes}, #{waiting := none} = Job) when is_binary(Bytes) ->
    next(Job#{waiting := {Stream, Bytes}}, []);
step({ended, Status}, #{status := running} = Job) ->
    finish(Job#{status := Status}, []).

-doc """
How a channel takes Message heard from the session for its job, given
which of its own messages are unanswered: `written` answers its
`job_input`, `{output, Stream, Bytes}` is data to send on Stream, which
the channel answers with `job_sent` once sent, `{ended, Status}` its
exit-status, and `close` a message that fails its check.
""".
-spec heard(term(), unanswered()) ->
          written | {output, stream(), binary()} | {ended, 0..255} | close.
heard(job_written, #{input := true}) ->
    written;
heard({job_output, Stream, Bytes}, #{output := false})
  when (Stream =:= stdout orelse Stream =:= stderr), is_binary(Bytes),
       byte_size(Bytes) =< ?ERX_SSH_LINE_DATA_MAX ->
    {output, Stream, Bytes};
heard({exited, Status}, _Unanswered)
  when is_integer(Status), Status >= 0, Status =< 255 ->
    {ended, Status};
heard(_Message, _Unanswered) ->
    close.

%% With no job_output unanswered, the waiting piece goes.
next(#{sent := none, waiting := {Stream, Bytes}} = Job, Actions) ->
    {Job#{sent := Stream, waiting := none},
     Actions ++ [{send, {job_output, Stream, Bytes}}]};
next(Job, Actions) ->
    finish(Job, Actions).

%% The ending once the job has ended, both streams are at their end and
%% nothing waits or is unanswered.
finish(#{status := Status, open := [], sent := none, waiting := none} = Job,
       Actions) when is_integer(Status) ->
    over(Job, Actions ++ [{send, {exited, Status}}, stop]);
finish(Job, Actions) ->
    {Job, Actions}.

over(Job, Actions) ->
    {Job#{phase := over}, Actions}.
