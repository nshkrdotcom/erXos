%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_ssh_job_core, the job relay's protocol (docs/design-ssh.md, "Sessions, ttys
%% and shells"), explored exhaustively: from a new job, every order of the
%% channel's messages, well-formed or not, of the input writer's answer, of each
%% reader's pieces and end and of the job's end, up to two inputs and two pieces a
%% stream. After every step the test checks what the relay may do and what it
%% must do: a well-formed input is written and a bad one hangs the job up,
%% job_hangup hangs it up, a write is answered with job_written, standard input
%% is closed once job_eof came and every write is done, and never sooner; one
%% write and one job_output unanswered at most, a reader reads again only once
%% its piece is answered, and exited goes once, as soon as every piece was sent
%% and answered after the job ended, and is the step's last action but stop.
-module(erx_ssh_job_core_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(INPUTS, 2).
-define(PIECES, 2).

%% The test's record of the relay: whether a write is unanswered, inputs sent,
%% whether job_eof was sent and standard input closed, which readers are reading,
%% each stream's pieces read, at its end, and read but not answered,
%% job_outputs unanswered and the stream of the last one sent, pieces sent,
%% whether the job has ended, and whether the relay is done. The *_due keys are
%% what the event obliges the relay to do in this step.
model() ->
    #{writing => false, inputs => 0, eof_sent => false, closed => false,
      reading => #{stdout => true, stderr => true},
      pieces => #{stdout => 0, stderr => 0},
      at_end => #{stdout => false, stderr => false},
      held => #{stdout => 0, stderr => 0},
      unanswered => 0, last => none, sent => 0, ended => false, exited => false,
      done => false,
      input_due => none, written_due => false, hangup_due => false}.

