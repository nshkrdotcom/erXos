%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_dev_channel).
-moduledoc """
A session channel of SSH's first stage (docs/design-ssh.md, "Stages"): the
channel process of OTP's daemon that erx_ssh_dev runs in root's session.
A channel that asked for a pseudo-terminal is the master of one tty of that
session, on which the command shell runs (erx_session_tty:open_channel/3);
an `exec` without one runs as a job on message pipes, relayed by the
session's job relay (erx_session_tty:open_job/1, erx_ssh_job).

On a tty the channel speaks the tty's six messages (erx_tty_link) to the
tty's relay, a process of this domain, as the SSH domain's channel does at
stage 2, so the tty, its line discipline and its shell are the ones every
session tty has: Ctrl-C reaches the shell as the line discipline's SIGINT,
and a window change is the tty's `{tty_size, Rows, Columns}`. `pty-req`
gives the tty's size and TERM, and the data the client sends is the tty's
input, the client's window opening by what the channel hands the tty.
`shell` opens the tty, with or without a `pty-req` (24 rows of 80 columns
and TERM vt100 without one), and runs the command shell on it; an `exec`
after a `pty-req` opens it and runs `rc -c Command` on it.

An `exec` without a `pty-req` runs `rc -c Command` as a job, and the
channel speaks the job messages (docs/design-ssh.md, "Sessions, ttys and
shells") to the job's relay, each tagged both ways with the alias the
channel made for the job (erx_ssh_job), so no other process of the session
speaks for the relay: the client's data goes as `job_input` pieces of
at most ssh_line_data_max bytes, one unanswered at a time, and the client's
window opens by a piece's size once the relay answers `job_written`, so
what the channel holds of the client's input is bounded by the window it
gave. The channel's window/0 tells OTP's channel not to open the window
itself after each data message (docs/design-ssh.md, "Edits to OTP's
ssh"), so the channel's own adjusts, here and on a tty, are the only
ones. The client's end of input goes as `job_eof` once every piece before
it is answered. What the relay sends is checked by
erx_ssh_job_core:heard/2: a job's standard output is channel data, its
standard error extended data, each answered `job_sent` once sent; its
`{exited, Status}` is the channel's ending; and a message that fails its
check closes the channel.

Either way the command is 1 to ssh_line_command_max bytes holding no NUL
byte (erx_ssh_line_core:valid_run/1), and a command out of those bounds is
refused, as is any other request the connection does not answer itself. A
shell or an exec opens one tty or job; a second on the channel is refused.

When the shell has ended and the channel has taken the tty's last output,
the tty says how (erx_console:shell_ending/1): `{exited, Status}` becomes the
channel's `exit-status`, `{signaled, sigint}` its `exit-signal` `INT`, and
the channel closes; a job's `{exited, Status}` after its last output does
the same. The channel watches the tty's console or the job's relay, and one
that ends without saying how ends the channel as a shell that crashed does,
with exit status 1. When the client closes the channel first, this process
ends, and its end is the tty's or the job's hangup: each relay watches its
channel.
""".

-behaviour(ssh_server_channel).

-export([init/1, handle_msg/2, handle_ssh_msg/2, terminate/2, window/0]).

-include("generated/erx_abi.hrl").

%% open and job: the openers of a channel's tty and of a job's relay, erx_session_tty's
%% or a host test's stand-ins. pty: the tty a pty-req asked for, none until one does.
%% tty: none until a shell or an exec opened the tty, then its relay, which named
%% itself before the open returned. relay: none until an exec started a job, then
%% the job's relay. alias: none until a tty or a job is opened, then the alias that
%% tags how the tty's shell ended, or the job messages. watched: the
%% monitor of the tty's console or of the job's relay. Of a job's input: input, the
%% pieces not yet sent; unanswered_size, the size of the one piece sent and not yet
%% answered, or none; eof, the client's end of input, none until the client sends
%% it, pending until it is sent as job_eof, then sent.
-record(state, {open :: fun((pid(), erx_session_tty:channel(), fun((term()) -> term())) -> {ok, pid()} | {error, term()}),
                job :: fun((binary()) -> {pid(), erx_ssh_job:tag()}),
                connection :: ssh:connection_ref() | undefined,
                channel :: ssh:channel_id() | undefined,
                pty = none :: none | erx_session_tty:channel(),
                tty = none :: none | pid(),
                relay = none :: none | pid(),
                alias = none :: none | erx_ssh_job:tag(),
                watched :: reference() | undefined,
                input = [] :: [binary()],
                unanswered_size = none :: none | 1..?ERX_SSH_LINE_DATA_MAX,
                eof = none :: none | pending | sent}).

%% OTP's channel leaves the client's window to this module (window/0 of
%% ssh_server_channel, an erXos edit).
-doc false.
window() -> manual.

