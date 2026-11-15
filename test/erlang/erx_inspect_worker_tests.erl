%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the query worker (docs/design-live.md, "The query worker" and
%% "The runtime agent"): its bounds, its deadlines and what it believes of an
%% agent's answer. Fake agents are local processes standing for domains 10 and
%% up: each answers in the envelope the system connection would put on its frame.
-module(erx_inspect_worker_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(D, 10).

%%% Fake domains.

%% A process record of domain D, number N, with Links links of its own domain.
record(D, N, Links) ->
    Id = {pid, D, N, 0},
    #{schema => erx_schema:schema(), path => [processes, Id], kind => process, id => Id,
      attrs => #{reductions => {runtime, {ok, N}}, state => {runtime, {ok, waiting}},
                 links => {runtime, {ok, [{pid, D, N + K, 0} || K <- lists:seq(1, Links)]}}},
      children => []}.

%% An agent of domain D that answers each question with Answer(Query).
agent(D, Answer) ->
    spawn_link(fun() -> agent_loop(D, Answer) end).

agent_loop(D, Answer) ->
    receive
        {erx_inspect_ask, Alias, Query} ->
            case Answer(Query) of
                stall -> ok;
                Reply -> Alias ! {erx_origin, D, {Alias, Reply}}
            end,
            agent_loop(D, Answer)
    end.

listing(D, Count, Links) ->
    agent(D, fun({entries, [processes]}) -> {ok, [record(D, N, Links) || N <- lists:seq(1, Count)]} end).

stalling(D) ->
    agent(D, fun(_Query) -> stall end).

%% Worker options over View, whose entries are {D, Agent} or the domain
%% service's own {D, Agent, Service}; {D, Agent} stands for a living domain
%% of principal 7 (living/2), and {D, ended} for one that ended.
%% The kernel collector answers as the stopgap's domain library does for
%% another domain's group and budget, ERX_ENOTSUP.
options(View) ->
    #{view => fun(_Scope) -> {ok, [entry(Entry) || Entry <- View]} end,
      kernel => fun(Kind, D) ->
                        {ok, Record} = erx_kernel_records:record(Kind, [domains, D, Kind], 0,
                                                                 {error, ?ERX_ENOTSUP}, 0),
                        Record
                end}.

entry({D, ended}) -> {D, ended, none};
entry({D, Agent}) -> living(D, Agent);
entry({_D, _Agent, _Service} = Entry) -> Entry.

%% A living domain D as the domain service's view gives it.
living(D, Agent) ->
    {D, Agent, #{name => <<"web">>, principal => 7, state => running}}.

%% An agent of domain D that answers [domains, D] with its runtime's counters,
%% as erx_inspect_agent does: the runtime attributes alone.
counting(D) ->
    {ok, #{attrs := Attrs} = Record} = erx_runtime_records:domain(D, #{atoms => 1, ets_tables => 2, modules => 3,
                                                                      processes => 4, run_queue => 5}),
    Runtime = Record#{attrs := maps:filter(fun(_Key, {Reporter, _}) -> Reporter =:= runtime end, Attrs)},
    agent(D, fun({inspect, [domains, Domain], _}) when Domain =:= D -> {ok, Runtime} end).

