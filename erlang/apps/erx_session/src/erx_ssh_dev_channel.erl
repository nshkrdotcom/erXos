%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_dev_channel).
-moduledoc """
A session channel of SSH's first stage (docs/design-ssh.md, "Stages"): the
channel process of OTP's daemon that erx_ssh_dev runs in root's session,
and the master of one tty of that session, on which the command shell runs
(erx_session_tty:open_channel/3). It speaks the tty's six messages
(erx_tty_link) to the tty's relay, a process of this domain, as the SSH
domain's channel does at stage 2, so the tty, its line discipline and its
shell are the ones every session tty has: Ctrl-C reaches the shell as the
line discipline's SIGINT, and a window change is the tty's `{tty_size, Rows,
Columns}`.

What a client may ask for is an interactive session: `pty-req` gives the
tty's size and TERM, `shell` opens the tty, `window-change` resizes it and
the data it sends is the tty's input. An `exec` request is refused, the
reason on its standard error and exit status 1, and so is any other
request the connection does not answer itself. A shell opens one tty;
a second `shell` on the channel is refused.

When the shell has ended and the channel has taken the tty's last output,
the tty says how (erx_console:shell_ending/1): `{exited, Status}` becomes the
channel's `exit-status`, `{signaled, sigint}` its `exit-signal` `INT`, and
the channel closes. When the client closes the channel first, this process
ends, and its end is the tty's hangup: the relay watches its master.
""".

-behaviour(ssh_server_channel).

-export([init/1, handle_msg/2, handle_ssh_msg/2, terminate/2]).

-include("generated/erx_abi.hrl").

-define(EXEC_REFUSED, <<"exec is not supported in 0.1\r\n">>).

%% open opens a tty for a channel, erx_session_tty:open_channel/3 or a host
%% test's stand-in. pty is the tty a pty-req asked for, the default one until
%% then; tty is none until a shell opened the tty, then its relay, which named
%% itself before the open returned, and console the tty's console, watched.
-record(state, {open :: fun((pid(), erx_session_tty:channel(), fun((term()) -> term())) -> {ok, pid()} | {error, term()}),
                connection :: ssh:connection_ref() | undefined,
                channel :: ssh:channel_id() | undefined,
                pty :: erx_session_tty:channel(),
                tty = none :: none | pid(),
                console :: reference() | undefined}).

-doc false.
init([Open]) ->
    {ok, #state{open = Open, pty = erx_ssh_line_core:tty(shell, <<>>, 0, 0)}}.

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
handle_msg({?MODULE, ended, Ending}, #state{connection = Connection, channel = Channel} = State) ->
    ok = ending(Connection, Channel, Ending),
    _ = ssh_connection:send_eof(Connection, Channel),
    {stop, Channel, State};
%% A tty that ended without a report, its console crashed, ends the channel as a
%% shell that crashed ends: exit status 1.
handle_msg({'DOWN', Ref, process, _, _}, #state{console = Ref} = State) ->
    handle_msg({?MODULE, ended, {exited, 1}}, State);
handle_msg(_Message, State) ->
    {ok, State}.

-doc false.
handle_ssh_msg({ssh_cm, Connection, {pty, Channel, WantReply, {Term, Columns, Rows, _, _, _}}}, State)
  when is_list(Term), length(Term) =< ?ERX_SSH_TERM_MAX,
       is_integer(Rows), Rows >= 0, Rows =< ?ERX_CONSOLE_SIDE_MAX,
       is_integer(Columns), Columns >= 0, Columns =< ?ERX_CONSOLE_SIDE_MAX ->
    ssh_connection:reply_request(Connection, WantReply, success, Channel),
    {ok, State#state{pty = erx_ssh_line_core:tty(shell, list_to_binary(Term), Rows, Columns)}};
handle_ssh_msg({ssh_cm, Connection, {shell, Channel, WantReply}}, #state{tty = none} = State) ->
    Self = self(),
    Notify = fun(Ending) -> Self ! {?MODULE, ended, Ending} end,
    case (State#state.open)(Self, State#state.pty, Notify) of
        {ok, Console} ->
            %% The relay names itself as it starts, so its tty_open is here before any
            %% data or size the client sent after the shell request is handled.
            receive {tty_open, Tty} when is_pid(Tty) -> ok end,
            ssh_connection:reply_request(Connection, WantReply, success, Channel),
            {ok, State#state{tty = Tty, console = monitor(process, Console)}};
        {error, _} ->
            ssh_connection:reply_request(Connection, WantReply, failure, Channel),
            {stop, Channel, State}
    end;
handle_ssh_msg({ssh_cm, Connection, {exec, Channel, WantReply, _Command}}, #state{tty = none} = State) ->
    ssh_connection:reply_request(Connection, WantReply, success, Channel),
    _ = ssh_connection:send(Connection, Channel, 1, ?EXEC_REFUSED),
    ok = ssh_connection:exit_status(Connection, Channel, 1),
    _ = ssh_connection:send_eof(Connection, Channel),
    {stop, Channel, State};
handle_ssh_msg({ssh_cm, _Connection, {window_change, _Channel, Columns, Rows, _, _}}, #state{tty = Tty} = State)
  when is_pid(Tty), is_integer(Rows), Rows > 0, Rows =< ?ERX_CONSOLE_SIDE_MAX,
       is_integer(Columns), Columns > 0, Columns =< ?ERX_CONSOLE_SIDE_MAX ->
    Tty ! {tty_size, Rows, Columns},
    {ok, State};
handle_ssh_msg({ssh_cm, Connection, {data, Channel, 0, Data}}, #state{tty = Tty} = State) ->
    _ = [Tty ! {tty_input, Piece} || is_pid(Tty), Piece <- pieces(Data, erx_tty_link:input_max())],
    ssh_connection:adjust_window(Connection, Channel, byte_size(Data)),
    {ok, State};
handle_ssh_msg({ssh_cm, Connection, {data, Channel, _Stderr, Data}}, State) ->
    ssh_connection:adjust_window(Connection, Channel, byte_size(Data)),
    {ok, State};
handle_ssh_msg({ssh_cm, _Connection, {closed, Channel}}, State) ->
    {stop, Channel, State};
handle_ssh_msg({ssh_cm, Connection, Request}, State) ->
    refuse(Connection, Request),
    {ok, State}.

-doc false.
terminate(_Reason, _State) ->
    ok.

%% How the tty's shell ended, as the channel's exit-status or exit-signal: the
%% tty reports only these two shapes (erx_console:shell_ending/1).
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

%% Data in pieces of at most Max bytes, as the tty takes its input.
pieces(Data, Max) when byte_size(Data) =< Max -> [Data || Data =/= <<>>];
pieces(Data, Max) ->
    <<Piece:Max/binary, Rest/binary>> = Data,
    [Piece | pieces(Rest, Max)].

