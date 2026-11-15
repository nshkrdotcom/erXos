%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tty).
-moduledoc """
The line discipline (docs/design-live.md, "The tty"): the decisions of one
tty as a pure state machine. Each call takes the tty and one event and
returns the next tty and what to do, as a list of actions in order. The
process that owns the tty, the terminal relay, carries the actions out and
owns the timers, so time reaches the machine only as timer/2.

Behaviour follows FreeBSD 15.1's line discipline, sys/kern/tty_ttydisc.c,
redesigned as a fold over the bytes rather than translated: a received byte
goes through ttydisc_rint's steps in its order (wake on any key, strip,
signals, start and stop, CR and NL mapping, line editing, storing, echo),
and echo and output share ttydisc_echo_force's and ttydisc_write_oproc's
rendering and the output column they keep.

The input the tty holds is two binaries: `ready`, the bytes a read can
take, and `line`, the cooked line being edited. A byte in raw mode goes
straight to `ready`; in cooked mode a line moves to `ready` at its end, a
newline, VEOF or VEOL. Together they hold at most ?MAX_INPUT bytes, and a
cooked line keeps one byte free for its end, so a line holds at most 4,095
bytes and its end. A byte that does not fit is dropped and counted, with a
bell when IMAXBEL is set, as ttydisc_rint drops a byte when nothing can be
read (tty_ttydisc.c:1220-1236); the relay cannot hold back its master, so
it drops in every case. One call echoes at most ?MAX_ECHO bytes and drops
the rest, as FreeBSD drops echo its full output queue cannot take, so a
chunk of VREPRINT keys cannot make megabytes of echo.

A reader waits before it reads. read_wait/2 and poll_wait/2 register a
waiter for an open, and the tty reports `{ready, Open}` once, when the
waiter's condition holds: a complete line in cooked mode; in raw mode, for
a read, what VMIN and VTIME ask for by POSIX's four cases, and for a poll
one byte, as FreeBSD's poll counts the canonicalized bytes (ttydisc.h:72).
read/3 then answers at once, with bytes, with no bytes for an end of file,
a timed-out raw read or a hung-up tty, or `eagain` when another reader took
the bytes first. A timer is named by `timer()`, which the tty makes fresh
for every start, so a late timer of a cancelled wait does nothing.

termios is a map of flag lists and characters, checked whole by set/2: a
flag outside this module's tables, a missing or extra key, or a value out
of range fails with `einval`. The numeric encoding of a C program's struct
belongs to the program protocol, not to this module.

What it does not do, each recorded in TODO.md: VLNEXT, VDISCARD and
FLUSHO, ECHOPRT, and the width of a double-width character on erase. Its
other characters and flags behave as FreeBSD's do; IGNBRK, BRKINT, IGNPAR,
INPCK, IXOFF, the control flags and the speeds are kept and returned, and
have nothing to act on, since a master reports no breaks or parity errors
and takes no flow control.
""".

-export([new/0, termios/1, set/2, winsize/1, size/3, input/2, output/3,
         read_wait/2, poll_wait/2, cancel/2, timer/2, read/3, status/3,
         hangup/1, waiting/1, dropped/1]).
-export_type([tty/0, termios/0, open/0, timer/0, action/0]).

%% Bytes held: complete lines unread and the line being edited.
-define(MAX_INPUT, 4096).
%% FreeBSD's _POSIX_VDISABLE (sys/sys/_termios.h:77).
-define(VDISABLE, 16#ff).
-define(MAX_SPEED, 16#ffffffff).
-define(MAX_SIDE, 65535).
%% FreeBSD prints a status line only with this much room (sys/kern/tty.c:2057-2062).
-define(STATUS_ROOM, 256).
%% Erlang has no escape for BEL.
%% The most one input/2 echoes; FreeBSD drops echo that finds its output
%% queue full (ttyoutq_write_nofrag), and this bounds what a chunk can make.
-define(MAX_ECHO, 16384).
-define(BELL, 7).

%% The termios map and its tables, every flag and character a termios may
%% hold, are the ABI file's termios table (abi/termios.txt), which
%% erx_abi_termios gives: FreeBSD's supported sets (sys/kern/tty.c:88-96)
%% less those named in the moduledoc.
-type termios() :: erx_abi_termios:termios().
-doc "Whatever names a reader: the relay's open.".
-type open() :: term().
-doc "A read's timer: the open it times and a serial no other timer has.".
-type timer() :: {open(), non_neg_integer()}.
-type action() :: {echo, binary()}               % bytes for the master
                | {signal, sigint | sigquit | sigtstp} % for the foreground group
                | info                           % VSTATUS: the foreground job's status
                | flush_output                   % drop output not yet at the master
                | stop_output | start_output     % IXON's VSTOP and VSTART
                | {ready, open()}                % the waiter may read now
                | {timer_start, timer(), pos_integer()} % milliseconds
                | {timer_cancel, timer()}
                | winch.                         % the window size changed
-type waiter() :: {read, timer() | none} | poll.

-record(tty, {
    termios :: termios(),
    size = {24, 80} :: {1..?MAX_SIDE, 1..?MAX_SIDE},
    ready = <<>> :: binary(),
    line = <<>> :: binary(),
    %% The output column, the column after the last write, and how much of
    %% the line was echoed before it (FreeBSD's t_column, t_writepos and
    %% reprint position), which erase and the status line read.
    column = 0 :: non_neg_integer(),
    writepos = 0 :: non_neg_integer(),
    reprintpos = 0 :: non_neg_integer(),
    stopped = false :: boolean(),
    hungup = false :: boolean(),
    waiters = #{} :: #{open() => waiter()},
    %% Opens whose read timer ended, so their next raw read with VMIN 0
    %% returns no bytes rather than eagain.
    expired = [] :: [open()],
    serial = 0 :: non_neg_integer(),
    received = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer(),
    %% The echo left to the input/2 under way, 0 between calls.
    echo_room = 0 :: integer()
}).

-opaque tty() :: #tty{}.

%%% The tty and its termios

-doc """
A new tty, cooked, with FreeBSD's default termios (sys/sys/ttydefaults.h:46-52,
:102-104) and a 24-by-80 window until the master reports one.
""".
-spec new() -> tty().
new() ->
    #tty{termios = #{iflag => [brkint, icrnl, imaxbel, iutf8, ixany, ixon],
                     oflag => [onlcr, opost],
                     cflag => [cread, hupcl],
                     lflag => [echo, echoctl, echoe, echoke, icanon, iexten,
                               isig],
                     csize => 8,
                     cc => #{veof => $\^D, veol => ?VDISABLE,
                             veol2 => ?VDISABLE, verase => $\^?,
                             vwerase => $\^W, vkill => $\^U,
                             vreprint => $\^R, verase2 => $\^H,
                             vintr => $\^C, vquit => $\^\, vsusp => $\^Z,
                             vdsusp => $\^Y, vstart => $\^Q, vstop => $\^S,
                             vlnext => $\^V, vdiscard => $\^O, vmin => 1,
                             vtime => 0, vstatus => $\^T},
                     ispeed => 9600, ospeed => 9600}}.

