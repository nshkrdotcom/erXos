%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_job_tests).
-moduledoc """
EUnit cases of the job relay, erx_ssh_job (docs/design-ssh.md, "Sessions,
ttys and shells"), running the real rc: the test process is the channel,
answering each job_output with job_sent as a channel does, and checks what
the relay sends it, the bytes of each stream and the ending, and what the
relay does at the channel's hangup and end.
""".

-include_lib("eunit/include/eunit.hrl").

-define(WAIT, 5000).

%% rc finds its commands in the erx_shell application's modules
%% (erx_shell_namespace:from_applications/1); the test build has no .app files,
%% so the test loads a description naming the commands it runs.
start(Command) ->
    _ = application:load({application, erx_shell,
                          [{description, "test"}, {vsn, "1"}, {modules, [erx_cmd_cat, erx_cmd_echo]}]}),
    erx_ssh_job:start(self(), Command, #{vars => #{}, cwd => <<"/">>}).

%% Everything the job sends until its ending: the bytes of each stream and the
%% status, answering each piece as a channel does.
collect(Relay) -> collect(Relay, #{stdout => [], stderr => []}).

collect(Relay, Acc) ->
    receive
        {job_output, Stream, Bytes} when byte_size(Bytes) =< 32768 ->
            Relay ! job_sent,
            collect(Relay, Acc#{Stream := [maps:get(Stream, Acc), Bytes]});
        {exited, Status} ->
            #{stdout => iolist_to_binary(maps:get(stdout, Acc)),
              stderr => iolist_to_binary(maps:get(stderr, Acc)), status => Status}
    after ?WAIT ->
            error({no_ending, Acc})
    end.

%% How the process the monitor Ref watches ended, or `running`.
ended(Ref) ->
    receive {'DOWN', Ref, process, _, Reason} -> Reason after ?WAIT -> running end.

output_and_status_test() ->
    Relay = start(<<"echo hi">>),
    Ref = monitor(process, Relay),
    ?assertEqual(#{stdout => <<"hi\n">>, stderr => <<>>, status => 0}, collect(Relay)),
    ?assertEqual(normal, ended(Ref)).

exit_status_test() ->
    ?assertMatch(#{status := 3}, collect(start(<<"exit 3">>))).

error_output_stays_apart_test() ->
    Relay = start(<<"echo out; echo err >[1=2]">>),
    ?assertEqual(#{stdout => <<"out\n">>, stderr => <<"err\n">>, status => 0}, collect(Relay)).

%% Input is answered piece by piece, end of input closes rc's standard input,
%% and output larger than one piece arrives whole and in order.
input_through_cat_test() ->
    Relay = start(<<"cat">>),
    Bytes = << <<B>> || _ <- lists:seq(1, 300), B <- lists:seq(0, 255) >>,
    Pieces = [binary:part(Bytes, At, min(32768, byte_size(Bytes) - At))
              || At <- lists:seq(0, byte_size(Bytes) - 1, 32768)],
    Output = lists:foldl(fun(Piece, Taken) ->
                                 Relay ! {job_input, Piece},
                                 written(Relay, Taken)
                         end, [], Pieces),
    Relay ! job_eof,
    #{stdout := Rest, status := 0} = collect(Relay),
    ?assertEqual(Bytes, iolist_to_binary([Output, Rest])).

%% Waits for job_written, answering output meanwhile, as cat may echo before
%% it is answered.
written(Relay, Taken) ->
    receive
        job_written -> Taken;
        {job_output, stdout, Bytes} ->
            Relay ! job_sent,
            written(Relay, [Taken, Bytes])
    after ?WAIT ->
            error(not_written)
    end.

%% The relay is the job's group: io output goes to standard error, and input
%% is refused.
group_leader_test() ->
    Relay = start(<<"cat">>),
    ?assertEqual(ok, io:format(Relay, "said ~p~n", [x])),
    ?assertEqual({error, enotsup}, io:get_line(Relay, '')),
    ?assertEqual({error, enotsup}, io:columns(Relay)),
    ?assertEqual({error, enotsup}, io:request(Relay, {put_chars, unicode, erlang, halt, []})),
    ?assertEqual({error, request}, io:request(Relay, {requests, [{put_chars, unicode, <<"x">>},
                                                                 {get_line, unicode, ''}]})),
    Relay ! job_eof,
    ?assertEqual(#{stdout => <<>>, stderr => <<"said x\n">>, status => 0}, collect(Relay)).

hangup_ends_the_job_test() ->
    Relay = start(<<"cat">>),
    {RelayRef, RcRef} = watch(Relay),
    Relay ! job_hangup,
    ?assertEqual({shutdown, hangup}, ended(RelayRef)),
    ?assertNotEqual(running, ended(RcRef)).

channel_end_ends_the_job_test() ->
    Test = self(),
    Channel = spawn(fun() -> Test ! {relay, start(<<"cat">>)}, receive stop -> ok end end),
    Relay = receive {relay, R} -> R end,
    {RelayRef, RcRef} = watch(Relay),
    Channel ! stop,
    ?assertEqual({shutdown, hangup}, ended(RelayRef)),
    ?assertNotEqual(running, ended(RcRef)).

%% A malformed job_input ends the job as a hangup does.
bad_input_ends_the_job_test() ->
    Relay = start(<<"cat">>),
    Ref = monitor(process, Relay),
    Relay ! {job_input, binary:copy(<<"x">>, 32769)},
    ?assertEqual({shutdown, hangup}, ended(Ref)).

%% Monitors of the relay and of its rc, the one process linked to the relay
%% once the relay has started it.
watch(Relay) -> watch(Relay, 100).

watch(Relay, Tries) ->
    case process_info(Relay, links) of
        {links, [Rc]} -> {monitor(process, Relay), monitor(process, Rc)};
        {links, []} when Tries > 0 -> receive after 10 -> watch(Relay, Tries - 1) end
    end.
