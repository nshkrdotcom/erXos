%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_tty_tests).
-moduledoc """
A session's ttys, erx_session_tty, each with the command shell on it, driven by
a terminal relay of its own (erx_session_relay), and a fake master in the same
node: a process that hands the test every message the tty sends it, while the
test takes each output, answering `{tty_taken, N}` as the console does, and
types into the tty with `{tty_input, Bytes}`. On one tty, `echo hi` and `erl`
return, `exit` starts the command shell again, an answer the master never sends
is asked for again within the resend second, and a hangup ends the tty. Two
masters each get a tty of their own, whose relays hold no name: the relay of the
domain's line alone holds erx_tty_owner. One master's end ends its tty only,
leaving the other tty and the line's `user` running.
""".
-behaviour(supervisor).

-include_lib("eunit/include/eunit.hrl").

-export([init/1]).

-define(WAIT_MS, 10000).

%% One process drives a tty throughout, so the steps run in order in it.
relay_test_() ->
    {timeout, 60, fun() -> in_session(fun relay/1) end}.

masters_test_() ->
    {timeout, 60, fun() -> in_session(fun two_masters/1) end}.

%% A session's domain starts with -nouser, so no `user` is registered but its line's:
%% the node's is set aside for the run. This module stands in for erx_session_sup, with
%% the session's console tty as its one child at the start; on the host erx:cap(console)
%% names no master, so that tty is stopped, and its console holds `user`.
in_session(Test) ->
    process_flag(trap_exit, true),
    Host = whereis(user),
    true = unregister(user),
    {ok, Sup} = supervisor:start_link({local, erx_session_sup}, ?MODULE, []),
    try Test(Sup) after
        Ended = monitor(process, Sup),
        unlink(Sup),
        exit(Sup, shutdown),
        receive {'DOWN', Ended, process, Sup, _} -> ok end,
        %% The line's `user` ends after its console, and may free its name meanwhile.
        try unregister(user) catch error:badarg -> ok end,
        register(user, Host)
    end.