exhaustive_test() ->
    Seen = explore([{erx_ssh_job_core:new(), model()}], #{}, 0),
    ?assert(map_size(Seen) > 500).

explore([], Seen, Endings) ->
    %% The exploration reaches the ending along many orders.
    ?assert(Endings > 100),
    Seen;
explore([State | Rest], Seen, Endings) when is_map_key(State, Seen) ->
    explore(Rest, Seen, Endings);
explore([{Job, M} = State | Rest], Seen, Endings) ->
    Next = [begin
                {Job1, Actions} = erx_ssh_job_core:step(Event, Job),
                {Job1, check(Event, Actions, M)}
            end || Event <- events(M)],
    Ended = length([S || {_, #{done := true}} = S <- Next]),
    explore([S || {_, #{done := false}} = S <- Next] ++ Rest,
            Seen#{State => true}, Endings + Ended).

%% The events the relay can meet in M: any channel message, and the writer's,
%% readers' and job's events only where they can happen.
events(#{writing := Writing, inputs := Inputs, reading := Reading,
         pieces := Pieces, ended := Ended}) ->
    Big = binary:copy(<<0>>, ?ERX_SSH_LINE_DATA_MAX + 1),
    Channel = [{job_input, <<0, 255>>} || Inputs < ?INPUTS]
        ++ [{job_input, Big}, {job_input, nope}, job_eof, job_sent,
            job_hangup, {job_output, stdout, <<"x">>}],
    [{channel, Message} || Message <- Channel]
        ++ [written || Writing]
        ++ [{read, S, atom_to_binary(S)}
            || S <- [stdout, stderr], maps:get(S, Reading),
               maps:get(S, Pieces) < ?PIECES]
        ++ [{read, S, eof} || S <- [stdout, stderr], maps:get(S, Reading)]
        ++ [{ended, 3} || not Ended].

%% M after Event and the relay's Actions, every rule asserted.
check(Event, Actions, M0) ->
    M = lists:foldl(fun act/2, before(Event, M0), Actions),
    Context = {Event, Actions, M0},
    ?assertMatch(#{input_due := none, written_due := false, hangup_due := false},
                 M, Context),
    ?assert(maps:get(unanswered, M) =< 1, Context),
    case M of
        #{done := false, eof_sent := true, writing := false} ->
            ?assert(maps:get(closed, M), Context);
        #{} ->
            ok
    end,
    case ready(M) andalso not maps:get(done, M) of
        true -> ?assert(false, {no_exited, Context});
        false -> ok
    end,
    M.

%% The model once Event has happened, before the relay acts on it, with what
%% the event obliges the relay to do.
before({channel, {job_input, Bytes}}, #{writing := false, eof_sent := false,
                                        inputs := N} = M)
  when is_binary(Bytes), byte_size(Bytes) =< ?ERX_SSH_LINE_DATA_MAX ->
    M#{inputs := N + 1, input_due := Bytes};
before({channel, {job_input, _}}, M) ->
    M#{hangup_due := true};
before({channel, job_eof}, M) ->
    M#{eof_sent := true};
before({channel, job_sent}, #{unanswered := 1, last := S, held := H} = M) ->
    M#{unanswered := 0, held := H#{S := maps:get(S, H) - 1}};
before({channel, job_sent}, M) ->
    M;
before({channel, job_hangup}, M) ->
    M#{hangup_due := true};
before({channel, _}, M) ->
    M;
before(written, M) ->
    M#{writing := false, written_due := true};
before({read, S, eof}, #{reading := R, at_end := E} = M) ->
    M#{reading := R#{S := false}, at_end := E#{S := true}};
before({read, S, _}, #{reading := R, pieces := P, held := H} = M) ->
    M#{reading := R#{S := false}, pieces := P#{S := maps:get(S, P) + 1},
       held := H#{S := maps:get(S, H) + 1}};
before({ended, _}, M) ->
    M#{ended := true}.

act(_Action, #{done := true} = M) ->
    ?assert(false, {action_after_the_end, M});
act({write, Bytes}, #{writing := false, closed := false, input_due := Bytes} = M) ->
    M#{writing := true, input_due := none};
act(close_input, #{closed := false, writing := false, eof_sent := true} = M) ->
    M#{closed := true};
act({send, job_written}, #{written_due := true} = M) ->
    M#{written_due := false};
act({send, {job_output, S, Bytes}}, #{unanswered := 0, sent := N} = M) ->
    ?assertEqual(atom_to_binary(S), Bytes),
    M#{unanswered := 1, last := S, sent := N + 1};
act({read, S}, #{reading := R, at_end := E, held := H} = M) ->
    ?assertNot(maps:get(S, R)),
    ?assertNot(maps:get(S, E)),
    %% A reader reads again only once its last piece has been answered.
    ?assertEqual(0, maps:get(S, H)),
    M#{reading := R#{S := true}};
act({send, {exited, 3}}, #{exited := false} = M) ->
    ?assert(ready(M)),
    M#{exited := true};
act(stop, #{exited := true} = M) ->
    M#{done := true};
act(hangup, #{hangup_due := true} = M) ->
    M#{done := true, hangup_due := false};
act(Action, M) ->
    ?assert(false, {unexpected, Action, M}).

%% Whether exited is due: the job ended, both readers at their end, every piece
%% sent and answered.
ready(#{ended := Ended, at_end := #{stdout := true, stderr := true},
        pieces := #{stdout := A, stderr := B}, sent := Sent, unanswered := 0}) ->
    Ended andalso Sent =:= A + B;
ready(_M) ->
    false.

%% Once the relay is over, by hangup or its ending, nothing changes it.
nothing_after_the_end_test() ->
    {Over, [hangup]} = erx_ssh_job_core:step({channel, job_hangup},
                                             erx_ssh_job_core:new()),
    ?assertEqual([{Over, []}, {Over, []}, {Over, []}],
                 [erx_ssh_job_core:step(Event, Over)
                  || Event <- [{channel, {job_input, <<"x">>}}, {read, stdout, eof},
                               {ended, 0}]]).

%% The channel's checks of what the line sends for its job.
heard_test() ->
    Big = binary:copy(<<1>>, ?ERX_SSH_LINE_DATA_MAX + 1),
    Idle = #{input => false, output => false},
    Input = Idle#{input := true},
    Output = Idle#{output := true},
    Heard = [{job_written, Input}, {job_written, Idle},
             {{job_output, stderr, <<0>>}, Idle},
             {{job_output, stderr, <<0>>}, Output},
             {{job_output, stdin, <<0>>}, Idle}, {{job_output, stdout, Big}, Idle},
             {{exited, 255}, Idle}, {{exited, 256}, Idle},
             {{signaled, sigint}, Idle}, {other, Input}],
    ?assertEqual([written, close, {output, stderr, <<0>>}, close, close, close,
                  {ended, 255}, close, close, close],
                 [erx_ssh_job_core:heard(Message, Unanswered)
                  || {Message, Unanswered} <- Heard]).
