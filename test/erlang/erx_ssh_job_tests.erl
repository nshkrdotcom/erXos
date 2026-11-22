%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_job_tests).
-moduledoc """
EUnit cases of the job relay, erx_ssh_job (docs/design-ssh.md, "Sessions,
ttys and shells"), running the real rc: the test process is the channel,
answering each job_output with job_sent as a channel does, and checks what
the relay sends it, the bytes of each stream and the ending, what the relay
does at the channel's hangup and end, and that it takes no job message
without the channel's tag.
""".

-include_lib("eunit/include/eunit.hrl").

-define(WAIT, 5000).

%% rc finds its commands in the erx_shell application's modules
%% (erx_shell_namespace:from_applications/1); the test build has no .app files,
%% so the test loads a description naming the commands it runs. A job is the
%% relay and the tag of its messages.
start(Command) ->
    _ = application:load({application, erx_shell,
                          [{description, "test"}, {vsn, "1"}, {modules, [erx_cmd_cat, erx_cmd_echo]}]}),
    erx_ssh_job:start(Command, #{vars => #{}, cwd => <<"/">>}).

%% Sends the relay a job message, tagged as the channel tags it.
send({Relay, Alias}, Message) ->
    Relay ! {Alias, Message}.

%% Everything the job sends until its ending: the bytes of each stream and the
%% status, answering each piece as a channel does.
collect(Job) -> collect(Job, #{stdout => [], stderr => []}).

collect({_, Alias} = Job, Acc) ->
    receive
        {Alias, {job_output, Stream, Bytes}} when byte_size(Bytes) =< 32768 ->
            send(Job, job_sent),
            collect(Job, Acc#{Stream := [maps:get(Stream, Acc), Bytes]});
        {Alias, {exited, Status}} ->
            #{stdout => iolist_to_binary(maps:get(stdout, Acc)),
              stderr => iolist_to_binary(maps:get(stderr, Acc)), status => Status}
    after ?WAIT ->
            error({no_ending, Acc})
    end.

%% How the process the monitor Ref watches ended, or `running`.
ended(Ref) ->
    receive {'DOWN', Ref, process, _, Reason} -> Reason after ?WAIT -> running end.

output_and_status_test() ->
    {Relay, _} = Job = start(<<"echo hi">>),
    Ref = monitor(process, Relay),
    ?assertEqual(#{stdout => <<"hi\n">>, stderr => <<>>, status => 0}, collect(Job)),
    ?assertEqual(normal, ended(Ref)).

exit_status_test() ->
    ?assertMatch(#{status := 3}, collect(start(<<"exit 3">>))).

error_output_stays_apart_test() ->
    Job = start(<<"echo out; echo err >[1=2]">>),
    ?assertEqual(#{stdout => <<"out\n">>, stderr => <<"err\n">>, status => 0}, collect(Job)).

%% Input is answered piece by piece, end of input closes rc's standard input,
%% and output larger than one piece arrives whole and in order.
input_through_cat_test() ->
    Job = start(<<"cat">>),
    Bytes = << <<B>> || _ <- lists:seq(1, 300), B <- lists:seq(0, 255) >>,
    Pieces = [binary:part(Bytes, At, min(32768, byte_size(Bytes) - At))
              || At <- lists:seq(0, byte_size(Bytes) - 1, 32768)],
    Output = lists:foldl(fun(Piece, Taken) ->
                                 send(Job, {job_input, Piece}),
                                 written(Job, Taken)
                         end, [], Pieces),
    send(Job, job_eof),
    #{stdout := Rest, status := 0} = collect(Job),
    ?assertEqual(Bytes, iolist_to_binary([Output, Rest])).

%% Waits for job_written, answering output meanwhile, as cat may echo before
%% it is answered.
written({_, Alias} = Job, Taken) ->
    receive
        {Alias, job_written} -> Taken;
        {Alias, {job_output, stdout, Bytes}} ->
            send(Job, job_sent),
            written(Job, [Taken, Bytes])
    after ?WAIT ->
            error(not_written)
    end.

%% The job's group: io output goes to standard error, a put_chars naming a
%% function is taken as stock OTP's group takes it, and input is refused.
group_leader_test() ->
    Job = start(<<"cat">>),
    Group = group(Job),
    ?assertEqual(ok, io:format(Group, "said ~p~n", [x])),
    ?assertEqual(ok, io:request(Group, {put_chars, unicode, lists, flatten, [["a", "b"]]})),
    ?assertEqual({error, enotsup}, io:get_line(Group, '')),
    ?assertEqual({error, enotsup}, io:columns(Group)),
    ?assertEqual({error, request}, io:request(Group, {requests, [{put_chars, unicode, <<"x">>},
                                                                 {get_line, unicode, ''}]})),
    GroupRef = monitor(process, Group),
    send(Job, job_eof),
    ?assertEqual(#{stdout => <<>>, stderr => <<"said x\nab">>, status => 0}, collect(Job)),
    %% The relay's normal end ends the group too.
    ?assertEqual(killed, ended(GroupRef)).

%% Output requests that arrive while one is being written wait their turn: two
%% processes printing at once are both answered, and each line reaches standard
%% error whole.
concurrent_printers_test() ->
    Job = start(<<"cat">>),
    Group = group(Job),
    Test = self(),
    _ = [spawn(fun() ->
                   Results = [io:format(Group, "~s ~b~n", [Name, N]) || N <- lists:seq(1, 20)],
                   Test ! {printed, Name, Results}
           end) || Name <- ["a", "b"]],
    Printed = [receive {printed, Name, Results} -> {Name, Results} after ?WAIT -> {Name, hung} end
               || Name <- ["a", "b"]],
    ?assertEqual([{Name, lists:duplicate(20, ok)} || Name <- ["a", "b"]], Printed),
    send(Job, job_eof),
    #{stderr := Error, status := 0} = collect(Job),
    Lines = lists:sort(binary:split(Error, <<"\n">>, [global, trim])),
    ?assertEqual(lists:sort([iolist_to_binary(io_lib:format("~s ~b", [Name, N]))
                             || Name <- ["a", "b"], N <- lists:seq(1, 20)]), Lines).

%% A job message without the channel's tag, sent by any other process of the
%% session, and an exit signal forged as rc's, change nothing: the job takes
%% only the channel's input and ends with rc's own status.
untagged_messages_are_dropped_test() ->
    {Relay, _} = Job = start(<<"cat">>),
    {_, _, Rc} = watch(Relay),
    _ = [Relay ! Forged || Forged <- [{job_input, <<"forged">>}, job_eof, job_hangup,
                                      {make_ref(), job_hangup},
                                      {'EXIT', Rc, {shutdown, {signaled, sigint}}}]],
    send(Job, {job_input, <<"real">>}),
    send(Job, job_eof),
    ?assertEqual(#{stdout => <<"real">>, stderr => <<>>, status => 0}, collect(Job)).

hangup_ends_the_job_test() ->
    {Relay, _} = Job = start(<<"cat">>),
    {RelayRef, RcRef, _} = watch(Relay),
    send(Job, job_hangup),
    ?assertEqual({shutdown, hangup}, ended(RelayRef)),
    ?assertNotEqual(running, ended(RcRef)).

%% A hangup ends rc, for the relay's reason, even while its command touches
%% neither stream, as a loop does: rc ends because the relay does, not
%% because its pipes die.
hangup_ends_a_job_that_never_reads_test() ->
    {Relay, _} = Job = start(<<"while(~ a a) x=y">>),
    {RelayRef, RcRef, Rc} = watch(Relay),
    ok = trapping(Rc, 100),
    send(Job, job_hangup),
    ?assertEqual({shutdown, hangup}, ended(RelayRef)),
    ?assertEqual({shutdown, hangup}, ended(RcRef)).

%% Waits until Rc traps exits, so a hangup reaches it as a message rather
%% than ending it before it reads exit signals.
trapping(Rc, Tries) ->
    case process_info(Rc, trap_exit) of
        {trap_exit, true} -> ok;
        {trap_exit, false} when Tries > 0 -> receive after 10 -> trapping(Rc, Tries - 1) end
    end.

channel_end_ends_the_job_test() ->
    Test = self(),
    Channel = spawn(fun() -> Test ! {relay, start(<<"cat">>)}, receive stop -> ok end end),
    {Relay, _} = receive {relay, Job} -> Job end,
    {RelayRef, RcRef, _} = watch(Relay),
    Channel ! stop,
    ?assertEqual({shutdown, hangup}, ended(RelayRef)),
    ?assertNotEqual(running, ended(RcRef)).

%% A malformed job_input ends the job as a hangup does.
bad_input_ends_the_job_test() ->
    {Relay, _} = Job = start(<<"cat">>),
    Ref = monitor(process, Relay),
    send(Job, {job_input, binary:copy(<<"x">>, 32769)}),
    ?assertEqual({shutdown, hangup}, ended(Ref)).

%% While the channel takes none of the job's output, printers wait in their
%% requests and the relay holds none of them: sixteen processes each printing
%% 100000 characters leave the relay under 1 MiB, and once the channel takes
%% the output every one is answered and all of it arrives.
a_stalled_channel_holds_no_output_in_the_relay_test() ->
    {Relay, Alias} = Job = start(<<"cat">>),
    Group = group(Job),
    Test = self(),
    Line = lists:duplicate(100000, $a),
    _ = [spawn(fun() -> Test ! {printed, io:format(Group, "~s", [Line])} end) || _ <- lists:seq(1, 16)],
    First = receive {Alias, {job_output, stderr, Bytes}} -> Bytes after ?WAIT -> error(no_output) end,
    receive after 200 -> ok end,
    %% The relay's heap and mailbox, and the binaries it holds off its heap.
    [{memory, Memory}, {binary, Binaries}] = process_info(Relay, [memory, binary]),
    Held = Memory + lists:sum([Size || {_, Size, _} <- Binaries]),
    ?assert(Held < 1 bsl 20, {relay_holds, Held}),
    send(Job, job_sent),
    send(Job, job_eof),
    #{stderr := Rest, status := 0} = collect(Job),
    ?assertEqual(16 * 100000, byte_size(First) + byte_size(Rest)),
    ?assertEqual(lists:duplicate(16, ok),
                 [receive {printed, Result} -> Result after ?WAIT -> hung end || _ <- lists:seq(1, 16)]).

%% A printer's format runs its own code, here a map-order comparator that never
%% returns and traps exits; that holds only the printer's request, and the
%% channel's hangup still ends the relay, rc and the group.
a_format_that_never_returns_ends_with_the_channel_test() ->
    {Relay, _} = Job = start(<<"cat">>),
    Group = group(Job),
    GroupRef = monitor(process, Group),
    {RelayRef, RcRef, _} = watch(Relay),
    Test = self(),
    Compare = fun(_, _) ->
                      process_flag(trap_exit, true),
                      Test ! comparing,
                      receive after infinity -> true end
              end,
    _ = spawn(fun() -> io:format(Group, "~Kp~n", [Compare, #{a => 1, b => 2}]) end),
    receive comparing -> ok after ?WAIT -> error(not_comparing) end,
    send(Job, job_hangup),
    ?assertEqual({shutdown, hangup}, ended(RelayRef)),
    ?assertNotEqual(running, ended(RcRef)),
    ?assertEqual(killed, ended(GroupRef)).

%% The job's group: rc's group leader.
group({Relay, _}) ->
    {_, _, Rc} = watch(Relay),
    {group_leader, Group} = process_info(Rc, group_leader),
    Group.

%% Monitors of the relay and of its rc, and rc: of the processes linked to the
%% relay, the one whose group leader is the relay or another of them.
watch(Relay) -> watch(Relay, 100).

watch(Relay, Tries) ->
    {links, Links} = process_info(Relay, links),
    Leader = fun(Pid) -> element(2, process_info(Pid, group_leader)) end,
    case [Pid || Pid <- Links, lists:member(Leader(Pid), [Relay | Links])] of
        [Rc] -> {monitor(process, Relay), monitor(process, Rc), Rc};
        [] when Tries > 0 -> receive after 10 -> watch(Relay, Tries - 1) end
    end.