-doc false.
init([]) ->
    Line = #{id => erx_session_tty, start => {erx_session_tty, start_link, []}, restart => transient},
    {ok, {#{strategy => one_for_one}, [Line]}}.

relay(_Sup) ->
    Master = master(),
    {ok, Console} = erx_session_tty:open(Master),
    Tty = opened(Master),
    ?assertMatch({erx_session_relay, init, _}, proc_lib:initial_call(Tty)),
    {ok, _} = await(Master, Tty, <<"% ">>),
    echo_and_erl_return(Master, Tty),
    exit_starts_the_shell_again(Master, Tty),
    a_taken_output_asks_nothing_more(Master, Tty),
    a_lost_answer_is_asked_for_again(Master, Tty),
    a_hangup_ends_the_tty(Master, Tty, Console).

%% A hangup while the Erlang shell runs ends that shell, the command shell then
%% reads the end of its input, and the tty and its console end with it, normally,
%% leaving the runtime running.
a_hangup_ends_the_tty(Master, Tty, Console) ->
    type(Tty, <<"erl\r">>),
    {ok, _} = await(Master, Tty, <<"1> ">>),
    ConsoleEnded = monitor(process, Console),
    TtyEnded = monitor(process, Tty),
    Tty ! tty_hangup,
    ?assertEqual(normal, ended(ConsoleEnded, Console)),
    _ = ended(TtyEnded, Tty),
    exit(Master, kill).

echo_and_erl_return(Master, Tty) ->
    type(Tty, <<"echo hi\r">>),
    {ok, _} = await(Master, Tty, <<"hi\n% ">>),
    type(Tty, <<"erl\r">>),
    {ok, _} = await(Master, Tty, <<"1> ">>),
    %% The Erlang shell's group ends, so run_shell/1 returns and `erl` with it.
    type(Tty, <<"exit(group_leader(), kill).\r">>),
    {ok, Seen} = await(Master, Tty, <<"% ">>),
    ?assertNotEqual(nomatch, binary:match(Seen, <<"killed">>)).

exit_starts_the_shell_again(Master, Tty) ->
    type(Tty, <<"exit\r">>),
    {ok, _} = await(Master, Tty, <<"exit ends it\n% ">>),
    type(Tty, <<"echo again\r">>),
    {ok, _} = await(Master, Tty, <<"again\n% ">>).

%% With every output answered at once, the tty names itself again only with a resend:
%% the timer of an output already taken sends nothing. A tty that named itself at each
%% such timer would send a burst of tty_open a second after a burst of output, such as
%% a line editor's echo of a pasted line, which fills the console facet's limit in
%% flight, so the facet drops the output sent among it and the console takes that
%% output's empty resend as its bytes lost.
a_taken_output_asks_nothing_more(Master, Tty) ->
    _ = flush_opens(Master),
    type(Tty, <<"echo quiet\r">>),
    {ok, _} = await(Master, Tty, <<"quiet\n% ">>),
    {Opens, Resends} = answer_until(Master, Tty, erlang:monotonic_time(millisecond) + 1500, 0, 0),
    ?assert(Opens =< Resends, {opens, Opens, resends, Resends}).

a_lost_answer_is_asked_for_again(Master, Tty) ->
    type(Tty, <<"echo lost\r">>),
    %% The first output's answer is lost: the tty names itself again and sends the
    %% output again, empty, and the master answers that.
    N = receive {Master, {tty_output, Number, <<_, _/binary>>}} -> Number after ?WAIT_MS -> error(no_output) end,
    Started = erlang:monotonic_time(millisecond),
    receive {Master, {tty_open, Tty}} -> ok after 3000 -> error(no_open) end,
    receive {Master, {tty_output, N, <<>>}} -> ok after 3000 -> error(no_resend) end,
    ?assert(erlang:monotonic_time(millisecond) - Started >= 900),
    Tty ! {tty_taken, N},
    {ok, _} = await(Master, Tty, <<"lost\n% ">>).

%% Two masters open ttys under the session's supervisor. What is typed at one tty
%% reaches only its own master, and when one master ends, its tty hangs up and ends,
%% while the other tty, the line and the line's `user` run on.
two_masters(Sup) ->
    User = whereis(user),
    One = master(),
    Two = master(),
    {ok, ConsoleOne} = erx_session_tty:open(One),
    {ok, _ConsoleTwo} = erx_session_tty:open(Two),
    TtyOne = opened(One),
    TtyTwo = opened(Two),
    ?assertNotEqual(TtyOne, TtyTwo),
    Line = whereis(erx_tty_owner),
    ?assertMatch({erx_session_relay, init, _}, proc_lib:initial_call(Line)),
    ?assertNot(lists:member(Line, [TtyOne, TtyTwo])),
    {ok, _} = await(One, TtyOne, <<"% ">>),
    {ok, _} = await(Two, TtyTwo, <<"% ">>),

    type(TtyOne, <<"echo one\r">>),
    {ok, _} = await(One, TtyOne, <<"one\n% ">>),
    type(TtyTwo, <<"echo two\r">>),
    {ok, SeenTwo} = await(Two, TtyTwo, <<"two\n% ">>),
    ?assertEqual(nomatch, binary:match(SeenTwo, <<"one">>)),

    ConsoleEnded = monitor(process, ConsoleOne),
    TtyEnded = monitor(process, TtyOne),
    exit(One, kill),
    ?assertEqual(normal, ended(ConsoleEnded, ConsoleOne)),
    _ = ended(TtyEnded, TtyOne),
    type(TtyTwo, <<"echo still\r">>),
    {ok, _} = await(Two, TtyTwo, <<"still\n% ">>),
    ?assert(is_pid(User) andalso whereis(user) =:= User),
    ?assertEqual(Line, whereis(erx_tty_owner)),
    Children = supervisor:which_children(Sup),
    ?assertEqual(2, length(Children)),
    ?assertMatch([_], [Id || {Id = {erx_session_tty, _}, _, worker, _} <- Children]),
    exit(Two, kill).

%% How Pid, monitored by Monitor, ended.
ended(Monitor, Pid) ->
    receive {'DOWN', Monitor, process, Pid, Reason} -> Reason after ?WAIT_MS -> error({runs_on, Pid}) end.

%%% The fake master

%% A master that hands the test, as {Master, Message}, every message it gets.
master() ->
    Test = self(),
    spawn_link(fun() -> forward(Test) end).

forward(Test) ->
    receive Message -> Test ! {self(), Message} end,
    forward(Test).

%% The tty that names itself to Master.
opened(Master) ->
    receive {Master, {tty_open, Tty}} -> Tty after ?WAIT_MS -> error(no_tty_open) end.

type(Tty, Bytes) ->
    Tty ! {tty_input, Bytes}.

%% The tty_open messages waiting, which the tty sent as it named itself.
flush_opens(Master) ->
    receive {Master, {tty_open, Tty}} -> [Tty | flush_opens(Master)] after 0 -> [] end.

%% Answers every output until Deadline, counting the tty_open messages and the empty
%% resends that came.
answer_until(Master, Tty, Deadline, Opens, Resends) ->
    receive
        {Master, {tty_open, _}} ->
            answer_until(Master, Tty, Deadline, Opens + 1, Resends);
        {Master, {tty_output, N, Bytes}} ->
            Tty ! {tty_taken, N},
            answer_until(Master, Tty, Deadline, Opens, Resends + case Bytes of <<>> -> 1; _ -> 0 end)
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
            {Opens, Resends}
    end.

%% Takes every output until what it took, carriage returns aside, contains Pattern,
%% and returns it. A command's newline reaches the master as CR CR LF while its job
%% holds the terminal (TODO.md, "a command's output through the console"), so no
%% pattern names a CR.
await(Master, Tty, Pattern) ->
    await(Master, Tty, Pattern, <<>>).

await(Master, Tty, Pattern, Seen) ->
    receive
        {Master, {tty_output, N, Bytes}} ->
            Tty ! {tty_taken, N},
            All = <<Seen/binary, Bytes/binary>>,
            case binary:match(binary:replace(All, <<"\r">>, <<>>, [global]), Pattern) of
                nomatch -> await(Master, Tty, Pattern, All);
                _ -> {ok, All}
            end
    after ?WAIT_MS ->
            {timeout, Pattern, Seen}
    end.
