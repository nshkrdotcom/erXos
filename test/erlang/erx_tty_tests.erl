%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_tty, the line discipline (docs/design-live.md, "The
%% tty"): first FreeBSD's behaviour case by case, then the exploration, which
%% drives every event from every state it reaches, to a bounded depth, over
%% small configurations, and checks each step against spec_*, a reference of
%% what a reader may get that shares no code with erx_tty, and against the
%% properties named in each failure: no lost or early ready report, the timer
%% of POSIX's VMIN and VTIME cases, no echo without ECHO, signals only with
%% ISIG, VSTATUS only with ICANON and IEXTEN, output only as OPOST says.

-module(erx_tty_tests).
-include_lib("eunit/include/eunit.hrl").

%%% Cases

defaults_are_freebsds_test() ->
    Termios = erx_tty:termios(erx_tty:new()),
    ?assertEqual([brkint, icrnl, imaxbel, iutf8, ixany, ixon], maps:get(iflag, Termios)),
    ?assertEqual([onlcr, opost], maps:get(oflag, Termios)),
    ?assertEqual([echo, echoctl, echoe, echoke, icanon, iexten, isig], maps:get(lflag, Termios)),
    ?assertMatch(#{veof := 4, verase := 127, vintr := 3, vstatus := 20, vmin := 1, vtime := 0,
                   veol := 255}, maps:get(cc, Termios)).

a_cooked_line_is_edited_echoed_and_read_whole_test() ->
    {Actions, Tty} = erx_tty:input(<<"ab", 127, "c\r">>, erx_tty:new()),
    ?assertEqual([{echo, <<"ab\b \bc\r\n">>}], Actions),
    ?assertEqual(3, erx_tty:waiting(Tty)),
    ?assertMatch({{ok, <<"ac\n">>}, _}, erx_tty:read(r, 64, Tty)).

a_partial_line_is_not_read_test() ->
    {_, Tty} = erx_tty:input(<<"ab">>, erx_tty:new()),
    ?assertMatch({eagain, _}, erx_tty:read(r, 64, Tty)).

veof_ends_a_line_and_alone_is_end_of_file_test() ->
    {[{echo, Echo}], Tty} = erx_tty:input(<<"ab", 4, 4>>, erx_tty:new()),
    ?assertEqual(<<"ab^D\b\b^D\b\b">>, Echo),
    {{ok, <<"ab">>}, Tty1} = erx_tty:read(r, 64, Tty),
    ?assertMatch({{ok, <<>>}, _}, erx_tty:read(r, 64, Tty1)).

kill_and_word_erase_test() ->
    {_, Tty} = erx_tty:input(<<"one two  ", 23, "x", 21, "z\n">>, erx_tty:new()),
    ?assertMatch({{ok, <<"z\n">>}, _}, erx_tty:read(r, 64, Tty)),
    {_, Tty1} = erx_tty:input(<<"one two  ", 23, "\n">>, erx_tty:new()),
    ?assertMatch({{ok, <<"one \n">>}, _}, erx_tty:read(r, 64, Tty1)).

vstatus_gives_info_keeps_the_line_and_echoes_nothing_test() ->
    {Actions, Tty} = erx_tty:input(<<"ab", 20>>, erx_tty:new()),
    ?assertEqual([{echo, <<"ab">>}, info], Actions),
    {_, Tty1} = erx_tty:input(<<"\r">>, Tty),
    ?assertMatch({{ok, <<"ab\n">>}, _}, erx_tty:read(r, 64, Tty1)),
    {[{echo, <<"^T">>}], _} = erx_tty:input(<<20>>, with([], [iexten], erx_tty:new())).

intr_flushes_echoes_and_signals_test() ->
    {_, Tty} = erx_tty:input(<<"ab\rcd">>, erx_tty:new()),
    {Actions, Tty1} = erx_tty:input(<<3>>, Tty),
    ?assertEqual([flush_output, {echo, <<"^C">>}, {signal, sigint}], Actions),
    ?assertEqual(0, erx_tty:waiting(Tty1)),
    {_, Tty2} = erx_tty:input(<<3>>, with([noflsh], [], Tty)),
    ?assertEqual(3, erx_tty:waiting(Tty2)).

