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
