%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_draw_conn).
-moduledoc """
A stand-in for the draw connection in the tests of a program's window. start/1
makes a connection process that ends when its starter does, or refuses with
`enomem`, as for an image 0 that cannot be made, on the display `noimage`.
ctl/1 answers 144 bytes whose first field counts the resized/1 calls so far,
write/2 answers `{incomplete, eio}` for the bytes `bad` and `ok` for any
other, and every call to a connection that has ended answers `ebadf`. Each
start and write is told as erx_win's stand-in tells its events.
""".

-export([start/1, write/2, read/2, resized/1, ctl/1]).

start(#{window := Window}) ->
    case maps:get(display, Window) of
        noimage ->
            {error, enomem};
        _ ->
            Starter = self(),
            Conn = spawn(fun() -> Ref = monitor(process, Starter), conn(Ref, 0) end),
            tell({conn, Conn}),
            {ok, Conn}
    end.

conn(Ref, Resized) ->
    receive
        {'DOWN', Ref, process, _, _} -> ok;
        {call, From, resized} -> From ! {answer, ok}, conn(Ref, Resized + 1);
        {call, From, ctl} -> From ! {answer, {ok, iolist_to_binary(io_lib:format("~11b ~131s ", [Resized, ""]))}},
                             conn(Ref, Resized);
        {call, From, {write, <<"bad">>}} -> From ! {answer, {incomplete, eio}}, conn(Ref, Resized);
        {call, From, {write, _}} -> From ! {answer, ok}, conn(Ref, Resized);
        {call, From, {read, _}} -> From ! {answer, {ok, <<>>}}, conn(Ref, Resized)
    end.

write(Conn, Bytes) -> tell({write, Bytes}), call(Conn, {write, Bytes}).
read(Conn, Count) -> call(Conn, {read, Count}).
resized(Conn) -> call(Conn, resized).
ctl(Conn) -> call(Conn, ctl).

call(Conn, Request) ->
    Ref = monitor(process, Conn),
    Conn ! {call, self(), Request},
    receive
        {answer, Answer} -> demonitor(Ref, [flush]), Answer;
        {'DOWN', Ref, process, _, _} -> {error, ebadf}
    end.

tell(Event) ->
    case persistent_term:get(erx_win, undefined) of
        Test when is_pid(Test) -> Test ! {erx_win, Event};
        undefined -> ok
    end.
