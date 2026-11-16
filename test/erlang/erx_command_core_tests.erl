%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_command_core_tests).
-moduledoc """
erx_command_core, the command server's process table, explored
exhaustively: every sequence of up to ?DEPTH events from an empty table,
over two jobs' session process starters, a program starter for each row
and one for a pid the table does not name, a reservation, the end of each
row's speaker, an await of a job and a job's action. After each event the
exploration checks that ids are given from 2 in order, so none twice;
that a row exists exactly while its speaker lives; that a row's parent
and job follow its starter and a job's rows share one group, its first
row's; and that an awaiter is answered exactly once no row carries its
tag. Beside it: the reservation after 2^31 - 1 is eagain, and kill and
probe reach a row only within their scope.
""".

-include_lib("eunit/include/eunit.hrl").

-define(DEPTH, 6).
-define(MAX, 16#7fffffff).

%% The model the exploration checks the table against.
-record(m, {given = [] :: [pos_integer()],
            %% Each live speaker's rows, by process id.
            speakers = #{} :: #{pid() => [pos_integer()]},
            %% Each awaiter not yet answered, with its tag.
            awaiting = [] :: [{atom(), pid()}],
            fresh = 100 :: pos_integer()}).

exploration_test_() ->
    {timeout, 120, fun() -> explore(erx_command_core:new(), #m{}, ?DEPTH) end}.

explore(_T, _M, 0) ->
    ok;
explore(T, M, Depth) ->
    lists:foreach(fun(Event) ->
                          {T1, M1} = apply_event(Event, T, M),
                          check(T1, M1),
                          explore(T1, M1, Depth - 1)
                  end, events(T)).

events(T) ->
    Pids = [Pid || #{pid := Pid} <- erx_command_core:rows(T)],
    Speakers = lists:usort([H || #{handler := H} <- erx_command_core:rows(T)]),
    [{handler, {process, a}}, {handler, {process, b}}, {handler, {program, 99}},
     {reserve, {process, b}}, {await, a}, {await, b}, {job, a}]
    ++ [{reserve, {process, a}, S} || S <- Speakers]
    ++ [{handler, {program, P}} || P <- Pids]
    ++ [{down, S} || S <- Speakers].

apply_event({handler, Starter}, T, #m{fresh = N} = M) ->
    Key = make_ref(),
    case erx_command_core:step(T, {call, from, self(), {handler, Starter, Key}}) of
        {T1, [{spawn_handler, from, #{starter := Starter0, key := Key0, pid := Id} = Init}]} ->
            ?assertEqual({self(), Key}, {Starter0, Key0}),
            H = fake_pid(N),
            {T2, [{monitor, H}, {reply, from, {ok, H, Id}}]} =
                erx_command_core:step(T1, {spawned, from, Init, H}),
            check_placement(T, Starter, Init),
            {T2, given(Id, H, M#m{fresh = N + 1})};
        {T1, [{reply, from, {error, Errno}}]} ->
            ?assertEqual(T, T1),
            ?assertEqual(esrch, Errno),
            ?assertMatch({program, _}, Starter),
            {T1, M}
    end;
apply_event({reserve, Starter}, T, #m{fresh = N} = M) ->
    reserved(Starter, fake_pid(N), T, M#m{fresh = N + 1});
apply_event({reserve, Starter, Caller}, T, M) ->
    reserved(Starter, Caller, T, M);
apply_event({down, S}, T, #m{speakers = Speakers, awaiting = Awaiting} = M) ->
    {T1, Actions} = erx_command_core:step(T, {down, S}),
    M1 = M#m{speakers = maps:remove(S, Speakers)},
    %% Exactly the awaiters of the tags no row carries any more are answered.
    {Due, Still} = lists:partition(fun({Tag, _}) -> not carries(T1, Tag) end, Awaiting),
    ?assertEqual(lists:sort([{send, A, {programs_ended, Tag}} || {Tag, A} <- Due]), lists:sort(Actions)),
    {T1, M1#m{awaiting = Still}};
apply_event({await, Tag}, T, #m{fresh = N, awaiting = Awaiting} = M) ->
    A = fake_pid(N),
    {T1, Actions} = erx_command_core:step(T, {await, Tag, A}),
    case carries(T, Tag) of
        true -> ?assertEqual([], Actions), {T1, M#m{fresh = N + 1, awaiting = [{Tag, A} | Awaiting]}};
        false -> ?assertEqual([{send, A, {programs_ended, Tag}}], Actions), {T1, M#m{fresh = N + 1}}
    end;
apply_event({job, Tag}, T, M) ->
    {T1, Actions} = erx_command_core:step(T, {job, Tag, pause}),
    ?assertEqual(T, T1),
    ?assertEqual(lists:sort([{send, H, {erx_job, pause}} || #{job := J, handler := H} <- erx_command_core:rows(T), J =:= Tag]),
                 lists:sort(Actions)),
    {T1, M}.

%% A reservation by Caller, a fresh speaker or one that already speaks
%% for a row.
reserved(Starter, Caller, T, M) ->
    {T1, [{monitor, Caller}, {reply, from, {ok, Id, Pgid}}]} =
        erx_command_core:step(T, {call, from, Caller, {reserve, Starter}}),
    {process, Job} = Starter,
    check_placement(T, Starter, #{pid => Id, ppid => 1, job => Job, pgid => Pgid}),
    {T1, given(Id, Caller, M)}.

%% A new row's parent and job follow its starter; its group is its job's
%% existing group, or its own id.
check_placement(T, Starter, #{pid := Id, ppid := Ppid, job := Job, pgid := Pgid}) ->
    Rows = erx_command_core:rows(T),
    case Starter of
        {process, Tag} -> ?assertEqual({1, Tag}, {Ppid, Job});
        {program, P} -> [#{job := PJob}] = [R || #{pid := RP} = R <- Rows, RP =:= P],
                        ?assertEqual({P, PJob}, {Ppid, Job})
    end,
    case [G || #{job := J, pgid := G} <- Rows, J =:= Job] of
        [] -> ?assertEqual(Id, Pgid);
        [G | _] -> ?assertEqual(G, Pgid)
    end.

%% Ids run from 2 in order, so none is given twice.
given(Id, Speaker, #m{given = Given, speakers = Speakers} = M) ->
    ?assertEqual(length(Given) + 2, Id),
    M#m{given = [Id | Given], speakers = Speakers#{Speaker => [Id | maps:get(Speaker, Speakers, [])]}}.

check(T, #m{speakers = Speakers}) ->
    Rows = erx_command_core:rows(T),
    %% A row exists exactly while its speaker lives.
    ?assertEqual(lists:sort([{Id, S} || S := Ids <- Speakers, Id <- Ids]),
                 lists:sort([{Id, S} || #{pid := Id, handler := S} <- Rows])),
    %% A job's rows share one group.
    Groups = lists:usort([{J, G} || #{job := J, pgid := G} <- Rows]),
    ?assertEqual(length(Groups), length(lists:usort([J || {J, _} <- Groups]))).

carries(T, Tag) ->
    lists:any(fun(#{job := J}) -> J =:= Tag end, erx_command_core:rows(T)).

fake_pid(N) ->
    list_to_pid("<0." ++ integer_to_list(N) ++ ".0>").

ids_run_out_at_the_protocol_bound_test() ->
    T0 = erx_command_core:new(?MAX),
    Handler = {handler, {process, a}, make_ref()},
    {T1, [{spawn_handler, f, #{pid := ?MAX} = Init}]} = erx_command_core:step(T0, {call, f, self(), Handler}),
    {T2, _} = erx_command_core:step(T1, {spawned, f, Init, fake_pid(1)}),
    ?assertEqual({T2, [{reply, f, {error, eagain}}]}, erx_command_core:step(T2, {call, f, self(), Handler})),
    ?assertEqual({T2, [{reply, f, {error, eagain}}]},
                 erx_command_core:step(T2, {call, f, self(), {reserve, {process, a}}})).

kill_reaches_a_row_only_within_its_scope_test() ->
    H = fake_pid(1),
    {T1, _} = erx_command_core:step(erx_command_core:new(), {call, f, H, {reserve, {process, a}}}),
    Kill = fun(Scope, Target) -> erx_command_core:step(T1, {call, f, self(), {kill, Scope, Target, sigterm, 7}}) end,
    Probe = fun(Scope, Target) -> erx_command_core:step(T1, {call, f, self(), {probe, Scope, Target}}) end,
    [?assertEqual({T1, [{send, H, {erx_signal, sigterm, 7}}, {reply, f, ok}]}, Kill(Scope, 2))
     || Scope <- [session, {job, a}]],
    [?assertEqual({T1, [{reply, f, {error, esrch}}]}, Kill(Scope, Target))
     || {Scope, Target} <- [{{job, b}, 2}, {session, 1}, {session, 3}]],
    ?assertEqual({T1, [{reply, f, ok}]}, Probe({job, a}, 2)),
    ?assertEqual({T1, [{reply, f, {error, esrch}}]}, Probe({job, b}, 2)).

programs_lists_the_rows_test() ->
    H = fake_pid(1),
    {T1, _} = erx_command_core:step(erx_command_core:new(), {call, f, H, {reserve, {process, a}}}),
    ?assertEqual({T1, [{reply, f, [#{pid => 2, ppid => 1, job => a, pgid => 2, handler => H}]}]},
                 erx_command_core:step(T1, {call, f, self(), programs})).
