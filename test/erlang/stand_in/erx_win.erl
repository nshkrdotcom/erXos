%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_win).
-moduledoc """
A stand-in for the window client in the tests of a program's window
(erx_prog_handler_tests and erx_session_export_tests). open/2 makes a window
process that ends when its opener does, as the display ends a window with its
holder; the display `nogrant` has no grant. Each window holds the answers its
options name for read_at/4, and every relayed request, clipboard open and
close is told to the process persistent_term names under this module, if any,
as `{erx_win, Event}`. The display `clip` carries `clipboard`.
""".

-export([open/2, read_at/4, write_at/4, clipboard/1, clipboard_open/2, clipboard_read/3,
         clipboard_write/3, clipboard_close/1]).
-export_type([window/0, clipboard/0]).

-opaque window() :: #{proc := pid(), display := atom()}.
-opaque clipboard() :: {clip, non_neg_integer()}.

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
        {read, From, File} -> From ! {answer, maps:get(File, Answers, {ok, <<>>})}, window(Ref, Answers)
    end.

read_at(#{proc := Proc}, File, Offset, Count) ->
    tell({read_at, File, Offset, Count}),
    Proc ! {read, self(), File},
    receive {answer, Answer} -> Answer after 1000 -> {error, eio} end.

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
