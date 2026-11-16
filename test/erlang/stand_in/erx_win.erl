%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_win).
-moduledoc """
A stand-in for the window client in the tests of a program's window
(erx_prog_handler_tests and erx_session_export_tests). open/2 makes a window
process that ends when its opener does, as the display ends a window with its
holder; the display `nogrant` has no grant. Each window holds the answers its
options name for read_at/4 and send_read/4, and every relayed request, clipboard
open and close is told to the process persistent_term names under this module,
if any, as `{erx_win, Event}`. The display `clip` carries `clipboard`. A sent
read's answer arrives as `{erx_win_reply, Id, Answer}`, which reply/2 takes for
Id, and the window process answers a flush of one ok so, after the read.
""".

-export([open/2, read_at/4, write_at/4, send_read/4, reply/2, send_flush/2, clipboard/1,
         clipboard_open/2, clipboard_read/3, clipboard_write/3, clipboard_close/1]).
-export_type([window/0, clipboard/0, request/0]).

-opaque window() :: #{proc := pid(), display := atom()}.
-opaque clipboard() :: {clip, non_neg_integer()}.
-opaque request() :: reference().

open(nogrant, _Options) ->
    {error, none};
open(Display, Options) ->
    Opener = self(),
    Answers = maps:get(answers, Options, #{}),
    Proc = spawn(fun() -> Ref = monitor(process, Opener), window(Ref, Answers) end),
    tell({opened, Proc}),
    {ok, #{proc => Proc, display => Display}}.

window(Ref, Answers) ->
    receive
        {'DOWN', Ref, process, _, _} -> ok;
        {read, From, File} -> From ! {answer, maps:get(File, Answers, {ok, <<>>})}, window(Ref, Answers);
        {read, From, Id, File} ->
            From ! {erx_win_reply, Id, maps:get(File, Answers, {ok, <<>>})},
            window(Ref, Answers);
        {flush, From, Id} -> From ! {erx_win_reply, Id, ok}, window(Ref, Answers)
    end.

read_at(#{proc := Proc}, File, Offset, Count) ->
    tell({read_at, File, Offset, Count}),
    Proc ! {read, self(), File},
    receive {answer, Answer} -> Answer after 1000 -> {error, eio} end.

send_read(#{proc := Proc}, File, Offset, Count) when File =:= kbd; File =:= mouse ->
    tell({send_read, File, Offset, Count}),
    Id = make_ref(),
    Proc ! {read, self(), Id, File},
    {ok, Id}.

reply({erx_win_reply, Id, Answer}, Id) -> {reply, Answer};
reply(_Message, _Id) -> no_reply.

%% The window process answers the flush after the read it names, as the display does.
send_flush(#{proc := Proc}, Read) ->
    tell({send_flush, Read}),
    Id = make_ref(),
    Proc ! {flush, self(), Id},
    {ok, Id}.

write_at(_Window, File, Offset, Bytes) ->
    tell({write_at, File, Offset, Bytes}),
    {ok, byte_size(Bytes), Offset + byte_size(Bytes)}.

clipboard(Display) -> Display =:= clip.

clipboard_open(_Display, Flags) ->
    tell({clipboard_open, Flags, self()}),
    {ok, {clip, Flags}}.

clipboard_read(_Clipboard, _Offset, _Count) -> {ok, <<"snarf">>}.

clipboard_write(_Clipboard, Offset, Bytes) -> {ok, byte_size(Bytes), Offset}.

clipboard_close(Clipboard) ->
    tell({clipboard_close, Clipboard}),
    ok.

tell(Event) ->
    case persistent_term:get(?MODULE, undefined) of
        Test when is_pid(Test) -> Test ! {?MODULE, Event};
        undefined -> ok
    end.