-doc "The tty's termios, for tcgetattr.".
-spec termios(tty()) -> termios().
termios(#tty{termios = Termios}) -> Termios.

-doc """
Takes a new termios, for tcsetattr, checked whole: anything but a termios
of this module's tables fails with `einval` and changes nothing. An input
speed of 0 takes the output speed, as POSIX and FreeBSD have it
(sys/kern/tty.c:1757-1758). A change of ICANON, VEOF or VEOL moves what the
new mode counts as complete into `ready` (tty.c:1803-1812), and every
waiter waits again under the new rules.
""".
-spec set(term(), tty()) -> {ok, [action()], tty()} | {error, einval}.
set(Candidate, Tty) ->
    try checked(Candidate) of
        Termios -> retermios(Termios, Tty)
    catch
        throw:einval -> {error, einval}
    end.

-doc "The window size the master last reported, as {Rows, Columns}.".
-spec winsize(tty()) -> {1..?MAX_SIDE, 1..?MAX_SIDE}.
winsize(#tty{size = Size}) -> Size.

-doc """
Takes a window size the master reports, each side from 1 to 65,535, and
refuses any other. It returns `winch` only when the size changes, after
`start_output` when output was stopped, since SIGWINCH starts it as every
signal does on FreeBSD (sys/kern/tty.c:1645-1648).
""".
-spec size(term(), term(), tty()) -> {ok, [action()], tty()} | {error, einval}.
size(Rows, Columns, #tty{size = Size} = Tty)
  when is_integer(Rows), Rows >= 1, Rows =< ?MAX_SIDE,
       is_integer(Columns), Columns >= 1, Columns =< ?MAX_SIDE ->
    case Size of
        {Rows, Columns} -> {ok, [], Tty};
        _ ->
            {Started, Tty1} = start([], Tty),
            {ok, lists:reverse([winch | Started]), Tty1#tty{size = {Rows, Columns}}}
    end;
size(_, _, _) ->
    {error, einval}.

-doc """
The master hung up. Every waiter is ready, and from now on every read that
finds no bytes returns none, an end of file.
""".
-spec hangup(tty()) -> {[action()], tty()}.
hangup(Tty) ->
    rewait(Tty#tty{hungup = true}).

-doc "The bytes a read can take now, FreeBSD's FIONREAD (ttydisc_bytesavail).".
-spec waiting(tty()) -> non_neg_integer().
waiting(#tty{ready = Ready} = Tty) ->
    case on(icanon, Tty) of
        false -> byte_size(Ready);
        true ->
            case line_end(Tty) of
                none -> 0;
                {Length, true} -> Length - 1;
                {Length, false} -> Length
            end
    end.

-doc "How many received bytes did not fit and were dropped.".
-spec dropped(tty()) -> non_neg_integer().
dropped(#tty{dropped = Dropped}) -> Dropped.

checked(#{iflag := I, oflag := O, cflag := C, lflag := L, csize := Size,
          cc := Chars, ispeed := ISpeed, ospeed := OSpeed} = Map)
  when map_size(Map) =:= 8, is_integer(Size), Size >= 5, Size =< 8 ->
    Out = speed(OSpeed),
    In = case speed(ISpeed) of
             0 -> Out;
             Speed -> Speed
         end,
    #{iflag => flags(I, iflag), oflag => flags(O, oflag),
      cflag => flags(C, cflag), lflag => flags(L, lflag),
      csize => Size, cc => chars(Chars), ispeed => In, ospeed => Out};
checked(_) ->
    throw(einval).

%% The flags of a word of termios, each one the table names.
flags(List, Word) -> flags(List, erx_abi_termios:flags(Word), []).

flags([], _, Acc) ->
    lists:usort(Acc);
flags([Flag | Rest], Table, Acc) ->
    case lists:member(Flag, Table) of
        true -> flags(Rest, Table, [Flag | Acc]);
        false -> throw(einval)
    end;
flags(_, _, _) ->
    throw(einval).

chars(Chars) when is_map(Chars) ->
    Names = erx_abi_termios:chars(),
    map_size(Chars) =:= length(Names) orelse throw(einval),
    lists:foreach(fun(Name) ->
                          case Chars of
                              #{Name := Value} when is_integer(Value),
                                                    Value >= 0,
                                                    Value =< 255 -> ok;
                              _ -> throw(einval)
                          end
                  end, Names),
    Chars;
chars(_) ->
    throw(einval).

speed(Speed) when is_integer(Speed), Speed >= 0, Speed =< ?MAX_SPEED -> Speed;
speed(_) -> throw(einval).

retermios(New, #tty{termios = Old} = Tty0) ->
    Tty1 = Tty0#tty{termios = New, expired = []},
    Ends = fun(#{lflag := L, cc := #{veof := Eof, veol := Eol}}) ->
                   {lists:member(icanon, L), Eof, Eol}
           end,
    Tty2 = case Ends(Old) =/= Ends(New) of
               true -> canonicalize(Tty1);
               false -> Tty1
           end,
    {Actions, Tty3} = rewait(Tty2),
    {ok, Actions, Tty3}.

%% Moves into `ready` what the mode counts as complete: in raw mode the whole
%% line, in cooked mode the line up to its last end (ttydisc_canonicalize).
canonicalize(#tty{ready = Ready, line = Line, reprintpos = Shown} = Tty) ->
    Cut = case on(icanon, Tty) of
              false -> byte_size(Line);
              true -> last_end(Line, Tty)
          end,
    <<Done:Cut/binary, Rest/binary>> = Line,
    Tty#tty{ready = <<Ready/binary, Done/binary>>, line = Rest,
            reprintpos = max(0, Shown - Cut)}.

last_end(Line, Tty) ->
    {_, Cut} = lists:foldl(fun(Byte, {Position, Cut}) ->
                                   Next = Position + 1,
                                   case is_end(Byte, Tty) of
                                       true -> {Next, Next};
                                       false -> {Next, Cut}
                                   end
                           end, {0, 0}, binary_to_list(Line)),
    Cut.

%%% Input

-doc """
Bytes from the master. Each goes through FreeBSD's steps in ttydisc_rint's
order (tty_ttydisc.c:1012-1250); then every waiter whose condition now
holds is ready, and a raw read waiting with VMIN and VTIME above 0 starts
its timer at its first byte and keeps that deadline.
""".
-spec input(binary(), tty()) -> {[action()], tty()}.
input(Bytes, #tty{received = Before} = Tty0) when is_binary(Bytes) ->
    {Keyed, Tty1} = lists:foldl(fun key/2, {[], Tty0#tty{echo_room = ?MAX_ECHO}},
                                binary_to_list(Bytes)),
    Arrived = Tty1#tty.received > Before,
    {Settled, Tty2} = settle(Arrived, Tty1#tty{echo_room = 0}),
    {merge(lists:reverse(Keyed)) ++ Settled, Tty2}.

%% Actions are gathered newest first, and merge/1 joins neighbouring echoes.
key(Byte, {Actions0, Tty0}) ->
    {Actions, Tty} = case on(ixany, Tty0) andalso Tty0#tty.stopped of
                         true -> {[start_output | Actions0],
                                  Tty0#tty{stopped = false}};
                         false -> {Actions0, Tty0}
                     end,
    Char = case on(istrip, Tty) of
               true -> Byte band 16#7f;
               false -> Byte
           end,
    signal_key(Char, Actions, Tty).

signal_key(Char, Actions, Tty) ->
    case on(isig, Tty) andalso signal_of(Char, Tty) of
        info ->
            {Started, Tty1} = start(Actions, Tty),
            {[info | Started], Tty1};
        {signal, _} = Signal ->
            {Started, Tty0} = start(Actions, Tty),
            {Flushed, Tty1} = flush(Started, Tty0),
            {Echoed, Tty2} = echo(Char, Flushed, Tty1),
            {[Signal | Echoed], Tty2};
        _ ->
            flow_key(Char, Actions, Tty)
    end.

%% VSTATUS needs ICANON and IEXTEN as well as ISIG (tty_ttydisc.c:1101-1106).
signal_of(Char, Tty) ->
    case on(icanon, Tty) andalso on(iexten, Tty) andalso
        is_char(vstatus, Char, Tty) of
        true ->
            info;
        false ->
            Keys = [{vintr, sigint}, {vquit, sigquit}, {vsusp, sigtstp}],
            case [{signal, Signal} || {Name, Signal} <- Keys,
                                      is_char(Name, Char, Tty)] of
                [First | _] -> First;
                [] -> none
            end
    end.

%% A signal from a key starts stopped output, as FreeBSD's tty_signal_pgrp
%% does (sys/kern/tty.c:1538-1540).
start(Actions, #tty{stopped = true} = Tty) ->
    {[start_output | Actions], Tty#tty{stopped = false}};
start(Actions, Tty) ->
    {Actions, Tty}.

flush(Actions, Tty) ->
    case on(noflsh, Tty) of
        true -> {Actions, Tty};
        false -> {[flush_output | Actions],
                  Tty#tty{ready = <<>>, line = <<>>, reprintpos = 0}}
    end.

%% IXON: VSTOP stops output and VSTART starts it; with both the same
%% character, it toggles (tty_ttydisc.c:1140-1162).
flow_key(Char, Actions, #tty{stopped = Stopped} = Tty) ->
    Stop = on(ixon, Tty) andalso is_char(vstop, Char, Tty),
    Start = on(ixon, Tty) andalso is_char(vstart, Char, Tty),
    if
        Stop, not Stopped -> {[stop_output | Actions], Tty#tty{stopped = true}};
        Start, Stopped -> {[start_output | Actions], Tty#tty{stopped = false}};
        Stop; Start -> {Actions, Tty};
        true -> map_key(Char, Actions, Tty)
    end.

map_key($\r, Actions, Tty) ->
    case {on(igncr, Tty), on(icrnl, Tty)} of
        {true, _} -> {Actions, Tty};
        {false, true} -> edit_key($\n, Actions, Tty);
        {false, false} -> edit_key($\r, Actions, Tty)
    end;
map_key($\n, Actions, Tty) ->
    case on(inlcr, Tty) of
        true -> edit_key($\r, Actions, Tty);
        false -> edit_key($\n, Actions, Tty)
    end;
map_key(Char, Actions, Tty) ->
    edit_key(Char, Actions, Tty).

edit_key(Char, Actions, Tty) ->
    Cooked = on(icanon, Tty),
    Extended = Cooked andalso on(iexten, Tty),
    Edits = [{Cooked, verase, erase}, {Cooked, verase2, erase},
             {Cooked, vkill, kill}, {Extended, vwerase, word},
             {Extended, vreprint, reprint}],
    case [Edit || {true, Name, Edit} <- Edits, is_char(Name, Char, Tty)] of
        [erase | _] -> rub_char(Actions, Tty);
        [kill | _] -> rub_line(Actions, Tty);
        [word | _] -> rub_word(Actions, Tty);
        [reprint | _] -> reprint(Actions, Tty);
        [] -> store(Char, Actions, Tty)
    end.

%% PARMRK marks a received 0xff by doubling it (tty_ttydisc.c:1195-1200).
store(Char, Actions, #tty{ready = Ready, line = Line} = Tty) ->
    Bytes = case on(parmrk, Tty) andalso Char =:= 16#ff of
                true -> <<16#ff, 16#ff>>;
                false -> <<Char>>
            end,
    Cooked = on(icanon, Tty),
    End = Cooked andalso is_end(Char, Tty),
    Reserve = case Cooked andalso not End of
                  true -> 1;
                  false -> 0
              end,
    Held = byte_size(Ready) + byte_size(Line) + byte_size(Bytes) + Reserve,
    Received = Tty#tty.received + byte_size(Bytes),
    if
        Held > ?MAX_INPUT ->
            full(Actions, Tty);
        not Cooked ->
            echo(Char, Actions, Tty#tty{ready = <<Ready/binary, Bytes/binary>>,
                                        received = Received});
        End ->
            echo(Char, Actions,
                 Tty#tty{ready = <<Ready/binary, Line/binary, Bytes/binary>>,
                         line = <<>>, reprintpos = 0, received = Received});
        true ->
            echo(Char, Actions, Tty#tty{line = <<Line/binary, Bytes/binary>>,
                                        received = Received})
    end.

full(Actions, #tty{dropped = Dropped} = Tty) ->
    Bell = case on(imaxbel, Tty) of
               true -> [{echo, <<?BELL>>}];
               false -> []
           end,
    {Bell ++ Actions, Tty#tty{dropped = Dropped + 1}}.

%%% Line editing (tty_ttydisc.c:833-1010)

rub_char(Actions, Tty) ->
    {_, Rubbed, Tty1} = rub(Actions, Tty),
    {Rubbed, Tty1}.

rub_line(Actions, Tty) ->
    case rub(Actions, Tty) of
        {empty, Rubbed, Tty1} -> {Rubbed, Tty1};
        {ok, Rubbed, Tty1} -> rub_line(Rubbed, Tty1)
    end.

%% Whitespace first, then the word; with ALTWERASE a word also ends where
%% letters and digits meet other characters.
rub_word(Actions, Tty) ->
    case last(Tty) of
        none ->
            {Actions, Tty};
        Char ->
            case white(Char) of
                true ->
                    {ok, Rubbed, Tty1} = rub(Actions, Tty),
                    rub_word(Rubbed, Tty1);
                false ->
                    rub_word(alnum(Char), Actions, Tty)
            end
    end.

rub_word(Alnum, Actions, Tty) ->
    {_, Rubbed, Tty1} = rub(Actions, Tty),
    case last(Tty1) of
        none ->
            {Rubbed, Tty1};
        Char ->
            case white(Char) orelse
                (on(altwerase, Tty1) andalso alnum(Char) =/= Alnum) of
                true -> {Rubbed, Tty1};
                false -> rub_word(Alnum, Rubbed, Tty1)
            end
    end.

%% Removes the last character of the line and, with ECHO, from the screen:
%% by retyping the line when output has been written over it since, by
%% ECHOE's visual erase, or else by echoing VERASE.
rub(Actions, #tty{line = <<>>} = Tty) ->
    {empty, Actions, Tty};
rub(Actions, #tty{line = Line} = Tty0) ->
    Keep = byte_size(Line) - 1,
    <<Rest:Keep/binary, Char>> = Line,
    Tty = shorten(Rest, Tty0),
    Echo = on(echo, Tty),
    Covered = Tty#tty.writepos >= Tty#tty.column,
    if
        not Echo ->
            {ok, Actions, Tty};
        Covered ->
            {Retyped, Tty1} = reprint(Actions, Tty),
            {ok, Retyped, Tty1};
        true ->
            {Erased, Tty1} = erase_shown(Char, Actions, Tty),
            {ok, Erased, Tty1}
    end.

erase_shown(Char, Actions, Tty) ->
    case on(echoe, Tty) of
        false -> echo(char(verase, Tty), Actions, Tty);
        true -> erase_visually(Char, Actions, Tty)
    end.

erase_visually(Char, Actions, Tty) ->
    Utf8 = on(iutf8, Tty) andalso Char >= 16#80,
    case caret(Char) of
        true ->
            case on(echoctl, Tty) of
                true -> {[{echo, <<"\b\b  \b\b">>} | Actions], back(2, Tty)};
                false -> {Actions, Tty}
            end;
        false when Char =:= $\s ->
            {[{echo, <<$\b>>} | Actions], back(1, Tty)};
        false when Char =:= $\t ->
            %% The tab's width is what the line before it leaves to the
            %% column, within 1 to 8.
            Before = line_width(Tty),
            Width = case Before >= Tty#tty.column of
                        true -> 1;
                        false -> min(8, Tty#tty.column - Before)
                    end,
            {[{echo, binary:copy(<<$\b>>, Width)} | Actions],
             Tty#tty{column = Before}};
        false when Utf8 ->
            %% The rest of a UTF-8 character goes with its last byte.
            Line = Tty#tty.line,
            More = utf8_tail(<<Line/binary, Char>>) - 1,
            Keep = byte_size(Line) - More,
            <<Rest:Keep/binary, _/binary>> = Line,
            {[{echo, <<"\b \b">>} | Actions], back(1, shorten(Rest, Tty))};
        false ->
            {[{echo, <<"\b \b">>} | Actions], back(1, Tty)}
    end.

%% The length of the valid UTF-8 character that ends Bytes, else 1.
utf8_tail(Bytes) ->
    Size = byte_size(Bytes),
    case [N || N <- [2, 3, 4], N =< Size,
               one_character(binary:part(Bytes, Size - N, N))] of
        [N] -> N;
        [] -> 1
    end.

one_character(<<_/utf8>>) -> true;
one_character(_) -> false.

%% VREPRINT and a newline, then the line again (ttydisc_reprint); nothing
%% once the echo room is spent, so a run of them costs no more than its bytes.
reprint(Actions, #tty{echo_room = Room} = Tty) when Room =< 0 ->
    {Actions, Tty};
reprint(Actions, Tty) ->
    {Keyed, Tty1} = case char(vreprint, Tty) of
                        ?VDISABLE -> {Actions, Tty};
                        Reprint -> echo(Reprint, Actions, Tty)
                    end,
    {Ended, Tty2} = echo($\n, Keyed, Tty1),
    lists:foldl(fun(Char, {Acc, T}) -> echo(Char, Acc, T) end,
                {Ended, Tty2#tty{reprintpos = 0}},
                binary_to_list(Tty2#tty.line)).

%% Where the column was before the line's last character: the column of
%% the last write plus the width of what was echoed since.
line_width(#tty{line = Line, reprintpos = Shown, writepos = Start} = Tty) ->
    <<_:Shown/binary, Echoed/binary>> = Line,
    Caret = case on(echoctl, Tty) of
                true -> 2;
                false -> 0
            end,
    lists:foldl(fun($\t, Width) -> Width + 8 - Width rem 8;
                   (Char, Width) ->
                        case caret(Char) of
                            true -> Width + Caret;
                            false -> Width + 1
                        end
                end, Start, binary_to_list(Echoed)).

shorten(Rest, #tty{reprintpos = Shown} = Tty) ->
    Tty#tty{line = Rest, reprintpos = min(Shown, byte_size(Rest))}.

back(Width, #tty{column = Column} = Tty) ->
    Tty#tty{column = max(0, Column - Width)}.

last(#tty{line = <<>>}) -> none;
last(#tty{line = Line}) -> binary:last(Line).

white(Char) -> Char =:= $\s orelse Char =:= $\t.

alnum(Char) ->
    (Char >= $0 andalso Char =< $9) orelse (Char >= $a andalso Char =< $z)
        orelse (Char >= $A andalso Char =< $Z).

%%% Echo and output rendering (tty_ttydisc.c:452-536, :725-776)

%% ECHO echoes every byte; ECHONL alone echoes a newline.
echo(_Char, Actions, #tty{echo_room = Room} = Tty) when Room =< 0 ->
    {Actions, Tty};
echo(Char, Actions, Tty) ->
    case on(echo, Tty) orelse (Char =:= $\n andalso on(echonl, Tty)) of
        true ->
            {Bytes, Tty1} = render(Char, Tty),
            Room = Tty1#tty.echo_room - byte_size(Bytes),
            {[{echo, Bytes} | Actions], Tty1#tty{echo_room = Room}};
        false ->
            {Actions, Tty}
    end.

%% One byte for the screen: OPOST's processing for backspace, tab, newline
%% and carriage return; ECHOCTL's caret notation for another control
%% character, with VEOF backed over; anything else as it is.
render(Char, Tty) ->
    Post = on(opost, Tty) andalso lists:member(Char, [$\b, $\t, $\n, $\r]),
    Caret = on(echoctl, Tty) andalso caret(Char),
    if
        Post -> post(Char, Tty);
        Caret -> caret_notation(Char, Tty);
        true -> {<<Char>>, forward(1, Tty)}
    end.

caret(Char) ->
    Char =:= 16#7f orelse (Char < 16#20 andalso Char =/= $\t andalso Char =/= $\n).

caret_notation(Char, Tty) ->
    Letter = case Char of
                 16#7f -> $?;
                 _ -> Char + $A - 1
             end,
    case is_char(veof, Char, Tty) of
        true -> {<<$^, Letter, $\b, $\b>>, Tty};
        false -> {<<$^, Letter>>, forward(2, Tty)}
    end.

%% OPOST's processing of a control character.
post($\^D, Tty) ->
    case on(onoeot, Tty) of
        true -> {<<>>, Tty};
        false -> {<<$\^D>>, Tty}
    end;
post($\b, Tty) ->
    {<<$\b>>, back(1, Tty)};
post($\t, #tty{column = Column} = Tty) ->
    Width = 8 - Column rem 8,
    Bytes = case on(tab3, Tty) of
                true -> binary:copy(<<$\s>>, Width);
                false -> <<$\t>>
            end,
    {Bytes, Tty#tty{column = Column + Width}};
post($\n, Tty) ->
    Bytes = case on(onlcr, Tty) of
                true -> <<"\r\n">>;
                false -> <<"\n">>
            end,
    case on(onlcr, Tty) orelse on(onlret, Tty) of
        true -> {Bytes, line_start(Tty)};
        false -> {Bytes, Tty}
    end;
post($\r, #tty{column = Column} = Tty) ->
    Byte = case on(ocrnl, Tty) of
               true -> $\n;
               false -> $\r
           end,
    case on(onocr, Tty) andalso Column =:= 0 of
        true -> {<<>>, Tty};
        false -> {<<Byte>>, line_start(Tty)}
    end;
post(Char, Tty) ->
    {<<Char>>, Tty}.

forward(Width, #tty{column = Column} = Tty) ->
    Tty#tty{column = Column + Width}.

line_start(#tty{line = Line} = Tty) ->
    Tty#tty{column = 0, writepos = 0, reprintpos = byte_size(Line)}.

%% After a write: the line echoed so far is behind it.
written(#tty{column = Column, line = Line} = Tty) ->
    Tty#tty{writepos = Column, reprintpos = byte_size(Line)}.

-doc """
A program's bytes for the master, with at most Room bytes to give. It
returns how many of Bytes it took and what they became. With OPOST clear
the bytes are themselves; with OPOST, each control character becomes what
its output flags make it (ttydisc_write_oproc), and a byte's rendering is
never split, so 4 KiB of newlines with ONLCR and 4 KiB of room takes 2 KiB.
Output stopped by VSTOP takes nothing.
""".
-spec output(binary(), non_neg_integer(), tty()) ->
          {non_neg_integer(), binary(), tty()}.
output(Bytes, Room, #tty{stopped = Stopped} = Tty)
  when is_binary(Bytes), is_integer(Room), Room >= 0 ->
    case {Stopped, on(opost, Tty)} of
        {true, _} ->
            {0, <<>>, Tty};
        {false, false} ->
            Taken = min(Room, byte_size(Bytes)),
            <<Out:Taken/binary, _/binary>> = Bytes,
            {Taken, Out, wrote(Taken, forward(Taken, Tty), Tty)};
        {false, true} ->
            post_bytes(Bytes, Room, 0, [], Tty)
    end.

post_bytes(<<Byte, Rest/binary>>, Room, Taken, Acc, Tty) ->
    {Piece, Tty1} = case caret(Byte) orelse Byte =:= $\t orelse Byte =:= $\n of
                        true -> post(Byte, Tty);
                        false -> {<<Byte>>, forward(1, Tty)}
                    end,
    case byte_size(Piece) =< Room of
        true ->
            post_bytes(Rest, Room - byte_size(Piece), Taken + 1,
                       [Piece | Acc], written(Tty1));
        false ->
            post_bytes(<<>>, 0, Taken, Acc, Tty)
    end;
post_bytes(<<>>, _Room, Taken, Acc, Tty) ->
    {Taken, iolist_to_binary(lists:reverse(Acc)), Tty}.

wrote(0, _, Unchanged) -> Unchanged;
wrote(_, Tty, _) -> written(Tty).

-doc """
The bytes of a status line for the master, rendered as echo renders
(tty_putstrn). They start with a newline when the output column is not 0.
There are none when NOKERNINFO is set (sys/kern/tty.c:1542-1543), when Room
is under 256 bytes (tty.c:2057-2062), or when the line does not fit whole.
""".
-spec status(binary(), non_neg_integer(), tty()) -> {binary(), tty()}.
status(Line, Room, #tty{column = Column} = Tty) when is_binary(Line) ->
    case on(nokerninfo, Tty) orelse Room < ?STATUS_ROOM of
        true ->
            {<<>>, Tty};
        false ->
            Text = case Column of
                       0 -> Line;
                       _ -> <<$\n, Line/binary>>
                   end,
            {Pieces, Tty1} = lists:mapfoldl(fun render/2, Tty,
                                            binary_to_list(Text)),
            Bytes = iolist_to_binary(Pieces),
            case byte_size(Bytes) =< Room of
                true -> {Bytes, written(Tty1)};
                false -> {<<>>, Tty}
            end
    end.

%%% Readers

-doc """
A blocking read of Open starts to wait. The tty reports `{ready, Open}` at
once when the read can go on, and otherwise when it can: with a timer
started now for VMIN 0 and VTIME above 0, or for VMIN and VTIME above 0
when bytes already wait. A wait of the same open replaces it.
""".
-spec read_wait(open(), tty()) -> {[action()], tty()}.
read_wait(Open, Tty) ->
    wait(Open, read, Tty#tty{expired = lists:delete(Open, Tty#tty.expired)}).

-doc """
A poll of Open waits for input, with no timer: `{ready, Open}` comes when a
line is complete in cooked mode, or a byte waits in raw mode.
""".
-spec poll_wait(open(), tty()) -> {[action()], tty()}.
poll_wait(Open, Tty) ->
    wait(Open, poll, Tty).

-doc "Open waits no more, for a signal or a close, and its timer stops.".
-spec cancel(open(), tty()) -> {[action()], tty()}.
cancel(Open, Tty) ->
    unwait(Open, Tty#tty{expired = lists:delete(Open, Tty#tty.expired)}).

-doc """
A timer ended. If it is the current timer of a waiting read, the read can
go on; any other timer, cancelled or replaced, does nothing.
""".
-spec timer(timer(), tty()) -> {[action()], tty()}.
timer({Open, _} = Timer, #tty{waiters = Waiters, expired = Expired} = Tty) ->
    case Waiters of
        #{Open := {read, Timer}} ->
            {[{ready, Open}],
             Tty#tty{waiters = maps:remove(Open, Waiters),
                     expired = [Open | lists:delete(Open, Expired)]}};
        _ ->
            {[], Tty}
    end.

-doc """
Open reads at most Max bytes, at once. In cooked mode it gets the first
line, or as much of it as fits, with its newline or VEOL and without its
VEOF, so VEOF at the start of a line gives no bytes, an end of file
(ttydisc_read_canonical). In raw mode it gets what waits, up to Max. It
gets no bytes when nothing waits and the tty has hung up, or in raw mode
with VMIN 0 when VTIME is 0 or its timer ended; otherwise `eagain`.
""".
-spec read(open(), non_neg_integer(), tty()) ->
          {{ok, binary()} | eagain, tty()}.
read(_Open, 0, Tty) ->
    {{ok, <<>>}, Tty};
read(Open, Max, #tty{expired = Expired} = Tty0)
  when is_integer(Max), Max > 0 ->
    Tty = Tty0#tty{expired = lists:delete(Open, Expired)},
    case on(icanon, Tty) of
        true -> read_line(Max, Tty);
        false -> read_raw(Max, lists:member(Open, Expired), Tty)
    end.

read_line(Max, #tty{ready = Ready, hungup = Hungup} = Tty) ->
    case line_end(Tty) of
        none when Hungup ->
            {{ok, <<>>}, Tty};
        none ->
            {eagain, Tty};
        {Length, Eof} ->
            Data = case Eof of
                       true -> Length - 1;
                       false -> Length
                   end,
            Taken = min(Max, Data),
            Consumed = case Eof andalso Taken =:= Data of
                           true -> Length;
                           false -> Taken
                       end,
            <<Got:Taken/binary, _:(Consumed - Taken)/binary, Rest/binary>> =
                Ready,
            {{ok, Got}, Tty#tty{ready = Rest}}
    end.

read_raw(Max, Expired, #tty{ready = Ready, hungup = Hungup} = Tty) ->
    Empty = Hungup orelse
        (char(vmin, Tty) =:= 0 andalso (char(vtime, Tty) =:= 0 orelse Expired)),
    case min(Max, byte_size(Ready)) of
        0 when Empty ->
            {{ok, <<>>}, Tty};
        0 ->
            {eagain, Tty};
        Taken ->
            <<Got:Taken/binary, Rest/binary>> = Ready,
            {{ok, Got}, Tty#tty{ready = Rest}}
    end.

wait(Open, Kind, Tty0) ->
    {Cancelled, Tty} = unwait(Open, Tty0),
    case ready_for(Kind, Tty) of
        true ->
            {Cancelled ++ [{ready, Open}], Tty};
        false ->
            {Armed, Tty1} = arm(Open, Kind, Tty),
            {Cancelled ++ Armed, Tty1}
    end.

unwait(Open, #tty{waiters = Waiters} = Tty) ->
    case maps:take(Open, Waiters) of
        {{read, {_, _} = Timer}, Rest} ->
            {[{timer_cancel, Timer}], Tty#tty{waiters = Rest}};
        {_, Rest} ->
            {[], Tty#tty{waiters = Rest}};
        error ->
            {[], Tty}
    end.

arm(Open, poll, #tty{waiters = Waiters} = Tty) ->
    {[], Tty#tty{waiters = Waiters#{Open => poll}}};
arm(Open, read, #tty{waiters = Waiters, ready = Ready} = Tty) ->
    Timed = raw_timer(Tty) andalso
        (char(vmin, Tty) =:= 0 orelse byte_size(Ready) > 0),
    case Timed of
        true -> start_timer(Open, Tty);
        false -> {[], Tty#tty{waiters = Waiters#{Open => {read, none}}}}
    end.

start_timer(Open, #tty{serial = Serial, waiters = Waiters} = Tty) ->
    Timer = {Open, Serial},
    {[{timer_start, Timer, char(vtime, Tty) * 100}],
     Tty#tty{serial = Serial + 1, waiters = Waiters#{Open => {read, Timer}}}}.

raw_timer(Tty) ->
    not on(icanon, Tty) andalso char(vtime, Tty) > 0.

%% POSIX's four cases for a read, one byte for a poll, a line when cooked.
ready_for(_, #tty{hungup = true}) ->
    true;
ready_for(Kind, #tty{ready = Ready} = Tty) ->
    case on(icanon, Tty) of
        true -> line_end(Tty) =/= none;
        false -> byte_size(Ready) >= wanted(Kind, Tty)
    end.

wanted(poll, _) ->
    1;
wanted(read, Tty) ->
    case {char(vmin, Tty), char(vtime, Tty)} of
        {0, 0} -> 0;
        {0, _} -> 1;
        {Min, _} -> Min
    end.

%% After input: each waiter whose condition holds is ready. A raw read with
%% VMIN and VTIME above 0 that still waits starts its timer when its first
%% byte arrives, and keeps that one deadline as more bytes arrive, as
%% FreeBSD's ttydisc_read_raw_interbyte_timer sets it once after the first
%% byte (tty_ttydisc.c:360-405, :306-320); a flush that left nothing stops it.
settle(Arrived, #tty{waiters = Waiters} = Tty0) ->
    lists:foldl(fun({Open, Waiter}, {Actions, Tty}) ->
                        {More, Tty1} = settle(Open, Waiter, Arrived, Tty),
                        {Actions ++ More, Tty1}
                end, {[], Tty0}, lists:sort(maps:to_list(Waiters))).

settle(Open, Waiter, Arrived, #tty{ready = Ready} = Tty) ->
    Kind = kind(Waiter),
    Interbyte = Kind =:= read andalso raw_timer(Tty) andalso
        char(vmin, Tty) > 0,
    case ready_for(Kind, Tty) of
        true ->
            {Cancelled, Tty1} = unwait(Open, Tty),
            {Cancelled ++ [{ready, Open}], Tty1};
        false when Interbyte, Arrived, Ready =/= <<>>, Waiter =:= {read, none} ->
            start_timer(Open, Tty);
        false when Interbyte, Ready =:= <<>>, Waiter =/= {read, none} ->
            {Cancelled, Tty1} = unwait(Open, Tty),
            Untimed = (Tty1#tty.waiters)#{Open => {read, none}},
            {Cancelled, Tty1#tty{waiters = Untimed}};
        false ->
            {[], Tty}
    end.

%% Every waiter waits again, as it would start now.
rewait(#tty{waiters = Waiters} = Tty0) ->
    lists:foldl(fun({Open, Waiter}, {Actions, Tty}) ->
                        {More, Tty1} = wait(Open, kind(Waiter), Tty),
                        {Actions ++ More, Tty1}
                end, {[], Tty0}, lists:sort(maps:to_list(Waiters))).

kind(poll) -> poll;
kind({read, _}) -> read.

%%% termios lookups

on(Flag, #tty{termios = #{iflag := I, oflag := O, cflag := C, lflag := L}}) ->
    lists:member(Flag, L) orelse lists:member(Flag, I) orelse
        lists:member(Flag, O) orelse lists:member(Flag, C).

char(Name, #tty{termios = #{cc := Chars}}) ->
    maps:get(Name, Chars).

%% A special character matches only when it is not disabled.
is_char(Name, Char, Tty) ->
    case char(Name, Tty) of
        ?VDISABLE -> false;
        Value -> Value =:= Char
    end.

%% The ends of a cooked line: newline, VEOF and VEOL, as FreeBSD's
%% ttydisc_read_break has them; VEOL2 is not one.
is_end(Char, Tty) ->
    Char =:= $\n orelse is_char(veof, Char, Tty) orelse is_char(veol, Char, Tty).

%% The first line in `ready`: its length with its end, and whether the end
%% is VEOF.
line_end(#tty{ready = Ready} = Tty) ->
    line_end(Ready, 0, Tty).

line_end(<<Char, Rest/binary>>, Position, Tty) ->
    case is_end(Char, Tty) of
        true -> {Position + 1, is_char(veof, Char, Tty)};
        false -> line_end(Rest, Position + 1, Tty)
    end;
line_end(<<>>, _, _) ->
    none.

merge([{echo, <<>>} | Rest]) -> merge(Rest);
merge([{echo, A}, {echo, B} | Rest]) -> merge([{echo, <<A/binary, B/binary>>} | Rest]);
merge([Action | Rest]) -> [Action | merge(Rest)];
merge([]) -> [].
