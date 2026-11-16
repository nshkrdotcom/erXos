%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_jobs_tests).
-moduledoc """
EUnit cases of the job table (erx_shell_jobs): an exhaustive exploration of
every table reachable within a few events from the empty one, checking the
table's invariants and that each effect agrees with the table before and
after the event that made it, that the terminal follows the table
(docs/design-shell.md, "The foreground rule"), and cases of the reports,
the terminal's holder, job specifications and `kill`'s arguments.
""".

-include_lib("eunit/include/eunit.hrl").

%% Tags, waiters and the depth the exploration reaches.
-define(TAGS, [a, b, c]).
-define(DEPTH, 6).

%%% The exhaustive exploration

exhaustive_test_() ->
    {timeout, 120, fun() -> explore() end}.

%% Breadth first, each table once: every event applies to every table seen,
%% and check/4 judges each step.
explore() ->
    Start = erx_shell_jobs:new(),
    Seen = explore([Start], #{key(Start) => Start}, 0),
    %% The exploration reaches stopped, running and done jobs, and a job
    %% in the foreground with the line.
    Views = [erx_shell_jobs:view(J) || J <- maps:values(Seen)],
    States = lists:usort([Run || #{jobs := Jobs} <- Views, {_, Run, _} <- maps:values(Jobs)]),
    ?assertEqual([done, running, stopped], States),
    ?assert(lists:any(fun(#{fg := Fg}) -> Fg =/= none end, Views)).

explore(_Frontier, Seen, ?DEPTH) ->
    Seen;
explore(Frontier, Seen, Depth) ->
    Next = [J1 || J <- Frontier, Event <- events(J, Depth), J1 <- [step(Event, J)]],
    {Frontier1, Seen1} = lists:foldl(fun(J, {F, S}) ->
                                             K = key(J),
                                             case S of
                                                 #{K := _} -> {F, S};
                                                 _ -> {[J | F], S#{K => J}}
                                             end
                                     end, {[], Seen}, Next),
    explore(Frontier1, Seen1, Depth + 1).

%% The whole table: order, the signal ending a job and the waiter all
%% change what later events do.
key(J) -> J.

%% Every event that can reach the table: a tag starts only once while it is
%% held, as erx_shell tags each job with a process of its own.
events(J, Depth) ->
    #{line := Line, jobs := Jobs} = erx_shell_jobs:view(J),
    Held = [T || T <- [Line], T =/= none] ++ [T || {T, _, _} <- maps:values(Jobs)],
    Free = ?TAGS -- Held,
    Specs = [current, previous, {id, 1}, {id, 2}, {id, 9}],
    [{start_line, T} || T <- Free, Line =:= none]
        ++ [{start_background, T} || T <- Free]
        ++ [{typed, Key, From} || Key <- [interrupt, suspend, quit],
                                  From <- [group | [{tty, T} || T <- ?TAGS]]]
        ++ [{above, Above} || Above <- [true, false]]
        ++ [reap, list]
        ++ [{stop_own, T, {own, Depth}} || T <- ?TAGS]
        ++ [{ended, T, R} || T <- ?TAGS, R <- [{exited, <<>>}, {exited, <<"1">>}, failed]]
        ++ [{fg, S, {w, Depth}} || S <- Specs]
        ++ [{bg, S} || S <- Specs]
        ++ [{signal, Sig, S} || S <- Specs,
                                Sig <- [{terminate, <<"TERM">>}, {stop, <<"STOP">>},
                                        {continue, <<"CONT">>}]].

%% A step is the event and then, as erx_shell carries a `foreground` out,
%% the termios its answer says the previous holder left, a term naming
%% the step, given back to the table.
step(Event, J) ->
    {Effects, J1} = apply_event(Event, J),
    ok = check(Event, J, Effects, J1),
    lists:foldl(fun({foreground, _Target, _Seen, Keep}, Acc) ->
                        erx_shell_jobs:kept(Keep, {left, Event}, Acc);
                   (_Effect, Acc) -> Acc
                end, J1, Effects).

apply_event({start_line, T}, J) -> erx_shell_jobs:start_line(T, <<"line">>, J);
apply_event({start_background, T}, J) ->
    {_Id, E, J1} = erx_shell_jobs:start_background(T, <<"bg">>, J),
    {E, J1};
apply_event({typed, Key, From}, J) -> erx_shell_jobs:typed(Key, From, J);
apply_event({above, Above}, J) -> erx_shell_jobs:above(Above, J);
apply_event({stop_own, T, W}, J) -> erx_shell_jobs:stop_own(T, W, J);
apply_event(reap, J) -> erx_shell_jobs:reap(J);
apply_event(list, J) ->
    {_Text, J1} = erx_shell_jobs:list(J),
    {[], J1};
apply_event({ended, T, R}, J) -> erx_shell_jobs:ended(T, R, J);
apply_event({fg, S, W}, J) -> drop_reply(erx_shell_jobs:foreground(S, W, J));
apply_event({bg, S}, J) -> drop_reply(erx_shell_jobs:background(S, J));
apply_event({signal, Sig, S}, J) -> drop_reply(erx_shell_jobs:signal(Sig, S, J)).

drop_reply({_Reply, Effects, J}) -> {Effects, J}.

%% The invariants hold after every event, and each effect agrees with the
%% tables on either side of it.
check(Event, J0, Effects, J1) ->
    ?assertEqual({Event, true}, {Event, erx_shell_jobs:invariant(J1)}),
    V0 = erx_shell_jobs:view(J0),
    V1 = erx_shell_jobs:view(J1),
    [check_effect(E, V0, V1) || E <- Effects],
    check_event(Event, V0, Effects, V1),
    check_terminal(Event, V0, Effects, V1),
    ok.

%% The terminal follows the table: after every step the holder the shell
%% last gave is the one the table's state names, the console with no line
%% or while a shell runs above it, else the job the line waits for in `fg`,
%% else the line. A step that changes the holder ends with one
%% `foreground`; a signal that leaves a job holding ends with `current`
%% for it; every `foreground` carries the signals taken so far.
check_terminal(Event, V0, Effects, V1) ->
    Typed = is_tuple(Event) andalso element(1, Event) =:= typed,
    Seen = maps:get(seen, V0) + case Typed of true -> 1; false -> 0 end,
    ?assertEqual({Event, Seen}, {Event, maps:get(seen, V1)}),
    Want = want(V1),
    ?assertEqual({Event, Want}, {Event, maps:get(given, V1)}),
    Given0 = maps:get(given, V0),
    case [F || F = {foreground, _, _, _} <- Effects] of
        [] ->
            ?assertEqual({Event, Given0}, {Event, Want}),
            ?assertNot(Typed andalso Want =/= console);
        [{foreground, Target, FgSeen, Keep} = Fg] ->
            %% It follows what the step does to processes and precedes its answers.
            Answers = [E || E <- Effects, element(1, E) =:= answer],
            ?assertEqual({Event, [Fg | Answers]}, {Event, lists:dropwhile(fun(E) -> E =/= Fg end, Effects)}),
            ?assertEqual(Seen, FgSeen),
            case Given0 =:= Want of
                true ->
                    ?assert(Typed),
                    ?assertEqual({Want, current}, Target);
                false ->
                    ?assertEqual(Want, holder_of(Target)),
                    check_mode(Target, V1)
            end,
            %% The termios a job leaves at its stop is kept for its `fg`.
            Stopped = Given0 =/= console andalso run_of(Given0, V1) =:= stopped,
            ?assertEqual(case Stopped of true -> Given0; false -> none end, Keep)
    end.

want(#{line := none}) -> console;
want(#{above := true}) -> console;
want(#{fg := none, line := Line}) -> Line;
want(#{fg := Id, jobs := Jobs}) -> element(1, maps:get(Id, Jobs)).

holder_of(console) -> console;
holder_of({Tag, _Mode}) -> Tag.

%% The line runs under the cooked termios; a job `fg` brought back under
%% the one its stop left, or the cooked one when it never stopped.
check_mode(console, _V) -> ok;
check_mode({Tag, Mode}, #{line := Tag}) -> ?assertEqual(cooked, Mode);
check_mode({_Tag, cooked}, _V) -> ok;
check_mode({_Tag, Mode}, _V) -> ?assertMatch({left, _}, Mode).

%% Stopping pauses a running job, which is stopped after; resuming one that
%% was stopped leaves it running; the answer goes to the waiter of the job
%% in the foreground, which then is not; only a held tag is ended.
check_effect({stop, T}, V0, V1) ->
    ?assert(is_line(T, V0) orelse run_of(T, V0) =:= running),
    ?assertEqual(stopped, run_of(T, V1));
check_effect({resume, T}, V0, V1) ->
    ?assertEqual(stopped, run_of(T, V0)),
    ?assertEqual(running, run_of(T, V1));
check_effect({terminate, T}, V0, _V1) ->
    ?assert(is_line(T, V0) orelse run_of(T, V0) =/= none);
check_effect({release, T, _Fate}, V0, _V1) ->
    ?assert(is_line(T, V0) orelse run_of(T, V0) =/= none);
check_effect({interrupted, T}, V0, V1) ->
    ?assert(is_line(T, V0)),
    ?assertEqual(none, maps:get(line, V1));
check_effect({finish_line, T}, V0, V1) ->
    ?assert(is_line(T, V0)),
    ?assertEqual(none, maps:get(line, V1));
check_effect({answer, _W, {ok, Status}}, V0 = #{fg := Fg}, #{fg := Fg1}) ->
    ?assert(is_binary(Status)),
    ?assertNotEqual(none, Fg),
    ?assertEqual(none, Fg1),
    ?assertMatch({_, running, true}, maps:get(Fg, maps:get(jobs, V0)));
check_effect({answer, {own, _}, ok}, _V0, _V1) ->
    ok;
check_effect({answer, {own, _}, {error, enotsup}}, _V0, _V1) ->
    ok;
check_effect({foreground, _Target, _Seen, _Keep}, _V0, _V1) ->
    %% check_terminal/4 judges the terminal.
    ok;
check_effect({say, Bytes}, _V0, _V1) ->
    ?assert(is_binary(iolist_to_binary(Bytes))).

check_event({typed, Key, {tty, T}}, V0 = #{fg := Fg, jobs := Jobs}, Effects, V1) ->
    %% A key the relay reports names the job that held the terminal: it
    %% acts as the group's key while that job is still in the foreground,
    %% and on no job after.
    Foreground = is_line(T, V0) orelse (Fg =/= none andalso element(1, maps:get(Fg, Jobs)) =:= T),
    case Foreground of
        true -> check_event({typed, Key, group}, V0, Effects, V1);
        false -> ?assertEqual(maps:remove(seen, V0), maps:remove(seen, V1))
    end;
check_event({typed, Key, group}, _V0, _Effects, V1) when Key =:= interrupt; Key =:= quit ->
    ?assertMatch(#{line := none, fg := none}, V1);
check_event({typed, suspend, group}, #{line := Line, fg := Fg}, Effects, V1) when Line =/= none ->
    %% The job in the foreground stops first; otherwise the line does.
    case Fg of
        none -> ?assertMatch(#{line := none}, V1);
        _ -> ?assertMatch(#{line := Line, fg := none}, V1)
    end,
    ?assertMatch([{stop, _} | _], Effects);
check_event({stop_own, T, W}, V0 = #{fg := Fg}, Effects, V1) ->
    %% The caller's own job stops, and the caller is answered last; a job
    %% already stopped stays so and the caller is answered; a tag the table
    %% does not hold as a live job, or the line waiting in `fg`, changes
    %% nothing and is refused.
    Run = run_of(T, V0),
    case (is_line(T, V0) andalso Fg =:= none) orelse Run =:= running of
        true ->
            ?assertMatch([{stop, T} | _], Effects),
            ?assertEqual({answer, W, ok}, lists:last([E || E <- Effects, element(1, E) =/= foreground])),
            ?assertEqual(stopped, run_of(T, V1));
        false when Run =:= stopped ->
            ?assertEqual({[{answer, W, ok}], V0}, {Effects, V1});
        false ->
            ?assertEqual({[{answer, W, {error, enotsup}}], V0}, {Effects, V1})
    end;
check_event({ended, T, _R}, V0, Effects, V1) ->
    case is_line(T, V0) orelse run_of(T, V0) =/= none of
        true -> ?assertEqual(1, length([E || E = {release, T1, _} <- Effects, T1 =:= T]));
        false -> ?assertEqual({[], V0}, {Effects, V1})
    end;
check_event(_Event, _V0, _Effects, _V1) ->
    ok.

is_line(T, #{line := Line}) -> T =:= Line.

run_of(T, #{jobs := Jobs}) ->
    case [Run || {T1, Run, _} <- maps:values(Jobs), T1 =:= T] of
        [Run] -> Run;
        [] -> none
    end.

%%% Cases

%% A line that Ctrl-Z stops takes the lowest free number and is reported,
%% and `fg` brings it back with its command shown.
stop_and_continue_test() ->
    {_, J0} = erx_shell_jobs:start_line(l, <<"sleep">>, erx_shell_jobs:new()),
    {E1, J1} = erx_shell_jobs:typed(suspend, group, J0),
    ?assertMatch([{stop, l}, {say, _}, {foreground, console, 1, l}], E1),
    [_, {say, Shown}, _] = E1,
    ?assertEqual(<<"^Z\n[1] + Suspended               sleep\n">>, iolist_to_binary(Shown)),
    ?assertEqual(idle, erx_shell_jobs:line(J1)),
    {_, J2} = erx_shell_jobs:start_line(m, <<"fg">>, J1),
    {wait, E3, J3} = erx_shell_jobs:foreground(current, w, J2),
    ?assertEqual([{say, [<<"sleep">>, $\n]}, {resume, l}, {foreground, {l, cooked}, 1, none}], E3),
    %% Ctrl-Z stops the job in the foreground, not the line waiting for it.
    {E4, J4} = erx_shell_jobs:typed(suspend, group, J3),
    ?assertMatch([{stop, l}, {say, _}, {foreground, {m, cooked}, 2, l}, {answer, w, {ok, <<"sigtstp">>}}], E4),
    ?assertEqual(busy, erx_shell_jobs:line(J4)).

%% Ctrl-C ends the line and the job it waits for, never a background job.
interrupt_spares_background_test() ->
    {1, _, J0} = erx_shell_jobs:start_background(b, <<"spin">>, erx_shell_jobs:new()),
    {2, _, J1} = erx_shell_jobs:start_background(f, <<"other">>, J0),
    {_, J2} = erx_shell_jobs:start_line(l, <<"fg %2">>, J1),
    {wait, _, J3} = erx_shell_jobs:foreground({id, 2}, w, J2),
    {E4, J4} = erx_shell_jobs:typed(interrupt, group, J3),
    ?assertEqual([{terminate, f}, {terminate, l}, {interrupted, l}, {say, <<"^C\n">>},
                  {foreground, console, 1, none}], E4),
    ?assertMatch(#{line := none, fg := none, jobs := #{1 := {b, running, false}}},
                 erx_shell_jobs:view(J4)),
    ?assertEqual(1, map_size(maps:get(jobs, erx_shell_jobs:view(J4)))).

%%% The terminal's holder (docs/design-shell.md, "The foreground rule")

%% A line takes the terminal under the cooked termios before it runs, and
%% the console takes it back when the line ends.
line_holds_while_it_runs_test() ->
    {E0, J0} = erx_shell_jobs:start_line(l, <<"date">>, erx_shell_jobs:new()),
    ?assertEqual([{foreground, {l, cooked}, 0, none}], E0),
    {E1, _} = erx_shell_jobs:ended(l, {exited, <<>>}, J0),
    ?assertEqual([{release, l, keep}, {finish_line, l}, {foreground, console, 0, none}], E1).

%% `fg` gives a stopped job the termios its stop left, also after `bg`;
%% a job started with `&` that never stopped runs under the cooked one.
%% When the job ends the line takes the terminal back.
fg_gives_the_kept_termios_test() ->
    {_, J0} = erx_shell_jobs:start_line(a, <<"vi">>, erx_shell_jobs:new()),
    {E1, J1} = erx_shell_jobs:typed(suspend, {tty, a}, J0),
    %% The relay echoed the key; the shell ends the echoed line.
    ?assertMatch([{stop, a}, {say, [<<"\n">> | _]}, {foreground, console, 1, a}], E1),
    J2 = erx_shell_jobs:kept(a, raw, J1),
    {2, _, J3} = erx_shell_jobs:start_background(b, <<"spin">>, J2),
    {ok, _, J4} = erx_shell_jobs:background({id, 1}, J3),
    {_, J5} = erx_shell_jobs:start_line(m, <<"fg %1">>, J4),
    {wait, E6, J6} = erx_shell_jobs:foreground({id, 1}, w, J5),
    ?assertEqual({foreground, {a, raw}, 1, none}, lists:last(E6)),
    {E7, J7} = erx_shell_jobs:ended(a, {exited, <<>>}, J6),
    ?assertMatch([{release, a, keep}, {foreground, {m, cooked}, 1, none}, {answer, w, {ok, _}}], E7),
    {wait, E8, _} = erx_shell_jobs:foreground({id, 2}, w2, J7),
    ?assertEqual({foreground, {b, cooked}, 1, none}, lists:last(E8)).

%% A key the relay reports for a job that has ended changes no job, and
%% the job that holds now gets its reads back with `current`. Seeded: a
%% table acting on its current foreground ends b.
stale_key_gives_current_test() ->
    {1, _, J0} = erx_shell_jobs:start_background(a, <<"x">>, erx_shell_jobs:new()),
    {_, J1} = erx_shell_jobs:start_line(b, <<"cat">>, J0),
    {_, J2} = erx_shell_jobs:ended(a, {exited, <<>>}, J1),
    {E3, J3} = erx_shell_jobs:typed(interrupt, {tty, a}, J2),
    ?assertEqual([{foreground, {b, current}, 1, none}], E3),
    ?assertEqual(busy, erx_shell_jobs:line(J3)).

%% Ctrl-C at the prompt reaches the group, and the next line's
%% `foreground` carries it. Seeded: a table that counts only the relay's
%% keys, which gives 0.
prompt_interrupt_counts_test() ->
    {E0, J0} = erx_shell_jobs:typed(interrupt, group, erx_shell_jobs:new()),
    ?assertEqual([], E0),
    ?assertEqual({[{foreground, {l, cooked}, 1, none}], idle},
                 {element(1, erx_shell_jobs:start_line(l, <<>>, J0)), erx_shell_jobs:line(J0)}).

%% `erl` gives the console the terminal while the Erlang shell runs, and
%% the line takes it back when it returns.
shell_above_holds_test() ->
    {_, J0} = erx_shell_jobs:start_line(l, <<"erl">>, erx_shell_jobs:new()),
    {E1, J1} = erx_shell_jobs:above(true, J0),
    ?assertEqual([{foreground, console, 0, none}], E1),
    {E2, _} = erx_shell_jobs:above(false, J1),
    ?assertEqual([{foreground, {l, cooked}, 0, none}], E2).

%% `kill` ends a job, which is reported with the signal's name once its
%% first process has ended, and leaves the table with the report.
kill_and_report_test() ->
    {1, [{say, Started}], J0} = erx_shell_jobs:start_background(b, <<"spin">>, erx_shell_jobs:new()),
    ?assertEqual(<<"[1]\n">>, iolist_to_binary(Started)),
    {ok, [{terminate, b}], J1} = erx_shell_jobs:signal({terminate, <<"TERM">>}, {id, 1}, J0),
    {[{release, b, kill}], J2} = erx_shell_jobs:ended(b, failed, J1),
    ?assertEqual(none, erx_shell_jobs:line_tag(J2)),
    {Listed, J3} = erx_shell_jobs:list(J2),
    ?assertEqual(<<"[1] + Terminated              spin\n">>, iolist_to_binary(Listed)),
    ?assertEqual({[], J3}, erx_shell_jobs:reap(J3)),
    ?assertEqual({{error, <<"no current job">>}, [], J3}, erx_shell_jobs:background(current, J3)).

%% A job's command and status reach the terminal escaped.
report_escapes_test() ->
    {1, _, J0} = erx_shell_jobs:start_background(b, <<"echo \e[2J">>, erx_shell_jobs:new()),
    {_, J1} = erx_shell_jobs:ended(b, {exited, <<"bad\e]0;x\^G">>}, J0),
    {[{say, Report}], _} = erx_shell_jobs:reap(J1),
    Bytes = iolist_to_binary(Report),
    ?assertEqual(nomatch, binary:match(Bytes, [<<"\e">>, <<"\^G">>])).

%% Requests from any process are checked whole before the table sees them.
valid_request_test_() ->
    [?_assert(erx_shell_jobs:valid_request({jobs})),
     ?_assert(erx_shell_jobs:valid_request({fg, {id, 2}})),
     ?_assert(erx_shell_jobs:valid_request({signal, {stop, <<"TSTP">>}, previous})),
     ?_assert(erx_shell_jobs:valid_request({background, fun() -> <<>> end})),
     ?_assertNot(erx_shell_jobs:valid_request({fg, bogus})),
     ?_assertNot(erx_shell_jobs:valid_request({fg, {id, 0}})),
     ?_assertNot(erx_shell_jobs:valid_request({signal, {terminate, 1}, current})),
     ?_assertNot(erx_shell_jobs:valid_request({signal, {stop, <<"TERM">>}, current})),
     ?_assertNot(erx_shell_jobs:valid_request({background, fun(_) -> ok end})),
     ?_assertNot(erx_shell_jobs:valid_request(jobs))].

specs_test_() ->
    [?_assertEqual({ok, current}, erx_shell_jobs:parse_spec(<<"%%">>)),
     ?_assertEqual({ok, current}, erx_shell_jobs:parse_spec(<<"%+">>)),
     ?_assertEqual({ok, current}, erx_shell_jobs:parse_spec(<<"%">>)),
     ?_assertEqual({ok, previous}, erx_shell_jobs:parse_spec(<<"%-">>)),
     ?_assertEqual({ok, {id, 12}}, erx_shell_jobs:parse_spec(<<"%12">>)),
     ?_assertEqual(error, erx_shell_jobs:parse_spec(<<"%0">>)),
     ?_assertEqual(error, erx_shell_jobs:parse_spec(<<"%1234567">>)),
     ?_assertEqual(error, erx_shell_jobs:parse_spec(<<"%-1">>)),
     ?_assertEqual(error, erx_shell_jobs:parse_spec(<<"%sleep">>)),
     ?_assertEqual(error, erx_shell_jobs:parse_spec(<<"12">>))].

kill_args_test_() ->
    [?_assertEqual({ok, {terminate, <<"TERM">>}, [<<"%1">>]}, erx_shell_jobs:parse_kill([<<"%1">>])),
     ?_assertEqual({ok, {terminate, <<"KILL">>}, [<<"%1">>]},
                   erx_shell_jobs:parse_kill([<<"-9">>, <<"%1">>])),
     ?_assertEqual({ok, {stop, <<"STOP">>}, [<<"%1">>]},
                   erx_shell_jobs:parse_kill([<<"-s">>, <<"sigstop">>, <<"%1">>])),
     ?_assertEqual({ok, {continue, <<"CONT">>}, [<<"%1">>, <<"%2">>]},
                   erx_shell_jobs:parse_kill([<<"-CONT">>, <<"%1">>, <<"%2">>])),
     ?_assertEqual({ok, {terminate, <<"TERM">>}, [<<"-1">>]},
                   erx_shell_jobs:parse_kill([<<"--">>, <<"-1">>])),
     ?_assertEqual(list, erx_shell_jobs:parse_kill([<<"-l">>])),
     ?_assertEqual(usage, erx_shell_jobs:parse_kill([])),
     ?_assertEqual(usage, erx_shell_jobs:parse_kill([<<"-9">>])),
     ?_assertEqual(usage, erx_shell_jobs:parse_kill([<<"-WINCH">>, <<"%1">>])),
     ?_assertEqual(usage, erx_shell_jobs:parse_kill([<<"-999">>, <<"%1">>])),
     ?_assertEqual(<<"HUP INT QUIT KILL TERM STOP TSTP CONT\n">>, erx_shell_jobs:signal_names())].