-doc false.
init([Open, Job]) ->
    {ok, #state{open = Open, job = Job}}.

-doc false.
handle_msg({ssh_channel_up, Channel, Connection}, State) ->
    {ok, State#state{connection = Connection, channel = Channel}};
handle_msg({tty_open, Tty}, #state{tty = Tty} = State) ->
    {ok, State};
handle_msg({tty_output, N, Bytes}, #state{connection = Connection, channel = Channel, tty = Tty} = State)
  when is_pid(Tty), is_integer(N), is_binary(Bytes) ->
    %% Once the connection is going the send fails, and the channel's close follows.
    _ = ssh_connection:send(Connection, Channel, Bytes),
    Tty ! {tty_taken, N},
    {ok, State};
%% How the tty's shell ended, tagged with the alias its Notify sends with; and a
%% job message from the job's relay, tagged with the job's alias.
handle_msg({Alias, {ended, Ending}}, #state{alias = Alias, tty = Tty} = State) when is_reference(Alias), is_pid(Tty) ->
    ended(Ending, State);
handle_msg({Alias, Message}, #state{alias = Alias, relay = Relay} = State) when is_reference(Alias), is_pid(Relay) ->
    heard(Message, State);
%% A tty that ended without a report, its console crashed, or a job's relay that
%% ended before the job's ending, ends the channel as a shell that crashed ends:
%% exit status 1.
handle_msg({'DOWN', Ref, process, _, _}, #state{watched = Ref} = State) ->
    ended({exited, 1}, State);
%% Anything else, a job message without the job's alias among it, is dropped.
handle_msg(_Message, State) ->
    {ok, State}.

-doc false.
handle_ssh_msg({ssh_cm, Connection, {pty, Channel, WantReply, {Term, Columns, Rows, _, _, _}}}, State)
  when is_list(Term), length(Term) =< ?ERX_SSH_TERM_MAX,
       is_integer(Rows), Rows >= 0, Rows =< ?ERX_CONSOLE_SIDE_MAX,
       is_integer(Columns), Columns >= 0, Columns =< ?ERX_CONSOLE_SIDE_MAX ->
    ssh_connection:reply_request(Connection, WantReply, success, Channel),
    {ok, State#state{pty = erx_ssh_line_core:tty(shell, list_to_binary(Term), Rows, Columns)}};
handle_ssh_msg({ssh_cm, Connection, {shell, Channel, WantReply}}, #state{tty = none, relay = none, pty = Pty} = State) ->
    Tty = case Pty of
              none -> erx_ssh_line_core:tty(shell, <<>>, 0, 0);
              #{} -> Pty
          end,
    open_tty(Tty, Connection, Channel, WantReply, State);
%% An exec runs rc -c Command: on the channel's tty, at the size and TERM the pty-req
%% gave, when the client asked for one, and as a job otherwise. A command out of
%% bounds is refused.
handle_ssh_msg({ssh_cm, Connection, {exec, Channel, WantReply, Command}}, #state{tty = none, relay = none, pty = Pty} = State) ->
    Run = {exec, list_to_binary(Command)},
    case {erx_ssh_line_core:valid_run(Run), Pty} of
        {true, #{}} ->
            open_tty(Pty#{run := Run}, Connection, Channel, WantReply, State);
        {true, none} ->
            open_job(Run, Connection, Channel, WantReply, State);
        {false, _} ->
            ssh_connection:reply_request(Connection, WantReply, failure, Channel),
            {stop, Channel, State}
    end;
handle_ssh_msg({ssh_cm, _Connection, {window_change, _Channel, Columns, Rows, _, _}}, #state{tty = Tty} = State)
  when is_pid(Tty), is_integer(Rows), Rows > 0, Rows =< ?ERX_CONSOLE_SIDE_MAX,
       is_integer(Columns), Columns > 0, Columns =< ?ERX_CONSOLE_SIDE_MAX ->
    Tty ! {tty_size, Rows, Columns},
    {ok, State};
%% A job's input waits in pieces, and the client's window opens as each is written.
handle_ssh_msg({ssh_cm, _Connection, {data, _Channel, 0, Data}}, #state{relay = Relay, eof = none, input = Input} = State)
  when is_pid(Relay) ->
    feed(State#state{input = Input ++ pieces(Data, ?ERX_SSH_LINE_DATA_MAX)});
handle_ssh_msg({ssh_cm, Connection, {data, Channel, 0, Data}}, #state{tty = Tty} = State) when is_pid(Tty) ->
    _ = [Tty ! {tty_input, Piece} || Piece <- pieces(Data, erx_tty_link:input_max())],
    ssh_connection:adjust_window(Connection, Channel, byte_size(Data)),
    {ok, State};
%% Data on no tty or job, extended data, and a job's data after the client's end of
%% input go nowhere.
handle_ssh_msg({ssh_cm, Connection, {data, Channel, _Type, Data}}, State) ->
    ssh_connection:adjust_window(Connection, Channel, byte_size(Data)),
    {ok, State};
handle_ssh_msg({ssh_cm, _Connection, {eof, _Channel}}, #state{relay = Relay, eof = none} = State) when is_pid(Relay) ->
    feed(State#state{eof = pending});
handle_ssh_msg({ssh_cm, _Connection, {closed, Channel}}, State) ->
    {stop, Channel, State};
handle_ssh_msg({ssh_cm, Connection, Request}, State) ->
    refuse(Connection, Request),
    {ok, State}.

-doc false.
terminate(_Reason, _State) ->
    ok.

%% Opens the channel's tty with Tty, what runs on it and its size, and answers the
%% request: the relay names itself as it starts, so its tty_open is here before any
%% data or size the client sent after the request is handled.
open_tty(Tty, Connection, Channel, WantReply, State) ->
    Alias = alias(),
    Notify = fun(Ending) -> Alias ! {Alias, {ended, Ending}} end,
    case (State#state.open)(self(), Tty, Notify) of
        {ok, Console} ->
            receive {tty_open, Relay} when is_pid(Relay) -> ok end,
            ssh_connection:reply_request(Connection, WantReply, success, Channel),
            {ok, State#state{tty = Relay, alias = Alias, watched = monitor(process, Console)}};
        {error, _} ->
            ssh_connection:reply_request(Connection, WantReply, failure, Channel),
            {stop, Channel, State}
    end.

%% Starts the job's relay for the command and answers the request.
open_job({exec, Command}, Connection, Channel, WantReply, State) ->
    {Relay, Alias} = (State#state.job)(Command),
    ssh_connection:reply_request(Connection, WantReply, success, Channel),
    {ok, State#state{relay = Relay, alias = Alias, watched = monitor(process, Relay)}}.

%% Sends the job's relay its next piece of input when none is unanswered, or, once
%% every piece is answered, the client's end of input.
feed(#state{relay = Relay, alias = Alias, unanswered_size = none, input = [Piece | Input]} = State) ->
    Relay ! {Alias, {job_input, Piece}},
    {ok, State#state{input = Input, unanswered_size = byte_size(Piece)}};
feed(#state{relay = Relay, alias = Alias, unanswered_size = none, input = [], eof = pending} = State) ->
    Relay ! {Alias, job_eof},
    {ok, State#state{eof = sent}};
feed(State) ->
    {ok, State}.

%% A job message from the relay, as erx_ssh_job_core:heard/2 takes it. A job's
%% output is sent before the next is heard, so none is unanswered when one arrives.
heard(Message, #state{connection = Connection, channel = Channel, relay = Relay, alias = Alias,
                      unanswered_size = Size} = State) ->
    case erx_ssh_job_core:heard(Message, #{input => Size =/= none, output => false}) of
        written ->
            ssh_connection:adjust_window(Connection, Channel, Size),
            feed(State#state{unanswered_size = none});
        {output, Stream, Bytes} ->
            %% Once the connection is going the send fails, and the channel's close follows.
            _ = ssh_connection:send(Connection, Channel, data_type(Stream), Bytes),
            Relay ! {Alias, job_sent},
            {ok, State};
        {ended, Status} ->
            ended({exited, Status}, State);
        close ->
            {stop, Channel, State}
    end.

%% The SSH data type of a job's stream: standard error is extended data of type 1,
%% SSH_EXTENDED_DATA_STDERR (RFC 4254, section 5.2).
data_type(stdout) -> 0;
data_type(stderr) -> 1.

%% How the tty's shell or the job ended, sent as the channel's exit-status or
%% exit-signal, and then the channel's end of output and its close.
ended(Ending, #state{connection = Connection, channel = Channel} = State) ->
    ok = ending(Connection, Channel, Ending),
    _ = ssh_connection:send_eof(Connection, Channel),
    {stop, Channel, State}.

%% The tty reports only these two shapes (erx_console:shell_ending/1), and a job
%% the first.
ending(Connection, Channel, {exited, Status}) ->
    ssh_connection:exit_status(Connection, Channel, Status);
ending(Connection, Channel, {signaled, sigint}) ->
    ssh_connection:exit_signal(Connection, Channel, "INT").

%% A request this channel does not take is refused when its client wants a reply;
%% eof, signal and env requests want none or are ignored.
refuse(Connection, Request) when is_tuple(Request), tuple_size(Request) >= 3,
                                 is_integer(element(2, Request)), is_boolean(element(3, Request)) ->
    ssh_connection:reply_request(Connection, element(3, Request), failure, element(2, Request));
refuse(_Connection, _Request) ->
    ok.

%% Data in pieces of at most Max bytes, as the tty and the job's relay take input.
pieces(Data, Max) when byte_size(Data) =< Max -> [Data || Data =/= <<>>];
pieces(Data, Max) ->
    <<Piece:Max/binary, Rest/binary>> = Data,
    [Piece | pieces(Rest, Max)].
