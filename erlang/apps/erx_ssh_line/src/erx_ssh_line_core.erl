%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_line_core).
-moduledoc """
The decisions of a session's line to the SSH domain (erx_ssh_line;
docs/design-ssh.md, "Sessions, ttys and shells"), pure: whom the line
serves, which requests it takes and how many channels it holds open.

The line serves one peer, the SSH domain the system domain exported it to,
and none before then (exported/2). A request from the peer is untrusted, so
request/3 checks its whole shape before anything acts on it, and answers
`{error, badarg}` for any shape but the one below, and for a channel that is
no process of the peer's: a channel of a third domain would make the session
send a tty's bytes there. Past ?MAX_CHANNELS open channels, `max_channels`,
it answers `{error, limited}`.

* `{open_tty, Channel, Run, Term, Rows, Columns}`: Channel a pid of the
  peer's, Run `shell` or `{exec, Command}` with Command a binary of 1 to
  ?MAX_COMMAND bytes holding no NUL, Term a binary of at most ?MAX_TERM
  bytes, and Rows and Columns integers from 0, which `pty-req` allows, to
  ?MAX_SIDE.

The tty opens at Rows by Columns, a side of zero taken as 24 rows or 80
columns, and its shell's TERM is Term when abi/terminal.txt lists it and
that file's default otherwise (term/1), as design-ssh.md has it, so
no byte of the peer's reaches the shell's variables. A channel counts from
its open (opened/3)
until its tty ends (ended/2), and the tty's report of how its shell ended
goes to that channel alone (channel/2).
""".

-export([new/0, exported/2, peer/1, request/3, term/1, opened/3, ended/2, report/3]).
-export_type([core/0]).

-include("generated/erx_abi.hrl").

%% `max_channels`: the channels one connection may hold open (design-ssh.md).
-define(MAX_CHANNELS, 10).
%% An exec request's command, at most 32 KiB, as design-ssh.md bounds it.
-define(MAX_COMMAND, 32768).
%% A TERM name; terminfo's names are short.
-define(MAX_TERM, 64).
%% A side of the window, as the tty bounds it (erx_tty_link).
-define(MAX_SIDE, 65535).
%% A pseudo-terminal's size when pty-req gives a side as zero.
-define(DEFAULT_ROWS, 24).
-define(DEFAULT_COLUMNS, 80).

%% The peer, none until the line is exported, and the open channels' ttys, each
%% by the process that ends with it, the tty's console.
-opaque core() :: #{peer := pos_integer() | none, ttys := #{pid() => pid()}}.

-doc "A line that serves no one and holds no channel.".
-spec new() -> core().
new() -> #{peer => none, ttys => #{}}.

-doc "The line once exported to Peer, which it serves from then on.".
-spec exported(pos_integer(), core()) -> core().
exported(Peer, Core) when is_integer(Peer), Peer > 0 -> Core#{peer := Peer}.

-doc "The domain the line serves, or none.".
-spec peer(core()) -> pos_integer() | none.
peer(#{peer := Peer}) -> Peer.

-doc """
What the line does with Request from its peer, given Owner, the domain of a
pid: open a tty on the channel, or answer the error.
""".
-spec request(term(), fun((pid()) -> non_neg_integer()), core()) ->
          {open_tty, pid(), erx_session_tty:channel()} | {error, limited | badarg}.
request({open_tty, Channel, Run, Term, Rows, Columns}, Owner, #{peer := Peer, ttys := Ttys})
  when is_pid(Channel), is_binary(Term), byte_size(Term) =< ?MAX_TERM,
       is_integer(Rows), Rows >= 0, Rows =< ?MAX_SIDE,
       is_integer(Columns), Columns >= 0, Columns =< ?MAX_SIDE ->
    case {valid_run(Run), Owner(Channel) =:= Peer} of
        {true, true} when map_size(Ttys) >= ?MAX_CHANNELS -> {error, limited};
        {true, true} ->
            Size = {side(Rows, ?DEFAULT_ROWS), side(Columns, ?DEFAULT_COLUMNS)},
            {open_tty, Channel, #{run => Run, size => Size, vars => #{<<"TERM">> => [term(Term)]}}};
        _ -> {error, badarg}
    end;
request(_Request, _Owner, _Core) ->
    {error, badarg}.

-doc """
The shell's TERM for a channel that asked for Term: Term itself when
abi/terminal.txt lists it, else that file's default.
""".
-spec term(binary()) -> binary().
term(Term) ->
    case lists:member(Term, erx_text_tables:term_types()) of
        true -> Term;
        false -> erx_text_tables:term_default()
    end.

side(0, Default) -> Default;
side(Side, _Default) -> Side.

valid_run(shell) -> true;
valid_run({exec, Command}) when is_binary(Command), byte_size(Command) >= 1, byte_size(Command) =< ?MAX_COMMAND ->
    binary:match(Command, <<0>>) =:= nomatch;
valid_run(_Run) -> false.

-doc "The line once Channel's tty, which ends with Tty, is open.".
-spec opened(pid(), pid(), core()) -> core().
opened(Tty, Channel, #{ttys := Ttys} = Core) -> Core#{ttys := Ttys#{Tty => Channel}}.

-doc "The line once the tty Tty has ended; a pid it holds no tty for changes nothing.".
-spec ended(pid(), core()) -> core().
ended(Tty, #{ttys := Ttys} = Core) -> Core#{ttys := maps:remove(Tty, Ttys)}.

-doc """
Where the tty Tty's report that its shell ended Ending goes: to the channel
whose tty it is, `{send, Channel}`, for an ending the channel hears, which is
`{exited, Status}` with Status 0 to 255 or `{signaled, Signal}` with Signal a
member of ssh_line_signal (abi/services/ssh.txt); `drop` for any other ending
and for a pid the line holds no tty for.
""".
-spec report(pid(), term(), core()) -> {send, pid()} | drop.
report(Tty, Ending, #{ttys := Ttys}) ->
    case {Ttys, heard(Ending)} of
        {#{Tty := Channel}, true} -> {send, Channel};
        _Other -> drop
    end.

heard({exited, Status}) -> is_integer(Status) andalso Status >= 0 andalso Status =< 255;
heard({signaled, Signal}) -> lists:keymember(Signal, 1, ?ERX_SSH_LINE_SIGNAL_MEMBERS);
heard(_Ending) -> false.