a_crlf_is_never_split_test() ->
    Newlines = binary:copy(<<"\n">>, 4096),
    {Taken, Out, _} = erx_tty:output(Newlines, 4096, erx_tty:new()),
    ?assertEqual(2048, Taken),
    ?assertEqual(binary:copy(<<"\r\n">>, 2048), Out).

output_without_opost_is_the_bytes_test() ->
    Every = << <<B>> || B <- lists:seq(0, 255) >>,
    Raw = with([], [opost], erx_tty:new()),
    ?assertMatch({256, Every, _}, erx_tty:output(Every, 4096, Raw)),
    ?assertMatch({4, <<"\r\n\tx\b">>, _},
                 erx_tty:output(<<"\n\tx\b", 4, 127, "\r", 27, "[m">>, 5, erx_tty:new())).

output_flags_test() ->
    Tty = with([tab3, onoeot, onocr, ocrnl], [], erx_tty:new()),
    ?assertMatch({6, <<"ab      \n">>, _}, erx_tty:output(<<"\rab\t", 4, "\r">>, 64, Tty)).

ixon_stops_and_starts_output_test() ->
    {[stop_output], Stopped} = erx_tty:input(<<19>>, erx_tty:new()),
    ?assertMatch({0, <<>>, _}, erx_tty:output(<<"x">>, 64, Stopped)),
    {[start_output], Started} = erx_tty:input(<<17>>, with([], [ixany], Stopped)),
    ?assertMatch({1, <<"x">>, _}, erx_tty:output(<<"x">>, 64, Started)),
    %% IXANY: any key restarts output, and is itself input.
    {[start_output, {echo, <<"q">>}], _} = erx_tty:input(<<"q">>, Stopped),
    %% A signal from a key, VSTATUS and a new size start it too, as on FreeBSD.
    Strict = with([], [ixany], Stopped),
    {[start_output, flush_output, {echo, <<"^C">>}, {signal, sigint}], _} = erx_tty:input(<<3>>, Strict),
    {[start_output, info], _} = erx_tty:input(<<20>>, Strict),
    {ok, [start_output, winch], _} = erx_tty:size(30, 100, Strict).

echo_of_one_input_is_bounded_test() ->
    Keys = <<(binary:copy(<<"a">>, 2048))/binary, (binary:copy(<<18>>, 2048))/binary>>,
    {Actions, _} = erx_tty:input(Keys, erx_tty:new()),
    Echo = iolist_to_binary([Bytes || {echo, Bytes} <- Actions]),
    ?assert(byte_size(Echo) =< 16384 + 8).

input_beyond_its_bound_is_dropped_and_counted_test() ->
    {Actions, Raw} = erx_tty:input(binary:copy(<<"a">>, 5000), raw(1, 0)),
    ?assertEqual([], Actions),
    ?assertEqual({4096, 904}, {erx_tty:waiting(Raw), erx_tty:dropped(Raw)}),
    Quiet = with([], [echo], erx_tty:new()),
    {Bells, Full} = erx_tty:input(binary:copy(<<"a">>, 4096), Quiet),
    ?assertEqual([{echo, <<7>>}], Bells),
    {[], Ended} = erx_tty:input(<<"\n">>, Full),
    ?assertEqual(4096, erx_tty:waiting(Ended)).

