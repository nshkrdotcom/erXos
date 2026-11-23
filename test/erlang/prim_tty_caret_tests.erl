%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(prim_tty_caret_tests).
-moduledoc """
EUnit cases of the tree's prim_tty:handle_request/2 on `{putc, Binary}` with control
characters. Caret notation shows a control character as `^` and the character with bit 6
set (NUL as `^@`, Ctrl-A as `^A`, US as `^_`) and DEL as `^?`; stock OTP sets bit 5
instead and shows NUL as `^ ` and Ctrl-A as `^!`, an upstream bug. The cases run against
the tree's prim_tty (test/host/prim_tty_caret_test.rb loads it over the kernel's); against
stock's the control characters other than DEL fail.
""".

-include_lib("eunit/include/eunit.hrl").

caret_test_() ->
    [{lists:flatten(io_lib:format("character ~B is shown as ~s", [Char, Shown])),
      fun() -> ?assertEqual(<<"x", Shown/binary, "y">>, putc(<<"x", Char, "y">>)) end}
     || {Char, Shown} <- [{0, <<"^@">>}, {1, <<"^A">>}, {26, <<"^Z">>}, {28, <<"^\\">>},
                          {31, <<"^_">>}, {127, <<"^?">>}]].

%% What a cooked-mode, 80-column terminal-less prim_tty writes for Binary.
putc(Binary) ->
    State = prim_tty:init_ssh(#{}, {80, 24}, unicode),
    {Output, _} = prim_tty:handle_request(State, {putc, Binary}),
    iolist_to_binary(Output).

%% The editor steps over a control character as one character, and prim_tty moves over and
%% erases both columns its caret notation takes, as it does two printable characters; stock
%% steps over one column and leaves a stray `^` behind a deleted `^@`.
one_step_over_a_caret_spans_its_two_columns_test_() ->
    [{atom_to_list(element(1, Step)),
      fun() -> ?assertEqual(after_typing(<<"xab">>, double(Step)), after_typing(<<"x", 0>>, Step)) end}
     || Step <- [{delete, -1}, {move, -1}]].

double({Request, N}) -> {Request, 2 * N}.

%% What a terminal-less prim_tty writes for Request once Typed is inserted.
after_typing(Typed, Request) ->
    State = prim_tty:init_ssh(#{}, {80, 24}, unicode),
    {_, Typing} = prim_tty:handle_request(State, {insert, Typed}),
    {Output, _} = prim_tty:handle_request(Typing, Request),
    iolist_to_binary(Output).