entries_of(D, Records) ->
    [Record || #{path := [processes, {pid, Domain, _, _}]} = Record <- Records, Domain =:= D].

%%% A worker stays within its bounds.

%% [processes] over eight domains of 1,000 processes each is one page, partial,
%% from a worker that holds one answer at a time within its heap. The page is
%% cut by whichever bound comes first, 1,000 entries or inspect_reply_max
%% encoded bytes: it holds this runtime's own processes, then a whole prefix
%% of the domains' records in the order asked, and when it is cut by bytes the
%% next record, as the worker would give it, does not fit.
eight_domains_give_one_page_test_() ->
    {timeout, 60, fun() ->
        [assert_cut(Links) || Links <- [0, 3]]
    end}.

assert_cut(Links) ->
    Domains = lists:seq(?D, ?D + 7),
    View = [{D, listing(D, 1000, Links)} || D <- Domains],
    {Status, Records} = Answer = erx_inspect_worker:call({entries, [processes]}, all, options(View)),
    ?assertEqual(partial, Status),
    ?assert(erlang:external_size(Answer) =< ?ERX_INSPECT_REPLY_MAX),
    Asked = [record(D, N, Links) || D <- Domains, N <- lists:seq(1, 1000)],
    [First | _] = Given = lists:append([entries_of(D, Records) || D <- Domains]),
    Taken = length(Given),
    ?assertEqual([Path || #{path := Path} <- lists:sublist(Asked, Taken)],
                 [Path || #{path := Path} <- Given]),
    ?assert(length(Records) =:= 1000 orelse
            encoded_bound(Records ++ [as_given(lists:nth(Taken + 1, Asked), First)]) > ?ERX_INSPECT_REPLY_MAX).

%% The inspector's bound on an answer's encoding (docs/design-live.md, "Bounds"):
%% each record's own encoding, plus 32 bytes for the answer around them.
encoded_bound(Records) ->
    32 + lists:sum([erlang:external_size(Record) || Record <- Records]).

%% Record as the worker gives it: its runtime attributes with the others the
%% worker gave Taken, a record of the same kind it took.
as_given(#{attrs := Runtime} = Record, #{attrs := Attrs}) ->
    Record#{attrs := maps:merge(Attrs, Runtime)}.

%% A domain that floods the worker's pid while it asks leaves the answer whole, and
%% the worker takes each message as it comes: when it asks the next domain its
%% queue holds nothing.
flood_leaves_the_answer_whole_test() ->
    Test = self(),
    Flooder = agent(?D, fun({entries, [processes]}) ->
                                receive {worker, Worker} -> ok end,
                                [Worker ! {erx_origin, ?D, {junk, N}} || N <- lists:seq(1, 10000)],
                                {ok, [record(?D, 1, 0)]}
                        end),
    Second = agent(?D + 1, fun({entries, [processes]}) ->
                                   Test ! {asked, self()},
                                   receive go -> ok end,
                                   {ok, [record(?D + 1, 1, 0)]}
                           end),
    {Pid, _Monitor, _Reply} = Worker = erx_inspect_worker:start({entries, [processes]}, all,
                                                                 options([{?D, Flooder}, {?D + 1, Second}])),
    Flooder ! {worker, Pid},
    receive {asked, Second} -> ok end,
    {message_queue_len, Queued} = process_info(Pid, message_queue_len),
    ?assert(Queued =< 1),
    Second ! go,
    {Status, Records} = erx_inspect_worker:await(Worker),
    ?assertEqual(ok, Status),
    ?assertMatch([_], entries_of(?D, Records)),
    ?assertMatch([_], entries_of(?D + 1, Records)).

%% Agents that all stall: the answer comes by the query's own deadline, its
%% listing partial.
stalled_agents_answer_by_the_deadline_test() ->
    View = [{D, stalling(D)} || D <- lists:seq(?D, ?D + 5)],
    Start = erlang:monotonic_time(millisecond),
    {Status, _Records} = erx_inspect_worker:call({entries, [processes]}, all,
                                                 (options(View))#{query_max => 300, agent_wait => 200}),
    ?assertEqual(partial, Status),
    ?assert(erlang:monotonic_time(millisecond) - Start < 700).

%% An agent that never answers: the record of one of its processes arrives within
%% the agent's wait and a margin, the domain given here and every runtime
%% attribute {timeout, 500}.
an_agent_that_never_answers_test() ->
    Path = [processes, {pid, ?D, 5, 0}],
    Start = erlang:monotonic_time(millisecond),
    {ok, #{attrs := Attrs}} = erx_inspect_worker:call({inspect, Path, #{}}, all, options([{?D, stalling(?D)}])),
    ?assert(erlang:monotonic_time(millisecond) - Start < 1000),
    ?assertEqual({service, {ok, ?D}}, maps:get(domain, Attrs)),
    ?assertEqual({runtime, {timeout, 500}}, maps:get(reductions, Attrs)),
    ?assertEqual({runtime, {timeout, 500}}, maps:get(links, Attrs)).

%%% What the worker believes.

%% A schema-valid record that names another of the agent's processes, one whose
%% path and id name another domain, and one carrying an attribute runtime does not
%% report are each dropped whole: the runtime attributes read {error, invalid}.
an_answer_must_agree_with_its_question_test() ->
    Path = [processes, {pid, ?D, 5, 0}],
    Other = record(?D, 6, 0),
    Foreign = record(?D + 1, 5, 0),
    #{attrs := Attrs} = Asked = record(?D, 5, 0),
    Lies = [Other, Foreign, Asked#{attrs := Attrs#{domain => {service, {ok, ?D}}}}],
    [begin
         ?assertMatch({ok, _}, erx_schema:validate_record(Lie)),
         Agent = agent(?D, fun(_Query) -> {ok, Lie} end),
         {ok, #{attrs := Taken}} = erx_inspect_worker:call({inspect, Path, #{}}, all, options([{?D, Agent}])),
         ?assertEqual({runtime, {error, invalid}}, maps:get(reductions, Taken)),
         ?assertEqual({service, {ok, ?D}}, maps:get(domain, Taken))
     end || Lie <- Lies].

%% The record an agent gives of its own process is taken, its attributes runtime's.
an_agreeing_answer_is_taken_test() ->
    Path = [processes, {pid, ?D, 5, 0}],
    #{attrs := Attrs} = Asked = record(?D, 5, 2),
    Agent = agent(?D, fun(_Query) -> {ok, Asked#{attrs := Attrs#{state => {kernel, {ok, running}}}}} end),
    {ok, #{attrs := Taken}} = erx_inspect_worker:call({inspect, Path, #{}}, all, options([{?D, Agent}])),
    ?assertEqual({runtime, {ok, running}}, maps:get(state, Taken)),
    ?assertEqual({runtime, {ok, [{pid, ?D, 6, 0}, {pid, ?D, 7, 0}]}}, maps:get(links, Taken)).

%% A lying agent's listing of another domain's processes is dropped whole.
a_listing_of_another_domain_is_dropped_test() ->
    Liar = agent(?D, fun({entries, [processes]}) -> {ok, [record(?D, 1, 0), record(?D + 1, 1, 0)]} end),
    {Status, Records} = erx_inspect_worker:call({entries, [processes]}, all, options([{?D, Liar}])),
    ?assertEqual(partial, Status),
    ?assertEqual([], entries_of(?D, Records) ++ entries_of(?D + 1, Records)).

%% Of a record it takes, the worker drops every proc_id() of another domain.
another_domains_names_are_dropped_test() ->
    ?assertEqual({partial, [{pid, ?D, 2, 0}]}, erx_inspect_worker:owned({ok, [{pid, ?D, 2, 0}, {pid, 4, 1, 0}]}, ?D)),
    ?assertEqual({ok, [{pid, ?D, 2, 0}]}, erx_inspect_worker:owned({ok, [{pid, ?D, 2, 0}]}, ?D)),
    ?assertEqual(unknown, erx_inspect_worker:owned({ok, {pid, 4, 1, 0}}, ?D)),
    ?assertEqual({ok, {pid, ?D, 1, 0}}, erx_inspect_worker:owned({ok, {pid, ?D, 1, 0}}, ?D)),
    #{attrs := Attrs} = Linked = record(?D, 5, 1),
    Answer = {ok, Linked#{attrs := Attrs#{group_leader => {runtime, {ok, {pid, 4, 1, 0}}}}}},
    {ok, {ok, #{attrs := Taken}}} = erx_inspect_worker:check({inspect, [processes, {pid, ?D, 5, 0}], #{}}, ?D, Answer),
    ?assertEqual({runtime, unknown}, maps:get(group_leader, Taken)).

%% Only the error answers an agent may give are taken; any other shape is invalid.
error_answers_test() ->
    Query = {inspect, [processes, {pid, ?D, 5, 0}], #{}},
    ?assertEqual({ok, {error, scope}}, erx_inspect_worker:check(Query, ?D, {error, scope})),
    [?assertEqual(invalid, erx_inspect_worker:check(Query, ?D, Answer))
     || Answer <- [{error, other}, {ok, self()}, {ok, [record(?D, 5, 0)]}, {ok, record(?D, 5, 0), extra}]],
    ?assertEqual(invalid, erx_inspect_worker:check({entries, [processes]}, ?D, {ok, [record(?D, 1, 0) | tail]})).

%%% Scope.

%% {principal, P} covers only the view's domains: the system domain's own
%% processes are not listed, and a domain outside the view names nothing.
a_principals_scope_is_its_domains_test() ->
    View = [{?D, listing(?D, 3, 0)}],
    {ok, Records} = erx_inspect_worker:call({entries, [processes]}, {principal, 7}, options(View)),
    ?assertEqual(Records, entries_of(?D, Records)),
    ?assertEqual(3, length(Records)),
    ?assertEqual({error, scope},
                 erx_inspect_worker:call({inspect, [processes, {pid, ?D + 1, 1, 0}], #{}}, {principal, 7},
                                         options(View))).

%% An ordinary session's scope, {principal, P}, reaches no machine-wide path
%% but the machine's record, its CPUs and the processes
%% (erx_inspector_tests), and no domain of another principal, the system
%% domain's own records included: each answers as a path that names nothing
%% (docs/design-live.md, "Scopes").
a_session_reads_no_other_principals_domain_test() ->
    View = [{?D, listing(?D, 1, 0)}],
    Ask = fun(Query) -> erx_inspect_worker:call(Query, {principal, 7}, options(View)) end,
    System = erx_kernel_records:system_domain(),
    [?assertEqual({error, scope}, Ask(Query))
     || Query <- [{inspect, [groups], #{}}, {inspect, [budgets], #{}}, {inspect, [kernel], #{}},
                  {inspect, [domains, System], #{}}, {inspect, [domains, System, group], #{}},
                  {inspect, [domains, System, budget], #{}}, {entries, [domains, System, threads]},
                  {inspect, [domains, ?D + 1], #{}}, {inspect, [domains, ?D + 1, group], #{}}]].

%% A domain that ended names nothing, and one without an agent has its runtime
%% attributes unknown, and makes a listing partial.
ended_and_agentless_domains_test() ->
    View = [{?D, ended}, {?D + 1, none}],
    ?assertEqual({error, scope}, erx_inspect_worker:call({inspect, [processes, {pid, ?D, 1, 0}], #{}}, all,
                                                        options(View))),
    {ok, #{attrs := Attrs}} = erx_inspect_worker:call({inspect, [processes, {pid, ?D + 1, 1, 0}], #{}}, all,
                                                     options(View)),
    ?assertEqual({runtime, unknown}, maps:get(state, Attrs)),
    ?assertMatch({partial, _}, erx_inspect_worker:call({entries, [processes]}, all, options(View))).

%%% Answers stay within their bound.

%% A listing whose records pass inspect_reply_max before 1,000 entries is cut by
%% bytes, every entry it holds whole.
a_listing_is_cut_by_bytes_test() ->
    Agent = listing(?D, 700, 16),
    Asked = {ok, [record(?D, N, 16) || N <- lists:seq(1, 700)]},
    ?assert(erlang:external_size(Asked) > ?ERX_INSPECT_REPLY_MAX),
    ?assert(erts_debug:flat_size(Asked) < ?ERX_INSPECT_MESSAGE_HEAP_MIN),
    {Status, Records} = Answer = erx_inspect_worker:call({entries, [processes]}, all, options([{?D, Agent}])),
    ?assertEqual(partial, Status),
    ?assert(length(entries_of(?D, Records)) < 700),
    ?assert(erlang:external_size(Answer) =< ?ERX_INSPECT_REPLY_MAX),
    [?assertMatch({ok, _}, erx_schema:validate_record(Record)) || Record <- Records].

%%% The domains.

%% A principal's scope lists only its own domains, in the listing's record
%% and in its entries, never the system domain's or another principal's,
%% which the domain service's view does not give it (erx_domain_tests
%% checks the view; docs/design-live.md, "Scopes").
a_scoped_listing_holds_only_its_domains_test() ->
    View = [{?D, counting(?D)}, {?D + 2, counting(?D + 2)}],
    Ask = fun(Query) -> erx_inspect_worker:call(Query, {principal, 7}, options(View)) end,
    ?assertMatch({ok, #{kind := listing, children := [?D, ?D + 2]}}, Ask({inspect, [domains], #{}})),
    {ok, Records} = Ask({entries, [domains]}),
    ?assertEqual([[domains, ?D], [domains, ?D + 2]], [Path || #{path := Path} <- Records]),
    ?assertEqual({error, scope}, Ask({inspect, [domains, ?D + 1], #{}})).

%% Scope `all` lists the system domain first, then every living domain the
%% view gives, and no ended one.
every_living_domain_is_listed_at_scope_all_test() ->
    View = [{?D, counting(?D)}, {?D + 1, ended}, {?D + 2, none}],
    System = erx_kernel_records:system_domain(),
    ?assertMatch({ok, #{children := [System, ?D, ?D + 2]}},
                 erx_inspect_worker:call({inspect, [domains], #{}}, all, options(View))).

%% A domain's record: name, principal and state from the domain service, the
%% runtime attributes from its agent, and the thread count, which nothing here
%% collects, unsupported; without an agent the runtime attributes are unknown,
%% and with the view unknown the service's are too.
each_domain_attribute_has_its_status_test() ->
    Ask = fun(View, Path) -> erx_inspect_worker:call({inspect, Path, #{}}, all, #{view => View}) end,
    {ok, #{attrs := Attrs}} = Ask(fun(_) -> {ok, [living(?D, counting(?D))]} end, [domains, ?D]),
    ?assertEqual(#{name => {service, {ok, <<"web">>}}, principal => {service, {ok, 7}},
                   state => {service, {ok, running}}, threads => {kernel, unsupported},
                   atoms => {runtime, {ok, 1}}, ets_tables => {runtime, {ok, 2}}, modules => {runtime, {ok, 3}},
                   processes => {runtime, {ok, 4}}, run_queue => {runtime, {ok, 5}}}, Attrs),
    {ok, #{attrs := Agentless}} = Ask(fun(_) -> {ok, [living(?D, none)]} end, [domains, ?D]),
    ?assertEqual({runtime, unknown}, maps:get(run_queue, Agentless)),
    ?assertEqual({service, {ok, running}}, maps:get(state, Agentless)),
    {ok, #{attrs := Unseen}} = Ask(fun(_) -> unavailable end, [domains, ?D]),
    ?assertEqual({service, unknown}, maps:get(name, Unseen)),
    ?assertEqual({runtime, unknown}, maps:get(run_queue, Unseen)),
    {ok, #{attrs := Late}} = erx_inspect_worker:call({inspect, [domains, ?D], #{}}, all,
                                                    (options([{?D, stalling(?D)}]))#{agent_wait => 50}),
    ?assertEqual({runtime, {timeout, 50}}, maps:get(run_queue, Late)).

%% Another living domain's group and budget are collected here, each kernel
%% attribute unsupported, while an ended domain's and an unknown id's name
%% nothing.
another_domains_group_and_budget_test() ->
    View = [{?D, none}, {?D + 1, ended}],
    Ask = fun(Path) -> erx_inspect_worker:call({inspect, Path, #{}}, all, options(View)) end,
    [begin
         Path = [domains, ?D, Kind],
         {ok, #{kind := Kind, path := Path, attrs := Attrs}} = Ask(Path),
         ?assertNotEqual(#{}, Attrs),
         ?assertEqual([{kernel, unsupported}], lists:usort(maps:values(Attrs)))
     end || Kind <- [group, budget]],
    [?assertEqual({error, scope}, Ask([domains, D, Kind])) || D <- [?D + 1, ?D + 3], Kind <- [group, budget]].

%% The entries at scope `all` hold the system domain's own record first; an
%% unknown view leaves only it, partial.
domain_entries_at_scope_all_test() ->
    System = erx_kernel_records:system_domain(),
    {ok, Records} = erx_inspect_worker:call({entries, [domains]}, all, options([{?D, counting(?D)}])),
    ?assertEqual([[domains, System], [domains, ?D]], [Path || #{path := Path} <- Records]),
    ?assertMatch({partial, [#{path := [domains, System]}]},
                 erx_inspect_worker:call({entries, [domains]}, all, #{view => fun(_) -> unavailable end})).

%% A principal reads its own domain's group and budget, never another
%% principal's, which its view does not hold, nor an ended domain's; with
%% the view unknown no domain's group is read.
a_scoped_caller_reads_only_its_domains_group_test() ->
    View = [{?D, none}, {?D + 1, ended}],
    Ask = fun(Scope, Options, Path) -> erx_inspect_worker:call({inspect, Path, #{}}, Scope, Options) end,
    ?assertMatch({ok, #{kind := group}}, Ask({principal, 7}, options(View), [domains, ?D, group])),
    [?assertEqual({error, scope}, Ask({principal, 7}, options(View), [domains, D, Kind]))
     || D <- [?D + 1, ?D + 2], Kind <- [group, budget]],
    ?assertEqual({error, scope}, Ask(all, #{view => fun(_) -> unavailable end}, [domains, ?D, group])).