utf8_tab_and_covered_erase_test() ->
    {_, Utf8} = erx_tty:input(<<"x", 16#c3, 16#a9>>, erx_tty:new()),
    {[{echo, <<"\b \b">>}], Erased} = erx_tty:input(<<127>>, Utf8),
    {_, Erased1} = erx_tty:input(<<"\n">>, Erased),
    ?assertMatch({{ok, <<"x\n">>}, _}, erx_tty:read(r, 64, Erased1)),
    {_, Tab} = erx_tty:input(<<"a\t">>, erx_tty:new()),
    {[{echo, <<"\b\b\b\b\b\b\b">>}], _} = erx_tty:input(<<127>>, Tab),
    %% Output written over the line since: the line is typed again.
    {_, Typed} = erx_tty:input(<<"ab">>, erx_tty:new()),
    {1, _, Covered} = erx_tty:output(<<"x">>, 64, Typed),
    {[{echo, <<"^R\r\na">>}], _} = erx_tty:input(<<127>>, Covered).

status_line_test() ->
    Line = <<"load: 0.00\n">>,
    {<<"load: 0.00\r\n">>, _} = erx_tty:status(Line, 256, erx_tty:new()),
    {_, Typed} = erx_tty:input(<<"ab">>, erx_tty:new()),
    {<<"\r\nload: 0.00\r\n">>, _} = erx_tty:status(Line, 256, Typed),
    {<<>>, _} = erx_tty:status(Line, 255, erx_tty:new()),
    {<<>>, _} = erx_tty:status(binary:copy(<<"x">>, 300), 299, erx_tty:new()),
    {<<>>, _} = erx_tty:status(Line, 4096, with([nokerninfo], [], erx_tty:new())).

window_size_test() ->
    Tty = erx_tty:new(),
    {ok, [winch], Tty1} = erx_tty:size(50, 132, Tty),
    ?assertEqual({50, 132}, erx_tty:winsize(Tty1)),
    {ok, [], _} = erx_tty:size(50, 132, Tty1),
    [?assertEqual({error, einval}, erx_tty:size(R, C, Tty))
     || {R, C} <- [{0, 80}, {24, 0}, {65536, 80}, {24, -1}, {a, 80}, {24, 1.0}]].

set_checks_the_termios_whole_test() ->
    Tty = erx_tty:new(),
    Good = erx_tty:termios(Tty),
    Bad = [Good#{lflag := [echo, bogus]}, Good#{iflag := [icrnl | ixon]},
           Good#{cc := (maps:get(cc, Good))#{vmin := 256}},
           Good#{cc := maps:remove(vtime, maps:get(cc, Good))},
           Good#{cc := (maps:get(cc, Good))#{vbogus => 1}},
           Good#{csize := 9}, Good#{ospeed := -1}, Good#{extra => 1},
           maps:remove(oflag, Good), Good#{oflag := [onlcr, echo]}, [], undefined],
    [?assertEqual({error, einval}, erx_tty:set(Termios, Tty)) || Termios <- Bad],
    {ok, [], Set} = erx_tty:set(Good#{ispeed := 0, ospeed := 38400, lflag := [isig, echo, echo]}, Tty),
    ?assertMatch(#{ispeed := 38400, lflag := [echo, isig]}, erx_tty:termios(Set)).

switching_to_raw_makes_the_line_readable_test() ->
    {_, Typed} = erx_tty:input(<<"ab">>, erx_tty:new()),
    {[], Waiting} = erx_tty:read_wait(r, Typed),
    {ok, [{ready, r}], Raw} = erx_tty:set(erx_tty:termios(raw(1, 0)), Waiting),
    ?assertMatch({{ok, <<"ab">>}, _}, erx_tty:read(r, 64, Raw)).

%% POSIX's four cases, each driven event by event.
vmin_and_vtime_test() ->
    %% VMIN 2, VTIME 0: ready at two bytes.
    {[], W1} = erx_tty:read_wait(r, raw(2, 0)),
    {[], W2} = erx_tty:input(<<"a">>, W1),
    {[{ready, r}], W3} = erx_tty:input(<<"b">>, W2),
    {{ok, <<"ab">>}, _} = erx_tty:read(r, 64, W3),
    %% VMIN 3, VTIME 1: the first byte starts a timer, and later bytes keep
    %% its deadline, as FreeBSD's interbyte timer does.
    {[], T0} = erx_tty:read_wait(r, raw(3, 1)),
    {[{timer_start, Timer1, 100}], T1} = erx_tty:input(<<"a">>, T0),
    {[], T2} = erx_tty:input(<<"b">>, T1),
    {[], T2} = erx_tty:timer({r, 999}, T2),
    {[{ready, r}], T3} = erx_tty:timer(Timer1, T2),
    {{ok, <<"ab">>}, _} = erx_tty:read(r, 64, T3),
    %% VMIN 0, VTIME 1: the wait starts the timer; its end gives no bytes.
    {[{timer_start, Timer2, 100}], E1} = erx_tty:read_wait(r, raw(0, 1)),
    {[{ready, r}], E2} = erx_tty:timer(Timer2, E1),
    {{ok, <<>>}, _} = erx_tty:read(r, 64, E2),
    {[{timer_start, Timer3, 100}], F1} = erx_tty:read_wait(r, raw(0, 1)),
    {[{timer_cancel, Timer3}, {ready, r}], _} = erx_tty:input(<<"a">>, F1),
    %% VMIN 0, VTIME 0: at once, with whatever waits.
    {[{ready, r}], Z} = erx_tty:read_wait(r, raw(0, 0)),
    {{ok, <<>>}, _} = erx_tty:read(r, 64, Z).

hangup_readies_every_waiter_test() ->
    {[], W} = erx_tty:poll_wait(p, element(2, erx_tty:read_wait(r, erx_tty:new()))),
    {[{ready, p}, {ready, r}], H} = erx_tty:hangup(W),
    {{ok, <<>>}, _} = erx_tty:read(r, 64, H).

%%% Exploration

-record(model, {tty, spec, waiting = #{}, armed = #{}, expired = [], stale = []}).
-record(spec, {ready = [], line = [], stopped = false, hungup = false}).

-define(COOKED_KEYS, [$a, $\s, $\r, $\n, 127, 21, 23, 4, 3, 20, 19, 17, 18]).
-define(RAW_KEYS, [$a, $\r, 3]).

explore_test_() ->
    Cooked = erx_tty:new(),
    Configs =
        [{cooked, Cooked, ?COOKED_KEYS, 4},
         {cooked_quiet, with([], [echo], Cooked), ?COOKED_KEYS, 4},
         {cooked_echonl, with([echonl], [echo, ixon], Cooked), ?COOKED_KEYS, 4},
         {cooked_plain_erase, with([], [echoe, echoctl, opost], Cooked), ?COOKED_KEYS, 4},
         {cooked_noflsh_altwerase, with([noflsh, altwerase], [ixany], Cooked), ?COOKED_KEYS, 4},
         {cooked_no_iexten, with([istrip], [iexten], Cooked), ?COOKED_KEYS, 4},
         {cooked_cr_maps, with([igncr, inlcr], [], Cooked), ?COOKED_KEYS, 4},
         {cooked_no_isig, with([], [isig, icrnl], Cooked), ?COOKED_KEYS, 4},
         {raw_vmin1, raw(1, 0), ?RAW_KEYS, 6},
         {raw_vmin2, raw(2, 0), ?RAW_KEYS, 6},
         {raw_vmin2_vtime1, raw(2, 1), ?RAW_KEYS, 6},
         {raw_vtime1, raw(0, 1), ?RAW_KEYS, 6},
         {raw_poll, raw(0, 0), ?RAW_KEYS, 6},
         {raw_isig_echo, with([isig, echo, ixon], [], raw(2, 1)), ?RAW_KEYS, 6}],
    [{atom_to_list(Name), {timeout, 300, fun() -> explore(Tty, Keys, Depth) end}}
     || {Name, Tty, Keys, Depth} <- Configs].

explore(Tty, Keys, Depth) ->
    explore(#model{tty = Tty, spec = #spec{}}, Keys, Depth, []).

explore(_, _, 0, _) ->
    ok;
explore(Model, Keys, Depth, Path) ->
    lists:foreach(fun(Event) ->
                          Next = step(Event, Model, [Event | Path]),
                          explore(Next, Keys, Depth - 1, [Event | Path])
                  end, events(Model, Keys)).

events(#model{armed = Armed, stale = Stale}, Keys) ->
    [{input, <<Key>>} || Key <- Keys] ++
        [{read_wait, r}, {read_wait, s}, {poll_wait, p}, {cancel, r},
         {read, r, 1}, {read, s, 64}, {output, <<"a\n\tb">>, 3}, toggle, hangup] ++
        [{timer, Timer} || Timer <- lists:sort(maps:keys(Armed))] ++
        [{timer, Timer} || Timer <- lists:sublist(Stale, 1)].

step({input, <<Key>> = Bytes}, #model{tty = Tty, spec = Spec} = M, Path) ->
    {Actions, Tty1} = erx_tty:input(Bytes, Tty),
    Spec1 = spec_key(Key, Spec, erx_tty:termios(Tty)),
    check_keyed(Key, Actions, erx_tty:termios(Tty), Spec#spec.stopped, Path),
    M1 = acted(Actions, input, M#model{tty = Tty1, spec = Spec1}, Path),
    check_interbyte(M, M1, Actions, Path),
    M1;
step({read_wait, Open}, #model{tty = Tty} = M, Path) ->
    {Actions, Tty1} = erx_tty:read_wait(Open, Tty),
    acted(Actions, wait, (forget(Open, M))#model{tty = Tty1,
        waiting = (M#model.waiting)#{Open => read}}, Path);
step({poll_wait, Open}, #model{tty = Tty} = M, Path) ->
    {Actions, Tty1} = erx_tty:poll_wait(Open, Tty),
    acted(Actions, wait, M#model{tty = Tty1, waiting = (M#model.waiting)#{Open => poll}}, Path);
step({cancel, Open}, #model{tty = Tty} = M, Path) ->
    {Actions, Tty1} = erx_tty:cancel(Open, Tty),
    acted(Actions, cancel, (forget(Open, M))#model{tty = Tty1,
        waiting = maps:remove(Open, M#model.waiting)}, Path);
step({timer, Timer}, #model{tty = Tty, armed = Armed} = M, Path) ->
    {Actions, Tty1} = erx_tty:timer(Timer, Tty),
    case maps:is_key(Timer, Armed) of
        true ->
            {Open, _} = Timer,
            property(Actions =:= [{ready, Open}], timer_end, Path),
            acted(Actions, {timer, Timer},
                  M#model{tty = Tty1, armed = maps:remove(Timer, Armed),
                          expired = [Open | M#model.expired]}, Path);
        false ->
            property(Actions =:= [], stale_timer, Path),
            M#model{tty = Tty1}
    end;
step({read, Open, Max}, #model{tty = Tty, spec = Spec} = M, Path) ->
    {Got, Tty1} = erx_tty:read(Open, Max, Tty),
    Expired = lists:member(Open, M#model.expired),
    {Want, Spec1} = spec_read(Max, Expired, Spec, erx_tty:termios(Tty)),
    property(Got =:= Want, read_differs, Path),
    M#model{tty = Tty1, spec = Spec1, expired = lists:delete(Open, M#model.expired)};
step({output, Bytes, Room}, #model{tty = Tty, spec = Spec} = M, Path) ->
    {Taken, Out, Tty1} = erx_tty:output(Bytes, Room, Tty),
    Opost = has(opost, erx_tty:termios(Tty)),
    property(byte_size(Out) =< Room, output_over_room, Path),
    property(not Spec#spec.stopped orelse Taken =:= 0, output_while_stopped, Path),
    property(Opost orelse Out =:= binary:part(Bytes, 0, Taken), opost_clear_changes_bytes, Path),
    M#model{tty = Tty1};
step(toggle, #model{tty = Tty, spec = Spec} = M, Path) ->
    Termios = erx_tty:termios(Tty),
    #{lflag := L} = Termios,
    Flipped = case lists:member(icanon, L) of
                  true -> L -- [icanon];
                  false -> [icanon | L]
              end,
    {ok, Actions, Tty1} = erx_tty:set(Termios#{lflag := Flipped}, Tty),
    Spec1 = spec_switch(Spec, Termios#{lflag := Flipped}),
    acted(Actions, set, M#model{tty = Tty1, spec = Spec1, expired = []}, Path);
step(hangup, #model{tty = Tty, spec = Spec} = M, Path) ->
    {Actions, Tty1} = erx_tty:hangup(Tty),
    acted(Actions, hangup, M#model{tty = Tty1, spec = Spec#spec{hungup = true}}, Path).

forget(Open, #model{expired = Expired} = M) ->
    M#model{expired = lists:delete(Open, Expired)}.

%% The actions of one event, in order, then the invariants of the state.
acted(Actions, Cause, M0, Path) ->
    M = lists:foldl(fun(Action, M) -> act(Action, Cause, M, Path) end, M0, Actions),
    Termios = erx_tty:termios(M#model.tty),
    property(spec_waiting(M#model.spec, Termios) =:= erx_tty:waiting(M#model.tty),
             waiting_differs, Path),
    maps:foreach(
      fun(Open, Kind) ->
              property(not spec_ready(Kind, M#model.spec, Termios), lost_wakeup, Path),
              Timers = [T || {O, _} = T <- maps:keys(M#model.armed), O =:= Open],
              property(lists:member(length(Timers), spec_timers(Kind, M#model.spec, Termios)),
                       timer_discipline, Path)
      end, M#model.waiting),
    Idle = [T || {O, _} = T <- maps:keys(M#model.armed), not maps:is_key(O, M#model.waiting)],
    property(Idle =:= [], timer_without_waiter, Path),
    M.

act({timer_cancel, Timer}, _, #model{armed = Armed, stale = Stale} = M, Path) ->
    property(maps:is_key(Timer, Armed), timer_cancel_unknown, Path),
    M#model{armed = maps:remove(Timer, Armed), stale = [Timer | Stale]};
act({timer_start, {Open, _} = Timer, Ms}, _, #model{armed = Armed} = M, Path) ->
    #{cc := #{vtime := Time}} = erx_tty:termios(M#model.tty),
    property(Ms =:= Time * 100 andalso not maps:is_key(Timer, Armed), timer_start, Path),
    M#model{armed = Armed#{Timer => Open}};
act({ready, Open}, Cause, #model{waiting = Waiting, spec = Spec} = M, Path) ->
    Kind = maps:get(Open, Waiting, none),
    Termios = erx_tty:termios(M#model.tty),
    Timed = case Cause of
                {timer, {Open, _}} -> true;
                _ -> false
            end,
    property(Kind =/= none, ready_without_waiter, Path),
    property(Timed orelse spec_ready(Kind, Spec, Termios), early_wakeup, Path),
    M#model{waiting = maps:remove(Open, Waiting)};
act(_, _, M, _) ->
    M.

%% Echo, signals and VSTATUS for one received byte.
check_keyed(Key, Actions, Termios, Stopped, Path) ->
    Char = case has(istrip, Termios) of
               true -> Key band 16#7f;
               false -> Key
           end,
    Echo = iolist_to_binary([Bytes || {echo, Bytes} <- Actions]),
    Signals = [A || A <- Actions, A =:= info orelse element(1, A) =:= signal],
    Isig = has(isig, Termios),
    Status = Isig andalso has(icanon, Termios) andalso has(iexten, Termios)
        andalso cc(vstatus, Char, Termios),
    Quiet = not has(echo, Termios),
    property(not Quiet orelse has(echonl, Termios) orelse
                 Echo =:= binary:copy(<<7>>, byte_size(Echo)),
             echo_without_echo, Path),
    property(Isig orelse Signals =:= [], signal_without_isig, Path),
    property(Status =:= lists:member(info, Actions), vstatus, Path),
    property(not Status orelse Echo =:= <<>>, vstatus_echoed, Path),
    property(not (Isig andalso cc(vintr, Char, Termios)) orelse
                 lists:member({signal, sigint}, Actions), vintr, Path),
    property(Stopped orelse not lists:member(start_output, Actions), start_unstopped, Path),
    property(not (Stopped andalso Signals =/= []) orelse lists:member(start_output, Actions),
             signal_left_output_stopped, Path).

%% Bytes that arrive for a raw read with VMIN and VTIME above 0 start its
%% timer when it has none and leave a running one alone: one deadline after
%% the first byte, as FreeBSD's interbyte timer sets it.
check_interbyte(#model{spec = #spec{ready = Before}, armed = Armed},
                #model{waiting = Waiting, spec = Spec} = M, Actions, Path) ->
    #{cc := #{vmin := Min, vtime := Time}} = Termios = erx_tty:termios(M#model.tty),
    Arrived = not has(icanon, Termios) andalso length(Spec#spec.ready) > length(Before),
    Started = fun(Open) -> lists:any(fun({timer_start, {O, _}, _}) -> O =:= Open;
                                        (_) -> false
                                     end, Actions)
              end,
    [property(Started(Open) =/= lists:member(Open, maps:values(Armed)),
              interbyte_deadline, Path)
     || Arrived, Min > 0, Time > 0, {Open, read} <- maps:to_list(Waiting)],
    ok.

property(true, _, _) -> ok;
property(false, Name, Path) -> error({property, Name, lists:reverse(Path)}).

%%% The reference: what a reader may get, by FreeBSD's rules, as lists.

spec_key(Key, Spec0, Tm) ->
    Spec = case has(ixany, Tm) of
               true -> Spec0#spec{stopped = false};
               false -> Spec0
           end,
    C = case has(istrip, Tm) of
            true -> Key band 16#7f;
            false -> Key
        end,
    Isig = has(isig, Tm),
    Status = Isig andalso has(icanon, Tm) andalso has(iexten, Tm) andalso cc(vstatus, C, Tm),
    Signal = Isig andalso lists:any(fun(V) -> cc(V, C, Tm) end, [vintr, vquit, vsusp]),
    Flow = has(ixon, Tm) andalso (cc(vstop, C, Tm) orelse cc(vstart, C, Tm)),
    if
        Status -> Spec#spec{stopped = false};
        Signal ->
            case has(noflsh, Tm) of
                true -> Spec#spec{stopped = false};
                false -> Spec#spec{ready = [], line = [], stopped = false}
            end;
        Flow ->
            Stop = cc(vstop, C, Tm) andalso not Spec#spec.stopped,
            Start = cc(vstart, C, Tm) andalso Spec#spec.stopped,
            Spec#spec{stopped = Stop orelse (Spec#spec.stopped andalso not Start)};
        true ->
            spec_edit(spec_map(C, Tm), Spec, Tm)
    end.

spec_map($\r, Tm) ->
    case {has(igncr, Tm), has(icrnl, Tm)} of
        {true, _} -> ignored;
        {false, true} -> $\n;
        {false, false} -> $\r
    end;
spec_map($\n, Tm) ->
    case has(inlcr, Tm) of
        true -> $\r;
        false -> $\n
    end;
spec_map(C, _) ->
    C.

spec_edit(ignored, Spec, _) ->
    Spec;
spec_edit(C, #spec{ready = Ready, line = Line} = Spec, Tm) ->
    Cooked = has(icanon, Tm),
    Ext = Cooked andalso has(iexten, Tm),
    Erase = Cooked andalso (cc(verase, C, Tm) orelse cc(verase2, C, Tm)),
    Kill = Cooked andalso cc(vkill, C, Tm),
    Word = Ext andalso cc(vwerase, C, Tm),
    Reprint = Ext andalso cc(vreprint, C, Tm),
    if
        Erase, Line =:= [] -> Spec;
        Erase -> Spec#spec{line = lists:droplast(Line)};
        Kill -> Spec#spec{line = []};
        Word -> Spec#spec{line = spec_word(Line, Tm)};
        Reprint -> Spec;
        not Cooked -> Spec#spec{ready = Ready ++ [C]};
        true ->
            case spec_end(C, Tm) of
                true -> Spec#spec{ready = Ready ++ Line ++ [C], line = []};
                false -> Spec#spec{line = Line ++ [C]}
            end
    end.

spec_word(Line, Tm) ->
    White = fun(X) -> X =:= $\s orelse X =:= $\t end,
    case lists:dropwhile(White, lists:reverse(Line)) of
        [] ->
            [];
        [Last | _] = Reversed ->
            Alt = has(altwerase, Tm),
            Same = fun(X) -> not White(X) andalso (not Alt orelse alnum(X) =:= alnum(Last)) end,
            lists:reverse(lists:dropwhile(Same, Reversed))
    end.

alnum(X) -> (X >= $0 andalso X =< $9) orelse (X >= $a andalso X =< $z) orelse (X >= $A andalso X =< $Z).

spec_end(C, Tm) -> C =:= $\n orelse cc(veof, C, Tm) orelse cc(veol, C, Tm).

spec_switch(#spec{ready = Ready, line = Line} = Spec, Tm) ->
    case has(icanon, Tm) of
        false -> Spec#spec{ready = Ready ++ Line, line = []};
        true -> Spec
    end.

%% The first line: {Data, Consumed} with VEOF dropped, or none.
spec_line(Ready, Tm) ->
    case lists:splitwith(fun(C) -> not spec_end(C, Tm) end, Ready) of
        {_, []} -> none;
        {Data, [End | _]} ->
            case cc(veof, End, Tm) of
                true -> {Data, true};
                false -> {Data ++ [End], false}
            end
    end.

spec_waiting(#spec{ready = Ready}, Tm) ->
    case has(icanon, Tm) of
        false -> length(Ready);
        true ->
            case spec_line(Ready, Tm) of
                none -> 0;
                {Data, _} -> length(Data)
            end
    end.

spec_ready(_, #spec{hungup = true}, _) ->
    true;
spec_ready(Kind, #spec{ready = Ready}, #{cc := #{vmin := Min, vtime := Time}} = Tm) ->
    case {has(icanon, Tm), Kind} of
        {true, _} -> spec_line(Ready, Tm) =/= none;
        {false, poll} -> length(Ready) >= 1;
        {false, read} when Min =:= 0, Time =:= 0 -> true;
        {false, read} when Min =:= 0 -> length(Ready) >= 1;
        {false, read} -> length(Ready) >= Min
    end.

%% How many timers a waiting read may have: one when raw with VTIME and VMIN
%% 0 or a byte waits; with VMIN above 0 and no byte left, the timer of bytes
%% another read took may still run, and its end readies a read that finds
%% nothing and waits again.
spec_timers(poll, _, _) ->
    [0];
spec_timers(read, #spec{ready = Ready}, #{cc := #{vmin := Min, vtime := Time}} = Tm) ->
    Timed = not has(icanon, Tm) andalso Time > 0,
    if
        Timed, Min =:= 0; Timed, Ready =/= [] -> [1];
        Timed -> [0, 1];
        true -> [0]
    end.

spec_read(Max, Expired, #spec{ready = Ready, hungup = Hungup} = Spec,
          #{cc := #{vmin := Min, vtime := Time}} = Tm) ->
    case has(icanon, Tm) of
        true ->
            case spec_line(Ready, Tm) of
                none when Hungup -> {{ok, <<>>}, Spec};
                none -> {eagain, Spec};
                {Data, Eof} ->
                    Got = lists:sublist(Data, Max),
                    Gone = case Eof andalso length(Got) =:= length(Data) of
                               true -> length(Got) + 1;
                               false -> length(Got)
                           end,
                    {{ok, list_to_binary(Got)}, Spec#spec{ready = lists:nthtail(Gone, Ready)}}
            end;
        false when Ready =:= [] ->
            case Hungup orelse (Min =:= 0 andalso (Time =:= 0 orelse Expired)) of
                true -> {{ok, <<>>}, Spec};
                false -> {eagain, Spec}
            end;
        false ->
            Got = lists:sublist(Ready, Max),
            {{ok, list_to_binary(Got)}, Spec#spec{ready = lists:nthtail(length(Got), Ready)}}
    end.

%%% Helpers

has(Flag, #{iflag := I, oflag := O, cflag := C, lflag := L}) ->
    lists:member(Flag, I ++ O ++ C ++ L).

cc(Name, Char, #{cc := Chars}) ->
    maps:get(Name, Chars) =/= 255 andalso maps:get(Name, Chars) =:= Char.

%% The tty with flags set and cleared, wherever each belongs.
with(Set, Cleared, Tty) ->
    Termios = erx_tty:termios(Tty),
    Changed = maps:map(fun(Field, Flags) when is_list(Flags) ->
                               Known = erx_abi_termios:flags(Field),
                               (Flags -- Cleared) ++ [F || F <- Set, lists:member(F, Known)];
                          (_, Value) -> Value
                       end, Termios),
    {ok, _, Tty1} = erx_tty:set(Changed, Tty),
    Tty1.

%% As cfmakeraw leaves a tty, with VMIN and VTIME.
raw(Min, Time) ->
    Tty = with([], [ignbrk, brkint, parmrk, istrip, inlcr, igncr, icrnl, ixon, imaxbel, opost,
                    echo, echonl, icanon, isig, iexten], erx_tty:new()),
    Termios = erx_tty:termios(Tty),
    {ok, _, Raw} = erx_tty:set(Termios#{cc := (maps:get(cc, Termios))#{vmin := Min, vtime := Time}},
                               Tty),
    Raw.
