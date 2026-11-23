%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_code_target, the code service's pure core for one target
%% (docs/design-live.md, "The code server"): a few named scenarios, then the exhaustive
%% exploration its Verification section names.
%%
%% The explorer drives the core from a model of its environment written from the design,
%% not from the core: erx_code's effect layer, which performs the core's actions; the
%% domain service, which starts D1 and, once D1 has ended, D2 of one supervised
%% specification and tells erx_code of each start; the code server of each domain, after
%% the design's four steps; a connection that delivers, delays or drops each message
%% between erx_code and a code server; and a lifeline that ends with erx_code. Its
%% events are two facet loads into D1, a reset of the specification, D1's start, D2's
%% start, D1's end, erx_code's deadline, a code server's deadline, the end of erx_code,
%% and a code server that answers ok, answers an error, sends an out-of-order piece
%% request, or, standing for an alias that leaked, an answer from the other domain to the
%% load in flight. A code server is silent by taking none of its events, and answers late
%% when a deadline is taken first. The first facet load names two modules, the second one
%% of them, so a code server that already runs the second's module skips its blob. Every
%% order of up to ?EVENTS events is tried, with every delivery and drop of a message
%% between them, from every reachable state.
%%
%% These hold after every step, each by the name a failure reports:
%%
%% * one_load: at most one load is in flight, and each ends once;
%% * alias_retired: every alias the core is handed is begun or unaliased at once;
%% * busy: a load or a reset that arrives while a load is in flight is answered busy;
%% * answered_once: every request is answered at most once, and settled: once the load in
%%   flight meets its deadline, every request is answered;
%% * sent_to_resolved: a load goes only to the domain its request resolved to, a start
%%   load only to the domain that started;
%% * after_start: a facet's load goes only to a domain whose start load was confirmed;
%% * published_on_ok: the overlay changes, and a word of publication is sent, only on an
%%   ok in the envelope of the load's domain to the alias of the load in flight (or by a
%%   reset);
%% * word_on_ok: such an ok sends the word of publication to the load's code server;
%% * failed_start_keeps_overlay: a start load that fails leaves the overlay as it was;
%% * start_carries_overlay: a start load carries the overlay published when it was taken;
%% * runs_published: a live domain whose start load is done runs its specification's
%%   published overlay, unless a batch it loaded is still within its deadline;
%% * lifeline: a code server holds published code only while the erx_code that published
%%   it lives;
%% * reset_stops_resolved: a reset stops exactly the domain it resolved;
%% * piece_once: each piece of a load is served at most once.
%%
%% Safety alone is met by a core that refuses everything, so the exploration also has to
%% reach these: D1 ready; D1 running a published overlay of both modules; D2 running its
%% start load's modules; and every piece of every blob served.
-module(erx_code_target_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(EVENTS, 8).
-define(D1, 1).
-define(D2, 2).
-define(RELEASE, <<7:256>>).
-define(LIMIT, 1 bsl 20).
-define(HASH_A, <<1:256>>).
-define(HASH_B, <<2:256>>).
%% Module a takes two pieces, module b one.
-define(A, {<<"a">>, ?HASH_A, 65537}).
-define(B, {<<"b">>, ?HASH_B, 10}).
-define(F1_MANIFEST, [?A, ?B]).
-define(F2_MANIFEST, [?B]).
-define(STORED, #{?HASH_A => 65537, ?HASH_B => 10}).

%% Scenarios.

a_facet_load_publishes_on_ok_and_tells_the_code_server_test() ->
    T1 = confirmed(supervised()),
    Alias = make_ref(),
    {T2, Sent} = erx_code_target:load(f1, Alias, request(?F1_MANIFEST), T1),
    ?assertEqual([{begin_load, Alias, pid(?D1, domain), [?HASH_A, ?HASH_B]},
                  {send, pid(?D1, agent), {erx_code_load, Alias, ?F1_MANIFEST}}], Sent),
    T3 = serves(T2, Alias, [{?HASH_A, 0, 65536}, {?HASH_A, 65536, 1}, {?HASH_B, 0, 10}]),
    {T4, Done} = erx_code_target:received(?D1, {erx_code_loaded, Alias, ok}, T3),
    ?assertEqual([{end_load, Alias}, {send, pid(?D1, agent), {erx_code_published, Alias, lifeline(0)}},
                  {reply, f1, {ok, 1}}], Done),
    ?assertEqual({1, ?F1_MANIFEST}, erx_code_target:overlay(T4)),
    ?assertEqual(none, erx_code_target:in_flight(T4)),
    ?assertEqual({?D1, {confirmed, 0}}, erx_code_target:current(T4)).

a_load_into_a_domain_not_ready_or_busy_is_refused_busy_test() ->
    Alias = make_ref(),
    NotReady = (request(?F1_MANIFEST))#{domain := (domain(?D1))#{ready := false}},
    ?assertEqual([{unalias, Alias}, {reply, f1, {error, busy}}],
                 element(2, erx_code_target:load(f1, Alias, NotReady, supervised()))),
    T1 = confirmed(supervised()),
    {T2, _} = erx_code_target:load(f1, make_ref(), request(?F1_MANIFEST), T1),
    ?assertEqual({T2, [{unalias, Alias}, {reply, f2, {error, busy}}]},
                 erx_code_target:load(f2, Alias, request(?F2_MANIFEST), T2)),
    ?assertEqual({T2, [{reply, r, {error, busy}}]}, erx_code_target:reset(r, ?D1, T2)).

%% The verdicts refuse in the order missing, overlay_full, no_memory, before anything is
%% sent; a domain no specification restarts has no candidate, so its charge is not read.
the_verdicts_refuse_in_order_before_anything_is_sent_test() ->
    T1 = confirmed(supervised()),
    Alias = make_ref(),
    Refused = fun(Why, Request, T) ->
                      ?assertEqual({T, [{unalias, Alias}, {reply, f1, {error, Why}}]},
                                   erx_code_target:load(f1, Alias, Request, T))
              end,
    Short = (request(?F1_MANIFEST))#{charge := no_memory},
    Refused({missing, [?HASH_A]}, Short#{missing := [?HASH_A]}, T1),
    Small = confirmed(erx_code_target:new(#{lifeline => lifeline(0), overlay_limit => 65536,
                                                supervised_flag => true})),
    Refused(overlay_full, Short, Small),
    Refused(no_memory, Short, T1),
    Free = erx_code_target:new(#{lifeline => lifeline(0), overlay_limit => none}),
    ?assertMatch({_, [{begin_load, Alias, _, _}, {send, _, {erx_code_load, Alias, _}}]},
                 erx_code_target:load(f1, Alias, Short, Free)).

a_load_into_a_domain_no_specification_restarts_answers_ok_none_test() ->
    T0 = erx_code_target:new(#{lifeline => lifeline(0), overlay_limit => none}),
    Alias = make_ref(),
    {T1, _} = erx_code_target:load(f1, Alias, request(?F2_MANIFEST), T0),
    T2 = serves(T1, Alias, [{?HASH_B, 0, 10}]),
    {_, Done} = erx_code_target:received(?D1, {erx_code_loaded, Alias, ok}, T2),
    ?assertEqual([{end_load, Alias}, {reply, f1, {ok, none}}], Done),
    ?assertEqual([{reply, r, {error, no_overlay}}], element(2, erx_code_target:reset(r, ?D1, T0))).

%% An answer naming a module outside the load, or a reason outside code_load_reason,
%% which the answer floors do not count, a piece out of order (a later blob while
%% the current one is half fetched among them) and a stray shape each end the load as
%% invalid; the same from another domain, or to another alias, change nothing.
messages_the_load_does_not_expect_end_it_invalid_test() ->
    T1 = confirmed(supervised()),
    Alias = make_ref(),
    {T2, _} = erx_code_target:load(f1, Alias, request([?A]), T1),
    Invalid = [{erx_code_loaded, Alias, {error, {hash_mismatch, <<"b">>}}},
               {erx_code_loaded, Alias, {error, {not_loaded, [{<<"a">>, badfile} | {<<"a">>, badfile}]}}},
               {erx_code_loaded, Alias, {error, {not_loaded, [{<<"a">>, x}, {<<"a">>, x}]}}},
               {erx_code_loaded, Alias, {error, {not_loaded, [{<<"a">>, x}]}}},
               {erx_code_loaded, Alias, {error, {not_loaded, []}}},
               {erx_code_get, Alias, ?HASH_A, 65536},
               {erx_code_get, Alias, ?HASH_B, 0},
               {erx_code_loaded, Alias},
               {junk, Alias, 1}],
    lists:foreach(fun(Message) ->
                          ?assertEqual([{end_load, Alias}, {reply, f1, {error, invalid}}],
                                       element(2, erx_code_target:received(?D1, Message, T2)),
                                       Message)
                  end, Invalid),
    {T3, _} = erx_code_target:load(f1, Alias, request(?F1_MANIFEST), T1),
    Half = serves(T3, Alias, [{?HASH_A, 0, 65536}]),
    ?assertEqual([{end_load, Alias}, {reply, f1, {error, invalid}}],
                 element(2, erx_code_target:received(?D1, {erx_code_get, Alias, ?HASH_B, 0}, Half))),
    ?assertEqual({T2, []}, erx_code_target:received(?D2, {erx_code_loaded, Alias, ok}, T2)),
    ?assertEqual({T2, []}, erx_code_target:received(?D1, {erx_code_loaded, make_ref(), ok}, T2)),
    ?assertEqual({T2, []}, erx_code_target:received(?D1, junk, T2)),
    ?assertEqual({ok, Alias}, erx_code_target:alias({junk, Alias})),
    ?assertEqual(error, erx_code_target:alias({junk, 1})).

%% A piece is cut to the blob erx_code holds, whatever size the manifest states: a request
%% past its stored end, which an overstated Size leads to, ends the load invalid, and a
%% blob the store does not hold, such as one only the release holds, is never served.
pieces_come_only_from_stored_blobs_test() ->
    T1 = confirmed(supervised()),
    Alias = make_ref(),
    Overstated = {<<"b">>, ?HASH_B, 1000000},
    {T2, _} = erx_code_target:load(f1, Alias, request([Overstated]), T1),
    T3 = serves(T2, Alias, [{?HASH_B, 0, 10}]),
    ?assertMatch({_, [{end_load, Alias}, {reply, f1, {error, invalid}}]},
                 erx_code_target:received(?D1, {erx_code_get, Alias, ?HASH_B, 10}, T3)),
    ReleaseOnly = (request(?F1_MANIFEST))#{stored := #{?HASH_A => 65537}},
    {T4, _} = erx_code_target:load(f1, Alias, ReleaseOnly, T1),
    ?assertMatch({_, [{end_load, Alias}, {reply, f1, {error, invalid}}]},
                 erx_code_target:received(?D1, {erx_code_get, Alias, ?HASH_B, 0}, T4)).

%% An overlay loaded over another release is dropped at the next start, which then
%% carries no module.
an_overlay_over_another_release_is_dropped_at_the_start_test() ->
    T1 = confirmed(supervised()),
    Alias = make_ref(),
    {T2, _} = erx_code_target:load(f1, Alias, request(?F2_MANIFEST), T1),
    T3 = serves(T2, Alias, [{?HASH_B, 0, 10}]),
    {T4, _} = erx_code_target:received(?D1, {erx_code_loaded, Alias, ok}, T3),
    Start = make_ref(),
    {T5, Actions} = erx_code_target:started(Start, (domain(?D2))#{release := <<8:256>>}, ?STORED, T4),
    ?assertEqual([{log, {overlay_dropped, 1}}, {begin_load, Start, pid(?D2, domain), []},
                  {send, pid(?D2, agent), {erx_code_load, Start, []}}], Actions),
    ?assertEqual({2, []}, erx_code_target:overlay(T5)).

%% A start load answered with a refusal that names no module of it, as invalid as any
%% other stray answer, fails the start: its domain is closed, the overlay stays and the
%% failure is logged.
a_failed_start_load_closes_the_domain_and_keeps_the_overlay_test() ->
    Start = make_ref(),
    {T1, _} = erx_code_target:started(Start, domain(?D1), ?STORED, supervised()),
    Refusal = {error, {not_loaded, []}},
    {T2, Actions} = erx_code_target:received(?D1, {erx_code_loaded, Start, Refusal}, T1),
    ?assertEqual([{end_load, Start}, {log, {start_load_failed, 0, {error, invalid}}}], Actions),
    ?assertEqual({?D1, closed}, erx_code_target:current(T2)),
    ?assertEqual({0, []}, erx_code_target:overlay(T2)),
    ?assertEqual([{unalias, f}, {reply, f1, {error, busy}}],
                 element(2, erx_code_target:load(f1, f, request(?F2_MANIFEST), T2))).

%% Until a supervised specification's domains carry the supervised flag, their code
%% servers would run a batch whether or not it is published, so a supervised target made
%% without the flag is sent nothing: no load, and no start load.
a_supervised_target_without_the_flag_is_sent_nothing_test() ->
    T0 = erx_code_target:new(#{lifeline => lifeline(0), overlay_limit => ?LIMIT}),
    Start = make_ref(),
    ?assertEqual({T0, [{unalias, Start}]}, erx_code_target:started(Start, domain(?D1), ?STORED, T0)),
    Alias = make_ref(),
    ?assertEqual({T0, [{unalias, Alias}, {reply, f1, {error, enotsup}}]},
                 erx_code_target:load(f1, Alias, request(?F1_MANIFEST), T0)),
    ?assertEqual({T0, [{reply, r, {error, enotsup}}]}, erx_code_target:reset(r, ?D1, T0)).

%% The load erx_code_target sends for the largest load, code_modules_max modules with
%% 255-byte names and sizes past a small integer, fits the code protocol's load floors
%% (docs/design-live.md, "Floors"), which tools/lib/erx/abi_code_bounds.rb computes from
%% the same shapes with a 255-byte node name; a local alias and pid are shorter, so a
%% field this message gains past the model's is what makes it fail.
%% erts_debug:flat_size/1 counts the local heap, near the funnel's count but not it; the
%% funnel's own check of these terms is docs/todo-domains.md's "code bounds" item.
the_largest_load_fits_the_load_floors_test() ->
    Entries = [{<<I:32, (binary:copy(<<$m>>, 251))/binary>>, <<I:256>>, 1 bsl 63}
               || I <- lists:seq(1, ?ERX_CODE_MODULES_MAX)],
    Stored = maps:from_list([{Hash, Size} || {_, Hash, Size} <- Entries]),
    Target = erx_code_target:new(#{lifeline => lifeline(0), overlay_limit => length(Entries) bsl 63,
                                   supervised_flag => true}),
    Alias = make_ref(),
    {_, Sent} = erx_code_target:load(f1, Alias, #{domain => domain(?D1), manifest => Entries, missing => [],
                                                  stored => Stored, charge => ok},
                                     confirmed(Target)),
    ?assertMatch([_], [Message || {send, _, {erx_code_load, _, _} = Message} <- Sent], Sent),
    [Load] = [Message || {send, _, {erx_code_load, _, _} = Message} <- Sent],
    ?assertEqual(Entries, element(3, Load)),
    ?assert(erlang:external_size(Load) =< ?ERX_CODE_LOAD_MAX_FRAME_MIN),
    ?assert(erts_debug:flat_size(Load) =< ?ERX_CODE_LOAD_MESSAGE_HEAP_MIN).

supervised() ->
    erx_code_target:new(#{lifeline => lifeline(0), overlay_limit => ?LIMIT, supervised_flag => true}).

%% D1 started, with its empty start load confirmed.
confirmed(T0) ->
    Start = make_ref(),
    {T1, Sent} = erx_code_target:started(Start, domain(?D1), ?STORED, T0),
    ?assertEqual([{begin_load, Start, pid(?D1, domain), []},
                  {send, pid(?D1, agent), {erx_code_load, Start, []}}], Sent),
    {T2, Done} = erx_code_target:received(?D1, {erx_code_loaded, Start, ok}, T1),
    ?assertEqual([{end_load, Start}, {send, pid(?D1, agent), {erx_code_published, Start, lifeline(0)}}],
                 Done),
    T2.

%% The code server asks for each piece in turn, and erx_code serves exactly it.
serves(T0, Alias, Pieces) ->
    lists:foldl(fun({Hash, Offset, Length}, T) ->
                        {Next, Served} = erx_code_target:received(?D1, {erx_code_get, Alias, Hash, Offset}, T),
                        ?assertEqual([{serve, pid(?D1, agent), Alias, Hash, Offset, Length}], Served),
                        Next
                end, T0, Pieces).

request(Manifest) ->
    #{domain => domain(?D1), manifest => Manifest, missing => [], stored => ?STORED, charge => ok}.

domain(Id) ->
    #{id => Id, pid => pid(Id, domain), agent => pid(Id, agent), ready => true, release => ?RELEASE}.

%% Fixed pids, so the explorer's states compare equal across runs of the same events.
pid(Id, domain) -> list_to_pid("<0.10" ++ integer_to_list(Id) ++ ".0>");
pid(Id, agent) -> list_to_pid("<0.20" ++ integer_to_list(Id) ++ ".0>").

lifeline(Incarnation) -> list_to_pid("<0.30" ++ integer_to_list(Incarnation) ++ ".0>").

%% The exploration.

%% A code server's load. It is fetching, with the piece it asked for (none once every blob
%% it fetches has arrived) and each blob still to fetch with the offset of its next piece,
%% the first being fetched; or loaded, holding the batch until its word of publication
%% comes. first is the first blob it fetches, which an out-of-order request asks for again.
-record(cs_load, {alias :: reference(), start :: boolean(), manifest :: list(),
                  first :: none | binary(),
                  phase :: {fetching, none | {binary(), non_neg_integer()},
                            [{binary(), pos_integer(), non_neg_integer()}]}
                         | loaded}).

%% A code server: waiting for its start load, idle, or busy with one load; ready once its
%% start load was confirmed; the modules it runs beyond its release; and the incarnation
%% of erx_code whose lifeline it monitors.
-record(cs, {stage = waiting_start :: waiting_start | idle | {busy, #cs_load{}},
             ready = false :: boolean(),
             code = #{} :: #{binary() => binary()},
             lifeline = none :: none | non_neg_integer()}).

%% The model. Messages from a code server to erx_code, the domain service's notifications
%% and the monitors' 'DOWN' carry the incarnation of erx_code they were sent to, and reach
%% only that one: the aliases and the registration of an ended erx_code are gone.
-record(m, {core :: erx_code_target:state(),
            incarnation = 0 :: 0 | 1,
            %% The requests made (f1, f2, reset) and the answers each got.
            asked = #{} :: #{atom() => true},
            answers = #{} :: #{atom() => [term()]},
            domains = #{?D1 => unborn, ?D2 => unborn} :: #{1 | 2 => unborn | ended | {live, #cs{}}},
            %% Each code server's mailbox, and each one's messages on their way to erx_code.
            to_cs = #{?D1 => [], ?D2 => []} :: #{1 | 2 => [tuple()]},
            to_erx = #{?D1 => [], ?D2 => []} :: #{1 | 2 => [{0 | 1, term()}]},
            %% The domain service's notifications of a start, and the monitors' 'DOWN's.
            notices = [] :: [{0 | 1, 1 | 2}],
            downs = [] :: [{0 | 1, reference()}],
            %% The domain whose pid erx_code monitors for the load in flight, the alias of
            %% that load, and the pieces served for each alias.
            monitors = #{} :: #{1 | 2 => reference()},
            open = none :: none | reference(),
            served = #{} :: #{reference() => [{binary(), non_neg_integer()}]}}).

explore_test_() ->
    {timeout, 600, fun() ->
                           {Count, Reached} = explore(),
                           ?assertEqual(lists:sort(witnesses()), lists:sort(Reached)),
                           ?debugFmt("~b states explored, up to ~b events", [Count, ?EVENTS])
                   end}.

%% Every reachable state, by a breadth-first search in which events cost one and the
%% connection's deliveries and drops cost nothing, so every state is reached first with
%% the fewest events and explored from there. It returns how many states it saw and
%% which of the witnesses it reached.
explore() ->
    Aliases = maps:from_list([{Event, make_ref()} || Event <- [f1, f2, start_d1, start_d2]]),
    First = #m{core = new_core(0)},
    explore(queue:from_list([{First, 0}]), #{First => 0}, #{}, Aliases).

explore(Queue, Seen, Reached, Aliases) ->
    case queue:out(Queue) of
        {empty, _} ->
            {map_size(Seen), maps:keys(Reached)};
        {{value, {M, Used}}, Rest} ->
            settled(M),
            Witnessed = maps:merge(Reached, maps:from_keys(witnessed(M), true)),
            Steps = [{Cost, Step} || {Cost, Step} <- steps(M), Used + Cost =< ?EVENTS],
            {Next, Seen1} = lists:foldl(
                              fun({Cost, Step}, {Q, S}) ->
                                      M1 = step(Step, M, Aliases),
                                      Total = Used + Cost,
                                      case S of
                                          #{M1 := Best} when Best =< Total -> {Q, S};
                                          _ when Cost =:= 0 -> {queue:in_r({M1, Total}, Q), S#{M1 => Total}};
                                          _ -> {queue:in({M1, Total}, Q), S#{M1 => Total}}
                                      end
                              end, {Rest, Seen}, Steps),
            explore(Next, Seen1, Witnessed, Aliases)
    end.

witnesses() ->
    [d1_ready, d1_runs_both, d2_runs_modules | [{served, H, O} || {H, O} <- pieces()]].

pieces() -> [{?HASH_A, 0}, {?HASH_A, 65536}, {?HASH_B, 0}].

witnessed(M) ->
    Runs = fun(D) -> case domain_state(D, M) of
                         #cs{stage = idle, code = Code} -> Code;
                         _ -> #{}
                     end
           end,
    Served = lists:append(maps:values(M#m.served)),
    [d1_ready || is_record(domain_state(?D1, M), cs), (domain_state(?D1, M))#cs.ready]
        ++ [d1_runs_both || map_size(Runs(?D1)) =:= 2]
        ++ [d2_runs_modules || map_size(Runs(?D2)) > 0]
        ++ [{served, H, O} || {H, O} <- pieces(), lists:member({H, O}, Served)].

new_core(Incarnation) ->
    erx_code_target:new(#{lifeline => lifeline(Incarnation), overlay_limit => ?LIMIT,
                          supervised_flag => true}).

%% The steps the model allows from M: events, which cost one, and the connection's
%% deliveries and drops, which cost nothing.
steps(M) ->
    Events = [E || E <- [f1, f2, reset], not maps:is_key(E, M#m.asked)]
        ++ [start_d1 || domain_state(?D1, M) =:= unborn]
        ++ [start_d2 || domain_state(?D1, M) =:= ended, domain_state(?D2, M) =:= unborn]
        ++ [down_d1 || is_record(domain_state(?D1, M), cs)]
        ++ [erx_deadline || erx_code_target:in_flight(M#m.core) =/= none]
        ++ [erx_end || M#m.incarnation =:= 0]
        ++ [{Act, D} || D <- [?D1, ?D2], Act <- cs_events(domain_state(D, M))]
        ++ [{forged, D} || D <- [?D1, ?D2], forgeable(D, M)],
    Free = [{deliver_cs, D} || D <- [?D1, ?D2], takeable(D, M) =/= none]
        ++ [{drop_cs, D, I} || D <- [?D1, ?D2], I <- positions(maps:get(D, M#m.to_cs))]
        ++ [{deliver_erx, D} || D <- [?D1, ?D2], maps:get(D, M#m.to_erx) =/= []]
        ++ [{drop_erx, D, I} || D <- [?D1, ?D2], I <- positions(maps:get(D, M#m.to_erx))]
        ++ [deliver_notice || M#m.notices =/= []]
        ++ [deliver_down || M#m.downs =/= []],
    [{1, E} || E <- Events] ++ [{0, F} || F <- Free].

positions(List) -> lists:seq(1, length(List)).

domain_state(D, M) ->
    case maps:get(D, M#m.domains) of
        {live, CS} -> CS;
        State -> State
    end.

cs_events(#cs{stage = {busy, #cs_load{phase = {fetching, none, []}, manifest = Manifest} = L}}) ->
    [cs_ok, cs_deadline] ++ [cs_error || Manifest =/= []] ++ [cs_bad_get || L#cs_load.first =/= none];
cs_events(#cs{stage = {busy, #cs_load{phase = {fetching, _, _}} = L}}) ->
    [cs_deadline] ++ [cs_bad_get || L#cs_load.first =/= none];
cs_events(#cs{stage = {busy, #cs_load{phase = loaded}}}) ->
    [cs_deadline];
cs_events(_) ->
    [].

%% The other domain, once started, can send an answer to the load in flight.
forgeable(D, M) ->
    case erx_code_target:in_flight(M#m.core) of
        {_, D} -> false;
        {_, _} -> domain_state(D, M) =/= unborn;
        none -> false
    end.

%% One step: the event or delivery applied to the model, then the properties checked.
step(Step, M0, Aliases) ->
    {M1, Actions} = event(Step, M0, Aliases),
    M = lists:foldl(fun(Action, Acc) -> act(Action, Step, Acc) end, M1, Actions),
    check(#{step => Step, actions => Actions, before => M0, handed => handed(Step, M0, Aliases)}, M),
    M.

%% The alias a step hands the core, if any.
handed(Step, M0, Aliases) when Step =:= f1; Step =:= f2 ->
    case domain_state(?D1, M0) of
        #cs{} -> maps:get(Step, Aliases);
        _ -> none
    end;
handed(deliver_notice, #m{notices = [{Incarnation, D} | _], incarnation = Incarnation}, Aliases) ->
    maps:get(case D of ?D1 -> start_d1; ?D2 -> start_d2 end, Aliases);
handed(_, _, _) ->
    none.

event(Request, M, Aliases) when Request =:= f1; Request =:= f2 ->
    Asked = M#m{asked = (M#m.asked)#{Request => true}},
    case domain_state(?D1, M) of
        #cs{ready = Ready} ->
            Manifest = case Request of f1 -> ?F1_MANIFEST; f2 -> ?F2_MANIFEST end,
            Resolved = #{domain => (domain(?D1))#{ready := Ready}, manifest => Manifest,
                         missing => [], stored => ?STORED, charge => ok},
            core(erx_code_target:load(Request, maps:get(Request, Aliases), Resolved, M#m.core), Asked);
        _ ->
            {Asked, [{reply, Request, {error, scope}}]}
    end;
event(reset, M, _) ->
    core(erx_code_target:reset(reset, live(M), M#m.core), M#m{asked = (M#m.asked)#{reset => true}});
event(start_d1, M, _) ->
    {start(?D1, M), []};
event(start_d2, M, _) ->
    {start(?D2, M), []};
event(down_d1, M, _) ->
    {domain_ends(?D1, M), []};
event(erx_deadline, M, _) ->
    {Alias, _} = erx_code_target:in_flight(M#m.core),
    core(erx_code_target:deadline(Alias, M#m.core), M);
event(erx_end, M, _) ->
    erx_ends(M);
event({Act, D}, M, _) when Act =:= cs_ok; Act =:= cs_error; Act =:= cs_bad_get; Act =:= cs_deadline ->
    {code_server(Act, D, M), []};
event({forged, D}, M, _) ->
    {Alias, _} = erx_code_target:in_flight(M#m.core),
    {to_erx(D, {erx_code_loaded, Alias, ok}, M), []};
event({deliver_cs, D}, M, _) ->
    {deliver_cs(D, M), []};
event({drop_cs, D, I}, M, _) ->
    {M#m{to_cs = (M#m.to_cs)#{D := drop_nth(I, maps:get(D, M#m.to_cs))}}, []};
event({deliver_erx, D} = Step, M, _) ->
    Delivered = M#m{to_erx = (M#m.to_erx)#{D := tl(maps:get(D, M#m.to_erx))}},
    case delivery(Step, M) of
        {D, Message} -> core(erx_code_target:received(D, Message, M#m.core), Delivered);
        none -> {Delivered, []}
    end;
event({drop_erx, D, I}, M, _) ->
    {M#m{to_erx = (M#m.to_erx)#{D := drop_nth(I, maps:get(D, M#m.to_erx))}}, []};
event(deliver_notice, #m{notices = [{Incarnation, D} | Rest]} = M, Aliases) ->
    Delivered = M#m{notices = Rest},
    case handed(deliver_notice, M, Aliases) of
        none -> {Delivered, []};
        Alias when Incarnation =:= M#m.incarnation ->
            core(erx_code_target:started(Alias, domain(D), ?STORED, M#m.core), Delivered)
    end;
event(deliver_down, #m{downs = [{Incarnation, Alias} | Rest]} = M, _) ->
    Delivered = M#m{downs = Rest},
    case Incarnation =:= M#m.incarnation of
        true -> core(erx_code_target:domain_down(Alias, M#m.core), Delivered);
        false -> {Delivered, []}
    end.

%% The code server's message a step hands the core: the head of D's messages to erx_code,
%% when it was sent to the erx_code that runs now.
delivery({deliver_erx, D}, M) ->
    case maps:get(D, M#m.to_erx) of
        [{Incarnation, Message} | _] when Incarnation =:= M#m.incarnation -> {D, Message};
        _ -> none
    end;
delivery(_, _) ->
    none.

core({Core, Actions}, M) -> {M#m{core = Core}, Actions}.

drop_nth(I, List) ->
    {Before, [_ | After]} = lists:split(I - 1, List),
    Before ++ After.

live(M) ->
    case [D || D <- [?D1, ?D2], is_record(domain_state(D, M), cs)] of
        [D] -> D;
        [] -> none
    end.

%% The domain service starts D, whose code server reports, and tells the erx_code
%% registered at that moment.
start(D, M) ->
    M#m{domains = (M#m.domains)#{D := {live, #cs{}}},
        notices = M#m.notices ++ [{M#m.incarnation, D}]}.

%% D ends: its messages in flight to it are lost, and the monitor of a load to it fires.
domain_ends(D, M) ->
    Downs = case M#m.monitors of
                #{D := Alias} -> [{M#m.incarnation, Alias}];
                _ -> []
            end,
    M#m{domains = (M#m.domains)#{D := ended}, to_cs = (M#m.to_cs)#{D := []},
        downs = M#m.downs ++ Downs, monitors = maps:remove(D, M#m.monitors)}.

%% erx_code ends: every facet waiting on it answers failed, its lifeline ends, and so
%% does every code server that monitors it; it restarts with nothing.
erx_ends(M0) ->
    Waiting = [R || R <- maps:keys(M0#m.asked), not maps:is_key(R, M0#m.answers)],
    M1 = M0#m{core = new_core(1), incarnation = 1, monitors = #{}, open = none},
    Ended = lists:foldl(fun(D, M) ->
                                case domain_state(D, M) of
                                    #cs{lifeline = 0} -> domain_ends(D, M);
                                    _ -> M
                                end
                        end, M1, [?D1, ?D2]),
    {Ended, [{reply, R, {error, failed}} || R <- Waiting]}.

to_erx(D, Message, M) ->
    M#m{to_erx = (M#m.to_erx)#{D := maps:get(D, M#m.to_erx) ++ [{M#m.incarnation, Message}]}}.

to_cs(D, Message, M) ->
    case domain_state(D, M) of
        #cs{} -> M#m{to_cs = (M#m.to_cs)#{D := maps:get(D, M#m.to_cs) ++ [Message]}};
        _ -> M
    end.

put_cs(D, CS, M) ->
    M#m{domains = (M#m.domains)#{D := {live, CS}}}.

%% The code server's events (the design's steps 3 and 4 and its deadline).
code_server(cs_ok, D, M) ->
    #cs{stage = {busy, L}} = CS = domain_state(D, M),
    to_erx(D, {erx_code_loaded, L#cs_load.alias, ok},
           put_cs(D, CS#cs{stage = {busy, L#cs_load{phase = loaded}}}, M));
code_server(cs_error, D, M) ->
    #cs{stage = {busy, #cs_load{alias = Alias, manifest = [{Name, _, _} | _]} = L}} = CS = domain_state(D, M),
    Answered = to_erx(D, {erx_code_loaded, Alias, {error, {not_loaded, [{Name, badfile}]}}}, M),
    case L#cs_load.start of
        true -> domain_ends(D, Answered);
        false -> put_cs(D, CS#cs{stage = idle}, Answered)
    end;
code_server(cs_bad_get, D, M) ->
    #cs{stage = {busy, #cs_load{alias = Alias, first = First}}} = domain_state(D, M),
    to_erx(D, {erx_code_get, Alias, First, 0}, M);
code_server(cs_deadline, D, M) ->
    #cs{stage = {busy, L}} = CS = domain_state(D, M),
    case L of
        #cs_load{phase = {fetching, _, _}, start = false} -> put_cs(D, CS#cs{stage = idle}, M);
        _ -> domain_ends(D, M)
    end.

%% The message the code server takes next, if any: a load only when it has none, and
%% otherwise the first message to its load's alias; a message to another alias is
%% dropped when it comes first.
takeable(D, M) ->
    case domain_state(D, M) of
        #cs{stage = {busy, #cs_load{}}} ->
            case [I || {I, Message} <- lists:enumerate(maps:get(D, M#m.to_cs)),
                       element(1, Message) =/= erx_code_load] of
                [I | _] -> I;
                [] -> none
            end;
        #cs{} ->
            case maps:get(D, M#m.to_cs) of
                [_ | _] -> 1;
                [] -> none
            end;
        _ ->
            none
    end.

deliver_cs(D, M) ->
    I = takeable(D, M),
    Queue = maps:get(D, M#m.to_cs),
    Taken = M#m{to_cs = (M#m.to_cs)#{D := drop_nth(I, Queue)}},
    take(D, lists:nth(I, Queue), domain_state(D, M), Taken).

%% Step 1: a module already current is skipped; every other blob is fetched.
take(D, {erx_code_load, Alias, Manifest}, #cs{stage = Stage, code = Code} = CS, M)
  when Stage =:= idle; Stage =:= waiting_start ->
    Fetch = [{Hash, Size, 0} || {Name, Hash, Size} <- Manifest, maps:get(Name, Code, none) =/= Hash],
    L = #cs_load{alias = Alias, start = Stage =:= waiting_start, manifest = Manifest,
                 first = case Fetch of [{H, _, _} | _] -> H; [] -> none end,
                 phase = {fetching, none, Fetch}},
    ask(D, L, CS, M);
%% Step 2: the piece asked for arrives, and the next is asked for.
take(D, {erx_code_piece, Alias, Hash, Offset, Length},
     #cs{stage = {busy, #cs_load{alias = Alias,
                                 phase = {fetching, {Hash, Offset}, [{Hash, Size, Offset} | Later]}} = L}} = CS,
     M) ->
    Todo = case Offset + Length >= Size of
               true -> Later;
               false -> [{Hash, Size, Offset + Length} | Later]
           end,
    ask(D, L#cs_load{phase = {fetching, none, Todo}}, CS, M);
%% Step 4: the word of publication keeps the batch, and the code server monitors the
%% lifeline from the first confirmed load that names a module.
take(D, {erx_code_published, Alias, Lifeline},
     #cs{stage = {busy, #cs_load{alias = Alias, phase = loaded, manifest = Manifest} = L}, code = Code} = CS,
     M) ->
    Batch = maps:from_list([{Name, Hash} || {Name, Hash, _} <- Manifest]),
    Monitor = monitors(CS#cs.lifeline, Manifest, Lifeline),
    Kept = put_cs(D, CS#cs{stage = idle, ready = CS#cs.ready orelse L#cs_load.start,
                           code = maps:merge(Code, Batch), lifeline = Monitor}, M),
    %% A monitor of a lifeline that has already ended fires at once.
    case Monitor of
        none -> Kept;
        Live when Live =:= M#m.incarnation -> Kept;
        _ -> domain_ends(D, Kept)
    end;
take(_, _, _, M) ->
    M.

%% Ask for the next piece of the blob being fetched, if there is one.
ask(D, #cs_load{phase = {fetching, none, Todo}, alias = Alias} = L, CS, M) ->
    {Asked, Sent} = case Todo of
                        [{Hash, _, Next} | _] -> {{Hash, Next}, to_erx(D, {erx_code_get, Alias, Hash, Next}, M)};
                        [] -> {none, M}
                    end,
    put_cs(D, CS#cs{stage = {busy, L#cs_load{phase = {fetching, Asked, Todo}}}}, Sent).

%% The incarnation of erx_code whose lifeline the code server monitors, from the first
%% confirmed load that names a module.
monitors(none, [_ | _], Lifeline) -> hd([I || I <- [0, 1], lifeline(I) =:= Lifeline]);
monitors(Held, _, _) -> Held.

agent_domain(Agent) ->
    hd([D || D <- [?D1, ?D2], pid(D, agent) =:= Agent]).

%% erx_code's effect layer: each of the core's actions performed on the model.
act({reply, From, Reply}, _, M) ->
    M#m{answers = maps:update_with(From, fun(Earlier) -> Earlier ++ [Reply] end, [Reply], M#m.answers)};
act({send, Agent, Message}, _, M) ->
    to_cs(agent_domain(Agent), Message, M);
act({serve, Agent, Alias, Hash, Offset, Length}, _, M) ->
    Served = maps:get(Alias, M#m.served, []),
    lists:member({Hash, Offset}, Served) andalso violation(piece_once, {Alias, Hash, Offset}),
    to_cs(agent_domain(Agent), {erx_code_piece, Alias, Hash, Offset, Length},
          M#m{served = (M#m.served)#{Alias => [{Hash, Offset} | Served]}});
act({begin_load, Alias, Pid, _}, _, M) ->
    M#m.open =:= none orelse violation(one_load, {begun_while_open, M#m.open}),
    D = hd([D || D <- [?D1, ?D2], pid(D, domain) =:= Pid]),
    Opened = M#m{open = Alias},
    case domain_state(D, M) of
        #cs{} -> Opened#m{monitors = (M#m.monitors)#{D => Alias}};
        _ -> Opened#m{downs = M#m.downs ++ [{M#m.incarnation, Alias}]}
    end;
act({end_load, Alias}, _, M) ->
    M#m.open =:= Alias orelse violation(one_load, {ended_not_open, Alias}),
    M#m{open = none, monitors = maps:filter(fun(_, A) -> A =/= Alias end, M#m.monitors),
        downs = [Down || {_, A} = Down <- M#m.downs, A =/= Alias]};
act({unalias, Alias}, _, M) ->
    M#m.open =/= Alias orelse violation(one_load, {unalias_open, Alias}),
    M;
act({stop_domain, Id}, Step, M) ->
    {Step, Id} =:= {reset, live(M)} orelse violation(reset_stops_resolved, {Step, Id}),
    domain_ends(Id, M);
act({log, _}, _, M) ->
    M.

%% The properties of one step, from what it was, what it did and the model before it,
%% against the model M after it.
check(#{step := Step, actions := Actions, before := M0} = Done, M) ->
    InFlight = erx_code_target:in_flight(M0#m.core),
    OkFromLoad = case {InFlight, delivery(Step, M0)} of
                     {{Alias, D}, {D, {erx_code_loaded, Alias, ok}}} -> true;
                     _ -> false
                 end,
    alias_retired(Done),
    busy(Step, InFlight, M0, M),
    [violation(answered_once, {R, A}) || R := A <- M#m.answers, length(A) > 1],
    [sent_to_resolved(Step, Agent, M0) || {send, Agent, {erx_code_load, _, _}} <- Actions],
    words(Actions, OkFromLoad, InFlight),
    overlay_kept(Step, InFlight, OkFromLoad, M0, M),
    start_carries_overlay(Step, Actions, M0),
    runs_published(M).

alias_retired(#{handed := none}) ->
    ok;
alias_retired(#{handed := Alias, actions := Actions}) ->
    lists:any(fun({unalias, A}) -> A =:= Alias;
                 ({begin_load, A, _, _}) -> A =:= Alias;
                 (_) -> false
              end, Actions) orelse violation(alias_retired, Alias).

%% A request that reached the core while a load was in flight is answered busy: a reset
%% always reaches it, a facet's load once D1 is live.
busy(Step, InFlight, M0, M) ->
    Reached = Step =:= reset orelse (lists:member(Step, [f1, f2]) andalso is_record(domain_state(?D1, M0), cs)),
    Answer = maps:get(Step, M#m.answers, none),
    Reached andalso InFlight =/= none andalso Answer =/= [{error, busy}]
        andalso violation(busy, {Step, Answer}).

%% A word of publication goes out on an ok from the load's domain, and only then, to that
%% load's code server.
words(Actions, OkFromLoad, InFlight) ->
    Words = [{Agent, Alias} || {send, Agent, {erx_code_published, Alias, _}} <- Actions],
    case {OkFromLoad, Words} of
        {false, []} -> ok;
        {false, _} -> violation(published_on_ok, {word, Words});
        {true, _} ->
            {Loaded, D} = InFlight,
            Words =:= [{pid(D, agent), Loaded}] orelse violation(word_on_ok, Words)
    end.

%% The overlay changes only on an ok from the load's domain, at a reset or with
%% erx_code's end; and never when a start load fails.
overlay_kept(Step, InFlight, OkFromLoad, M0, M) ->
    Overlay0 = erx_code_target:overlay(M0#m.core),
    Overlay = erx_code_target:overlay(M#m.core),
    StartEnded = case InFlight of
                     {_, D} -> erx_code_target:current(M0#m.core) =:= {D, starting}
                                   andalso erx_code_target:in_flight(M#m.core) =/= InFlight;
                     none -> false
                 end,
    Changed = Overlay =/= Overlay0 andalso Step =/= erx_end,
    StartEnded andalso Changed andalso not OkFromLoad
        andalso violation(failed_start_keeps_overlay, {Step, Overlay0, Overlay}),
    Changed andalso not OkFromLoad andalso Step =/= reset
        andalso violation(published_on_ok, {Step, Overlay0, Overlay}).

start_carries_overlay(deliver_notice, Actions, M0) ->
    {_, Published} = erx_code_target:overlay(M0#m.core),
    [violation(start_carries_overlay, {Published, Manifest})
     || {send, _, {erx_code_load, _, Manifest}} <- Actions, Manifest =/= Published];
start_carries_overlay(_, _, _) ->
    ok.

%% A load goes only to the domain its request resolved to, D1 for a facet's load, or the
%% domain that started for a start load; a facet's load only once that domain's start
%% load was confirmed.
sent_to_resolved(Step, Agent, M0) ->
    Expected = case Step of
                   F when F =:= f1; F =:= f2 -> ?D1;
                   deliver_notice -> element(2, hd(M0#m.notices));
                   _ -> violation(sent_to_resolved, {Step, Agent})
               end,
    agent_domain(Agent) =:= Expected orelse violation(sent_to_resolved, {Step, Agent}),
    case {Step, domain_state(Expected, M0)} of
        {deliver_notice, _} -> ok;
        {_, #cs{ready = true}} -> ok;
        {_, State} -> violation(after_start, {Step, Expected, State})
    end.

runs_published(#m{core = Core} = M) ->
    {_, Modules} = erx_code_target:overlay(Core),
    Published = maps:from_list([{Name, Hash} || {Name, Hash, _} <- Modules]),
    lists:foreach(
      fun(D) ->
              case domain_state(D, M) of
                  #cs{code = Code, lifeline = Lifeline} = CS ->
                      Code =:= #{} orelse Lifeline =:= M#m.incarnation
                          orelse violation(lifeline, {D, Code, Lifeline}),
                      within_deadline(CS) orelse Code =:= Published
                          orelse violation(runs_published, {D, Code, Published});
                  _ -> ok
              end
      end, [?D1, ?D2]).

%% A code server still booting, or holding a batch its deadline has not yet passed.
within_deadline(#cs{stage = waiting_start}) -> true;
within_deadline(#cs{stage = {busy, #cs_load{phase = loaded}}}) -> true;
within_deadline(#cs{stage = {busy, #cs_load{start = true}}}) -> true;
within_deadline(_) -> false.

%% Once the load in flight meets its deadline, every request is answered.
settled(#m{core = Core} = M) ->
    Settled = case erx_code_target:in_flight(Core) of
                  {Alias, _} ->
                      {_, Actions} = erx_code_target:deadline(Alias, Core),
                      lists:foldl(fun({reply, _, _} = A, Acc) -> act(A, settle, Acc);
                                     (_, Acc) -> Acc
                                  end, M, Actions);
                  none -> M
              end,
    [violation(answered_once, {never_answered, R})
     || R <- maps:keys(M#m.asked), not maps:is_key(R, Settled#m.answers)],
    ok.

violation(Property, Detail) ->
    error({violation, Property, Detail}).
