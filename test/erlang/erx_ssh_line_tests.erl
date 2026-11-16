%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the session's line to the SSH domain (erx_ssh_line and its core,
%% erx_ssh_line_core; docs/design-ssh.md, "Sessions, ttys and shells"). The export
%% table and the tty opener are the test's stand-ins; erx_session_tty_tests covers the
%% tty a channel gets and its report of the shell's status.
-module(erx_ssh_line_tests).

-include_lib("eunit/include/eunit.hrl").

-export([owner/1, export/3]).

-define(PEER, 5).
-define(SYSTEM, 4).
-define(OTHER, 9).
-define(TESTER, erx_ssh_line_tests_test).

%% The export table's stand-in: every name is the peer's unless a test has claimed it for
%% another domain.
owner(Name) when is_pid(Name); is_reference(Name) ->
    persistent_term:get({?MODULE, owner, Name}, ?PEER).

%% Every export is taken and told to the test.
export(Name, Rights, Peer) ->
    ?TESTER ! {exported, Name, Rights, Peer},
    ok.

%% A line whose opener tells the test each open and answers with a fresh tty, a process
%% that reports a status through the line's Notify and ends when the test tells it to,
%% or the error the test asked for.
line() ->
    _ = [unregister(?TESTER) || whereis(?TESTER) =/= undefined],
    register(?TESTER, self()),
    Open = fun(Channel, Spec = #{run := Run, size := Size}, Notify) ->
                   case persistent_term:get({?MODULE, open_error}, none) of
                       none ->
                           Tty = spawn(fun() -> stand_in_tty(Notify) end),
                           ?TESTER ! {opened, Tty, Channel, Run, Size},
                           ?TESTER ! {vars, Tty, maps:get(vars, Spec, none)},
                           {ok, Tty};
                       Error ->
                           {error, Error}
                   end
           end,
    {ok, Line} = erx_ssh_line:start_link(#{system => ?SYSTEM, exports => ?MODULE, open => Open}),
    Line.

stand_in_tty(Notify) ->
    receive
        {notify, Status} -> Notify(Status), stand_in_tty(Notify);
        stop -> ok
    end.

%% Request in Domain's envelope as a call, and the answer, or none.
call(Line, Domain, Request) ->
    Alias = alias([reply]),
    Line ! {erx_origin, Domain, {'$gen_call', {self(), [alias | Alias]}, Request}},
    receive {[alias | Alias], Reply} -> Reply after 300 -> unalias(Alias), none end.

exported_line() ->
    Line = line(),
    ?assertEqual(ok, call(Line, ?SYSTEM, {export, ?PEER})),
    ?assertEqual(ok, receive {exported, Line, [send], ?PEER} -> ok after 1000 -> none end),
    Line.

opened() ->
    receive {opened, Tty, Channel, Run, Size} -> {Tty, Channel, Run, Size} after 1000 -> none end.

%% Only the system domain exports the line: the same call from the peer, or from a
%% third domain, is dropped, and a line that is exported to no one serves no request.
export_only_from_the_system_domain_test() ->
    Line = line(),
    ?assertEqual(none, call(Line, ?PEER, {export, ?PEER})),
    ?assertEqual(none, call(Line, ?OTHER, {export, ?OTHER})),
    ?assertEqual(none, call(Line, ?PEER, {open_tty, self(), shell, <<"xterm">>, 24, 80})),
    ?assertEqual(ok, call(Line, ?SYSTEM, {export, ?PEER})),
    ?assertEqual(ok, call(Line, ?PEER, {open_tty, self(), shell, <<"xterm">>, 24, 80})),
    ?assertMatch({_, _, shell, _}, opened()),
    %% Once exported, the line serves its peer alone.
    ?assertEqual(none, call(Line, ?OTHER, {open_tty, self(), shell, <<"xterm">>, 24, 80})).

%% Every shape but open_tty's, and every field outside its bounds, is badarg, and opens
%% nothing; the bounds themselves are taken.
request_shapes_test() ->
    Line = exported_line(),
    Me = self(),
    Bad = [nonsense, {open_tty}, {open_tty, Me, shell, <<"xterm">>, 24},
           {open_tty, not_a_pid, shell, <<"xterm">>, 24, 80},
           {open_tty, Me, login, <<"xterm">>, 24, 80},
           {open_tty, Me, {exec, <<>>}, <<"xterm">>, 24, 80},
           {open_tty, Me, {exec, <<"echo", 0, "x">>}, <<"xterm">>, 24, 80},
           {open_tty, Me, {exec, binary:copy(<<"a">>, 32769)}, <<"xterm">>, 24, 80},
           {open_tty, Me, {exec, "echo"}, <<"xterm">>, 24, 80},
           {open_tty, Me, shell, "xterm", 24, 80},
           {open_tty, Me, shell, binary:copy(<<"x">>, 65), 24, 80},
           {open_tty, Me, shell, <<"xterm">>, -1, 80},
           {open_tty, Me, shell, <<"xterm">>, 24, 65536},
           {open_tty, Me, shell, <<"xterm">>, 24.0, 80}],
    [?assertEqual({Request, {error, badarg}}, {Request, call(Line, ?PEER, Request)}) || Request <- Bad],
    ?assertEqual(none, opened()),
    Command = binary:copy(<<"a">>, 32768),
    ?assertEqual(ok, call(Line, ?PEER, {open_tty, Me, {exec, Command}, binary:copy(<<"x">>, 64), 0, 65535})),
    ?assertMatch({_, Me, {exec, Command}, _}, opened()).

%% A channel that is no process of the peer's is badarg, so the session never sends a
%% tty's bytes to a third domain.
foreign_channel_test() ->
    Line = exported_line(),
    Foreign = spawn(fun() -> ok end),
    persistent_term:put({?MODULE, owner, Foreign}, ?OTHER),
    try
        ?assertEqual({error, badarg}, call(Line, ?PEER, {open_tty, Foreign, shell, <<"vt100">>, 24, 80})),
        ?assertEqual(none, opened())
    after
        persistent_term:erase({?MODULE, owner, Foreign})
    end.

%% Past ten open channels the line answers limited; a tty's end frees its place.
limited_test() ->
    Line = exported_line(),
    Open = [begin
                ?assertEqual(ok, call(Line, ?PEER, {open_tty, self(), shell, <<"vt100">>, 24, 80})),
                opened()
            end || _ <- lists:seq(1, 10)],
    ?assertEqual({error, limited}, call(Line, ?PEER, {open_tty, self(), shell, <<"vt100">>, 24, 80})),
    [{Tty, _, _, _} | _] = Open,
    Tty ! stop,
    ?assertEqual(ok, wait_ok(Line, 20)),
    ?assertMatch({_, _, shell, _}, opened()).

wait_ok(_Line, 0) -> gave_up;
wait_ok(Line, N) ->
    case call(Line, ?PEER, {open_tty, self(), shell, <<"vt100">>, 24, 80}) of
        ok -> ok;
        {error, limited} -> timer:sleep(50), wait_ok(Line, N - 1)
    end.

%% A tty that cannot be started is answered limited.
open_failure_test() ->
    Line = exported_line(),
    persistent_term:put({?MODULE, open_error}, no_room),
    try
        ?assertEqual({error, limited}, call(Line, ?PEER, {open_tty, self(), shell, <<"vt100">>, 24, 80}))
    after
        persistent_term:erase({?MODULE, open_error})
    end.

%% The tty's report of its shell's status reaches the channel as {exited, Status}, sent
%% by the line; the same report from a process that is no tty of the line's reaches no
%% one.
exited_reaches_the_channel_test() ->
    Line = exported_line(),
    ?assertEqual(ok, call(Line, ?PEER, {open_tty, self(), {exec, <<"exit 4">>}, <<"vt100">>, 24, 80})),
    {Tty, Channel, _Run, _Size} = opened(),
    ?assertEqual(self(), Channel),
    Line ! {erx_ssh_line, exited, spawn(fun() -> ok end), 5},
    Tty ! {notify, 4},
    ?assertEqual(4, receive {exited, Status} -> Status after 1000 -> none end),
    ?assertEqual(none, receive {exited, Other} -> Other after 300 -> none end).

%% The tty opens at the size asked for, a side of zero being 24 rows or 80 columns.
size_test() ->
    Line = exported_line(),
    [begin
         ?assertEqual(ok, call(Line, ?PEER, {open_tty, self(), shell, <<"vt100">>, Rows, Columns})),
         ?assertMatch({_, _, shell, Size}, opened())
     end || {Rows, Columns, Size} <- [{30, 100, {30, 100}}, {0, 0, {24, 80}}, {0, 132, {24, 132}}, {50, 0, {50, 80}}]].

%% The shell's TERM is the channel's Term when abi/terminal.txt lists it and vt100 for
%% any other name: an unknown one, an empty one, another case, or one that carries an
%% escape sequence, so no byte of the peer's reaches the shell's variables.
term_test() ->
    Line = exported_line(),
    [begin
         ?assertEqual(ok, call(Line, ?PEER, {open_tty, self(), shell, Term, 24, 80})),
         {Tty, _, shell, _} = opened(),
         ?assertEqual({Term, #{<<"TERM">> => [Given]}}, {Term, receive {vars, Tty, Vars} -> Vars after 1000 -> none end})
     end || {Term, Given} <- [{<<"vt100">>, <<"vt100">>}, {<<"xterm">>, <<"xterm">>},
                              {<<"xterm-256color">>, <<"xterm-256color">>}, {<<"ansi">>, <<"vt100">>},
                              {<<>>, <<"vt100">>}, {<<"XTERM">>, <<"vt100">>},
                              {<<"xterm", 27, "]0;owned", 7>>, <<"vt100">>}]].
