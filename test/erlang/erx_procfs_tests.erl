%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of /proc (docs/design-live.md, "The /proc tree"): erx_procfs_core's names,
%% walks, listings and status text from made-up inspector answers, every status kind
%% among them, and erx_procfs's listing of the processes and its snapshot bound over the
%% real inspector. test/host/erx_procfs_test.rb runs them on stock's emulator, also
%% against seeded faults each of which a named case must catch.

-module(erx_procfs_tests).
-include_lib("eunit/include/eunit.hrl").

%%% Names

names_round_trip_through_child_test() ->
    Pid = {pid, 4, 85, 0},
    [?assertEqual({ok, Parent ++ [Segment]}, erx_procfs_core:child(Parent, erx_procfs_core:name(Segment)))
     || {Parent, Segment} <- [{[], processes}, {[], domains}, {[domains], 4}, {[domains, 4], threads},
                              {[domains, 4, threads], 0}, {[cpus], 63}, {[processes], Pid},
                              {[domains, 4, modules], <<"lists">>},
                              {[domains, 4, modules], <<".odd name\t\n%/", 16#c3, 16#a9>>}]].

proc_id_name_is_three_numbers_test() ->
    ?assertEqual(<<"4.85.0">>, erx_procfs_core:name({pid, 4, 85, 0})),
    ?assertEqual(<<"0.4294967295.7">>, erx_procfs_core:name({pid, 0, 4294967295, 7})).

text_names_encode_every_other_byte_test() ->
    ?assertEqual(<<"%2Ea%20b%2F%25%FF">>, erx_procfs_core:name(<<".a b/%", 255>>)),
    ?assertEqual(<<"A-z_0+,:=@">>, erx_procfs_core:name(<<"A-z_0+,:=@">>)).

child_refuses_names_outside_the_encoding_test() ->
    Long = binary:copy(<<"a">>, 766),
    [?assertEqual(error, erx_procfs_core:child(Parent, Name))
     || {Parent, Name} <- [{[], <<>>}, {[], <<".">>}, {[], <<"..">>}, {[], <<"cpus/0">>}, {[], <<"/cpus">>},
                           {[], <<"nothing">>}, {[cpus], <<"007">>}, {[cpus], <<"64">>},
                           {[cpus], <<"-1">>}, {[domains, 4, modules], <<"%41">>},
                           {[domains, 4, modules], <<"%2e">>}, {[domains, 4, modules], <<"a.b">>},
                           {[domains, 4, modules], Long}, {[processes], <<"0.1">>},
                           {[processes], <<"<0.1.0>">>}, {[domains, 4], <<"status">>}]].

%%% Walks

walk_answers_status_without_asking_test() ->
    ?assertEqual({ok, {status, [domains, 4]}},
                 erx_procfs_core:walk([domains, 4], <<"status">>, fun(Q) -> error({asked, Q}) end)).

walk_reads_scope_as_no_entry_test() ->
    Scope = fun({exists, _}) -> {error, scope} end,
    ?assertEqual({error, enoent}, erx_procfs_core:walk([processes], <<"4.85.0">>, Scope)),
    Unsupported = fun(_Question) -> {error, unsupported} end,
    ?assertEqual({ok, {dir, [groups]}}, erx_procfs_core:walk([], <<"groups">>, Unsupported)),
    ?assertEqual({error, enoent}, erx_procfs_core:walk([], <<"nothing">>, Unsupported)).

%% A facet whose requests in flight are all taken answers busy: the path
%% exists, and its status file says the query failed, never that nothing is
%% there.
walk_reads_busy_as_an_entry_test() ->
    Busy = fun({exists, _}) -> {error, busy} end,
    ?assertEqual({ok, {dir, [processes, {pid, 4, 85, 0}]}},
                 erx_procfs_core:walk([processes], <<"4.85.0">>, Busy)),
    ?assertEqual(<<"[error]\n">>, erx_procfs_core:status({error, busy}, development)).

markers_exist_only_where_the_listing_says_test() ->
    Partial = fun({listing, Path}) -> listing(Path, {partial, [0]}) end,
    Unknown = fun({listing, _}) -> {error, unsupported} end,
    Whole = fun({listing, Path}) -> listing(Path, [0, 1]) end,
    ?assertEqual({ok, {partial, [cpus]}}, erx_procfs_core:walk([cpus], <<".partial">>, Partial)),
    ?assertEqual({error, enoent}, erx_procfs_core:walk([cpus], <<".unknown">>, Partial)),
    ?assertEqual({ok, {unknown, [cpus]}}, erx_procfs_core:walk([cpus], <<".unknown">>, Unknown)),
    ?assertEqual({error, enoent}, erx_procfs_core:walk([cpus], <<".partial">>, Whole)),
    ?assertEqual({error, enoent}, erx_procfs_core:walk([], <<".partial">>, Partial)).

%%% Listings

%% A directory whose children the schema names is listed, and its literal
%% children walked, by one question, which of them the scope reaches: no
%% record is gathered, so the root's listing never asks for `[processes]`,
%% whose answer collects every domain's processes.
a_literal_listing_asks_one_question_test() ->
    Lookup = fun({literals, []}) -> {ok, [cpus, processes]};
                (Question) -> error({asked, Question})
             end,
    ?assertEqual([<<"status">>, <<"cpus">>, <<"processes">>], names(erx_procfs_core:listing([], none, Lookup))),
    ?assertEqual({ok, {dir, [processes]}}, erx_procfs_core:walk([], <<"processes">>, Lookup)),
    ?assertEqual({error, enoent}, erx_procfs_core:walk([], <<"kernel">>, Lookup)),
    %% Only declared literals, in the schema's order, whatever the answer holds;
    %% a directory that declares no literal asks nothing.
    Unordered = fun({literals, []}) -> {ok, [log, bogus, processes, cpus]} end,
    ?assertEqual([<<"status">>, <<"cpus">>, <<"processes">>], names(erx_procfs_core:listing([], none, Unordered))),
    ?assertEqual([<<"status">>], names(erx_procfs_core:listing([domains, 4, budget], none, Lookup))).

root_lists_what_the_scope_reaches_test() ->
    ?assertEqual([<<"status">>, <<"cpus">>, <<"groups">>, <<"budgets">>, <<"domains">>, <<"processes">>,
                  <<"apps">>, <<"time">>, <<"ntp">>, <<"kernel">>],
                 names(erx_procfs_core:listing([], none, fun every/1))),
    ?assertEqual([<<"status">>, <<"processes">>], names(erx_procfs_core:listing([], none, fun processes_only/1))).

a_listing_lists_its_ids_and_markers_test() ->
    ?assertEqual([<<"status">>, <<"0">>, <<"1">>],
                 names(erx_procfs_core:listing([cpus], listing([cpus], [0, 1]), fun every/1))),
    ?assertEqual([<<"status">>, <<"0">>, <<".partial">>],
                 names(erx_procfs_core:listing([cpus], listing([cpus], {partial, [0]}), fun every/1))),
    ?assertEqual([<<"status">>, <<".unknown">>],
                 names(erx_procfs_core:listing([groups], {error, unsupported}, fun every/1))),
    ?assertEqual([{<<".unknown">>, {unknown, [groups]}}],
                 tl(erx_procfs_core:listing([groups], unknown_listing([groups]), fun every/1))),
    ?assertEqual([<<"status">>, <<".unknown">>],
                 names(erx_procfs_core:listing([domains, 4, processes], {error, unsupported}, fun every/1))),
    ?assertEqual([<<"status">>, <<"budget">>, <<"group">>, <<"threads">>, <<"modules">>, <<"processes">>],
                 names(erx_procfs_core:listing([domains, 4], none, fun every/1))),
    ?assertEqual([<<"status">>, <<"4.85.0">>],
                 names(erx_procfs_core:listing([processes], listing([processes], [{pid, 4, 85, 0}]), fun every/1))).

%% A principal's tree lists its own domains under domains, as the query worker
%% answers its facet: the system domain's and other principals' are not there,
%% and its own domain's directory is reached.
a_scoped_tree_lists_its_own_domains_test() ->
    View = fun(_Scope) -> {ok, [{10, none, #{name => <<"web">>, principal => 7, state => running}}]} end,
    Lookup = fun({_Question, Path}) -> erx_inspect_worker:call({inspect, Path, #{}}, {principal, 7}, #{view => View}) end,
    ?assertEqual([<<"status">>, <<"10">>], names(erx_procfs_core:listing([domains], Lookup({listing, [domains]}), Lookup))),
    ?assertMatch({ok, {dir, [domains, 10]}}, erx_procfs_core:walk([domains], <<"10">>, Lookup)),
    ?assertEqual({error, enoent}, erx_procfs_core:walk([domains], <<"4">>, Lookup)).

marker_files_never_fabricate_test() ->
    ?assertEqual(<<"left_out\t[unknown]\n">>, erx_procfs_core:marker(partial, listing([cpus], {partial, [0]}))),
    ?assertEqual(<<"[unsupported]\n">>, erx_procfs_core:marker(unknown, {error, unsupported})),
    ?assertEqual(<<"[unknown]\n">>,
                 erx_procfs_core:marker(unknown, unknown_listing([groups]))).

%%% Status files

every_status_kind_is_written_as_itself_test() ->
    Text = erx_procfs_core:status({ok, budget(#{guarantee => {kernel, {ok, 12}},
                                                cap => {kernel, unsupported},
                                                used => {{stopgap, liberx_pool}, {partial, 7}},
                                                carved => {kernel, unknown},
                                                lent => {kernel, {timeout, 500}},
                                                pinned => {kernel, {error, einval}}})}, development),
    ?assertEqual([[<<"guarantee">>, <<"12">>, <<"kernel">>],
                  [<<"cap">>, <<"[unsupported]">>, <<"kernel">>],
                  [<<"used">>, <<"[partial]">>, <<"root pool">>],
                  [<<"carved">>, <<"[unknown]">>, <<"kernel">>],
                  [<<"lent">>, <<"[timeout 500]">>, <<"kernel">>],
                  [<<"pinned">>, <<"[error]">>, <<"kernel">>]], rows(Text)).

an_answer_without_a_record_says_why_test() ->
    ?assertEqual(<<"[unsupported]\n">>, erx_procfs_core:status({error, unsupported}, development)).

fields_escape_and_round_trip_test() ->
    Name = <<"evil\t\n\\", 27, "[2J", 16#c2, 16#9b, "x", 255>>,
    Text = erx_procfs_core:status({ok, process(#{registered_name => {runtime, {ok, Name}}})}, development),
    [Line] = binary:split(Text, <<"\n">>, [global, trim_all]),
    ?assertEqual(nomatch, binary:match(Line, [<<27>>, <<16#c2, 16#9b>>, <<255>>])),
    [<<"registered_name">>, Value, <<"runtime">>] = binary:split(Line, <<"\t">>, [global]),
    ?assertEqual({ok, Name}, erx_text:unescape_field(Value)).

a_record_over_64_kib_is_cut_at_a_line_test() ->
    Line = <<(binary:copy(<<"x">>, 999))/binary, "\n">>,
    Text = erx_procfs_core:cut(lists:duplicate(70, Line)),
    ?assert(byte_size(Text) =< 65536),
    ?assertMatch({_, 10}, binary:match(Text, <<"[partial]\n">>, [{scope, {byte_size(Text) - 10, 10}}])),
    ?assertEqual(Line, binary:part(Text, byte_size(Text) - 1010, 1000)),
    Whole = erx_procfs_core:cut(lists:duplicate(65, Line)),
    ?assertEqual(65000, byte_size(Whole)).

%%% The kernel log

%% /proc/kernel is a directory and its log a file, which a walk reaches
%% without collecting it.
the_kernel_log_is_a_file_test() ->
    Exists = fun({literals, []}) -> {ok, [kernel]};
                ({literals, [kernel]}) -> {ok, [log]}
             end,
    ?assertEqual({ok, {dir, [kernel]}}, erx_procfs_core:walk([], <<"kernel">>, Exists)),
    ?assertEqual({ok, {lines, [kernel, log]}}, erx_procfs_core:walk([kernel], <<"log">>, Exists)),
    ?assertEqual([{<<"status">>, {status, [kernel]}}, {<<"log">>, {lines, [kernel, log]}}],
                 erx_procfs_core:listing([kernel], none, fun every/1)).

log_page(Status, Next, Entries) ->
    {ok, #{schema => 1, path => [kernel, log], kind => log, id => log, attrs => #{}, children => [],
           entries => {Status, Next, Entries}}}.

%% Each line through the field escape: no byte a domain chose is a control
%% on the reader's terminal, and the bytes come back with unescape_field.
log_lines_escape_and_round_trip_test() ->
    Hostile = [<<"#0 1.000000 info evil", 27, "]8;;x", 7, "\\e[2J">>,
               <<"#1 tab\\t", 9, "nl", 10, "end">>,
               <<"#2 ", 16#e2, 16#80, 16#ae, "bidi", 16#c2, 16#9b, "csi", 255>>],
    Text = erx_procfs_core:lines([log_page(ok, 3, lists:enumerate(0, Hostile))]),
    Lines = binary:split(Text, <<"\n">>, [global, trim_all]),
    ?assertEqual(length(Hostile), length(Lines)),
    ?assertEqual(nomatch, binary:match(Text, [<<C>> || C <- lists:seq(0, 31), C =/= $\n] ++
                                                [<<127>>, <<16#c2, 16#9b>>, <<255>>, <<16#e2, 16#80, 16#ae>>])),
    ?assertEqual([{ok, Line} || Line <- Hostile], [erx_text:unescape_field(Line) || Line <- Lines]),
    %% A backslash the log core already wrote is doubled, as design-live.md says.
    ?assertEqual(<<"#1 tab\\\\t\\tnl\\nend">>, lists:nth(2, Lines)).

%% Entries the inspector could not give are a line that says how many, at
%% the start, between entries, after the last entry and between pages.
log_lines_show_what_is_lost_test() ->
    Pages = [log_page(partial, 9, [{3, <<"a">>}, {4, <<"b">>}, {7, <<"c">>}]),
             log_page(ok, 13, [{12, <<"d">>}])],
    ?assertEqual(<<"[missing 3]\na\nb\n[missing 2]\nc\n[missing 1]\n[missing 3]\nd\n">>, erx_procfs_core:lines(Pages)),
    ?assertEqual(<<"a\n">>, erx_procfs_core:lines([log_page(ok, 1, [{0, <<"a">>}])])),
    ?assertEqual(<<>>, erx_procfs_core:lines([log_page(ok, 0, [])])),
    ?assertEqual(<<"[missing 5]\n">>, erx_procfs_core:lines([log_page(ok, 5, [])])).

%% A file that stops short says so, never ends as if whole.
log_lines_never_fabricate_test() ->
    ?assertEqual(<<"a\n[partial]\n">>, erx_procfs_core:lines([log_page(partial, 1, [{0, <<"a">>}])])),
    ?assertEqual(<<"[unsupported]\n">>, erx_procfs_core:lines([{error, unsupported}])),
    ?assertEqual(<<"a\n[error]\n">>,
                 erx_procfs_core:lines([log_page(partial, 1, [{0, <<"a">>}]), {error, failed}])),
    Long = binary:copy(<<"x">>, 999),
    Text = erx_procfs_core:lines([log_page(ok, 70, lists:enumerate(0, lists:duplicate(70, Long)))]),
    ?assert(byte_size(Text) =< 65536),
    ?assertMatch({_, 10}, binary:match(Text, <<"[partial]\n">>, [{scope, {byte_size(Text) - 10, 10}}])).

%% A tree whose scope is not all has no /proc/kernel, as a path that names nothing.
a_scoped_tree_has_no_kernel_log_test() ->
    {ok, Fs} = erx_procfs:init(scoped([4])),
    ?assertEqual({error, enoent}, erx_procfs:walk(erx_procfs_core:root(), <<"kernel">>, Fs)),
    {ok, All} = erx_procfs:init(fun erx_procfs:inspector/1),
    {ok, Kernel, _} = erx_procfs:walk(erx_procfs_core:root(), <<"kernel">>, All),
    ?assertMatch({ok, {lines, [kernel, log]}, _}, erx_procfs:walk(Kernel, <<"log">>, All)).

%%% The tree over the real inspector

the_processes_directory_lists_this_process_test() ->
    {ok, Fs} = erx_procfs:init(fun erx_procfs:inspector/1),
    {ok, Processes, _} = erx_procfs:walk(erx_procfs_core:root(), <<"processes">>, Fs),
    {ok, Handle} = erx_procfs:open(Processes, 0, Fs),
    {ok, Entries} = erx_procfs:readdir(Handle, 0, 256, Fs),
    Names = [Name || {_, _, _, Name} <- Entries],
    ?assertEqual(<<"status">>, hd(Names)),
    ?assert(lists:member(erx_procfs_core:name(erx_inspector:proc_id(self())), Names)),
    {ok, Rest} = erx_procfs:readdir(Handle, 1, 256, Fs),
    ?assertEqual(tl(Entries), Rest),
    ok = erx_procfs:clunk(Handle, Fs),
    Dead = spawn(fun() -> ok end),
    Ref = monitor(process, Dead),
    receive {'DOWN', Ref, process, Dead, _} -> ok end,
    ?assertEqual({error, enoent}, erx_procfs:walk(Processes, erx_procfs_core:name(erx_inspector:proc_id(Dead)), Fs)).

%% The snapshots are of [processes], which the core in this process lists on
%% stock; the root's listing asks for /cpus, whose collector needs
%% erx_object_info's NIF, which stock does not load.
the_257th_snapshot_is_refused_test() ->
    {ok, Fs} = erx_procfs:init(scoped([4])),
    Processes = {dir, [processes]},
    Handles = [element(2, {ok, _} = erx_procfs:open(Processes, 0, Fs)) || _ <- lists:seq(1, 256)],
    ?assertEqual({error, emfile}, erx_procfs:open(Processes, 0, Fs)),
    ok = erx_procfs:clunk(hd(Handles), Fs),
    ?assertMatch({ok, _}, erx_procfs:open(Processes, 0, Fs)),
    ?assertEqual({error, erofs}, erx_procfs:open(Processes, 1, Fs)).

a_crashing_query_answers_eio_and_keeps_its_snapshot_test() ->
    {ok, Fs} = erx_procfs:init(scoped(all)),
    %% The core in this process, not a worker that answers a crash `failed`: on
    %% stock erx_object_info's NIF is not loaded, so the machine's record, which a
    %% status file asks for its build's projection, crashes.
    [?assertEqual({error, eio}, erx_procfs:open({status, [processes, erx_inspector:proc_id(self())]}, 0, Fs)) || _ <- lists:seq(1, 300)],
    ?assertMatch({ok, _}, erx_procfs:open({dir, [processes]}, 0, Fs)).

%% A domain that holds no inspect facet finds every path of its tree
%% `enoent`: no name below the root, no status file and no log, and a
%% listing of the root names nothing but its status.
a_domain_without_the_facet_has_an_empty_tree_test() ->
    {ok, Fs} = erx_procfs:init(fun(_Query) -> {error, no_facet} end),
    Root = erx_procfs_core:root(),
    ?assertEqual({error, enoent}, erx_procfs:walk(Root, <<"processes">>, Fs)),
    ?assertEqual({error, enoent}, erx_procfs:open({status, []}, 0, Fs)),
    ?assertEqual({error, enoent}, erx_procfs:open({lines, [kernel, log]}, 0, Fs)),
    {ok, Handle} = erx_procfs:open(Root, 0, Fs),
    ?assertMatch({ok, [{_, _, _, <<"status">>}]}, erx_procfs:readdir(Handle, 0, 256, Fs)).

%% A tree over a facet that has ended, as a revoked one does, is the tree
%% of a domain without one: each open after the end is `enoent`
%% (design-live.md, "The /proc tree"). A facet that is there but has all
%% its requests in flight answers busy, so the path exists and its status
%% file says the query failed.
an_ended_facet_empties_the_tree_and_a_busy_one_does_not_test() ->
    Dead = spawn(fun() -> ok end),
    Gone = monitor(process, Dead),
    receive {'DOWN', Gone, process, Dead, _} -> ok end,
    Root = erx_procfs_core:root(),
    {ok, Revoked} = erx_procfs:init(fun(Query) -> through(Dead, Query) end),
    ?assertEqual({error, enoent}, erx_procfs:walk(Root, <<"processes">>, Revoked)),
    ?assertEqual({error, enoent}, erx_procfs:open({status, []}, 0, Revoked)),
    Busy = spawn_link(fun Facet() -> receive {'$gen_call', From, _} -> gen:reply(From, {error, busy}), Facet() end end),
    {ok, Full} = erx_procfs:init(fun(Query) -> through(Busy, Query) end),
    ?assertMatch({ok, {dir, [processes]}, _}, erx_procfs:walk(Root, <<"processes">>, Full)),
    {ok, Status} = erx_procfs:open({status, []}, 0, Full),
    ?assertEqual({ok, <<"[error]\n">>}, erx_procfs:read(Status, 0, 4096, Full)),
    unlink(Busy),
    exit(Busy, kill).

%% A query as a domain other than the system domain makes it, through Facet.
through(Facet, Query) ->
    erx_inspector:route(false, Facet, Query, 1000).

%% The tree asks its inspector with no scope of its own: every question is
%% a path and the query's options, never a scope.
the_tree_asks_paths_alone_test() ->
    Me = self(),
    Ask = fun(Query) -> Me ! {asked, Query}, {error, scope} end,
    {ok, Fs} = erx_procfs:init(Ask),
    ?assertEqual({error, enoent}, erx_procfs:walk(erx_procfs_core:root(), <<"kernel">>, Fs)),
    ?assertEqual([{asked, {literals, []}}], flush()),
    ?assertEqual({error, enoent}, erx_procfs:open({status, [processes]}, 0, Fs)),
    ?assertEqual([{asked, {inspect, [processes], #{}}}], flush()).

%% Listing the root over the real inspector, at scope `all` as the system
%% domain's tree asks, gathers no record: no listing is enumerated and the
%% query worker never collects the processes.
the_root_listing_gathers_no_record_test() ->
    {ok, Fs} = erx_procfs:init(fun erx_procfs:inspector/1),
    Gatherers = [{erx_inspector, enumerate, 2}, {erx_inspect_worker, processes, 1}],
    [{module, Module} = code:ensure_loaded(Module) || {Module, _, _} <- Gatherers],
    [1 = erlang:trace_pattern(Gatherer, true, [local]) || Gatherer <- Gatherers],
    erlang:trace(self(), true, [call, set_on_spawn]),
    {Handle, Walked} =
        try
            {ok, Opened} = erx_procfs:open(erx_procfs_core:root(), 0, Fs),
            {Opened, erx_procfs:walk(erx_procfs_core:root(), <<"processes">>, Fs)}
        after
            erlang:trace(self(), false, [call, set_on_spawn]),
            [erlang:trace_pattern(Gatherer, false, [local]) || Gatherer <- Gatherers]
        end,
    ?assertMatch({ok, {dir, [processes]}, _}, Walked),
    {ok, Entries} = erx_procfs:readdir(Handle, 0, 256, Fs),
    ?assertEqual([<<"status">>, <<"cpus">>, <<"groups">>, <<"budgets">>, <<"domains">>, <<"processes">>,
                  <<"apps">>, <<"time">>, <<"ntp">>, <<"kernel">>],
                 [Name || {_, _, _, Name} <- Entries]),
    ?assertEqual([], [Call || {trace, _Pid, call, _} = Call <- flush()]).

%% The literals query answers exactly the declared children whose own
%% query names something, as the tree asked one query per child before,
%% at scope `all` and at a principal's: below the root, the kernel, the
%% system domain, a living domain of the principal's, one that ended and
%% one the view does not hold. Below a domain the answer depends on what
%% exists, not on the schema alone: a living domain's group and budget,
%% and the threads, modules and processes of the system domain alone.
literals_name_what_each_child_s_query_names_test() ->
    View = fun(_Scope) -> {ok, [{10, none, #{name => <<"web">>, principal => 7, state => running}},
                                {11, ended, #{name => <<"old">>, principal => 7, state => ended}}]} end,
    Kernel = fun(Object, Domain) -> kernel_record(Object, Domain) end,
    Options = #{view => View, kernel => Kernel},
    Ask = fun(Query, Scope) -> erx_inspect_worker:call(Query, Scope, Options) end,
    System = erx_kernel_records:system_domain(),
    %% Every declared path with literal children, each domain id as the
    %% system domain, a living domain, an ended one and one the view does
    %% not hold; a literal parent below another variable needs its values here.
    Values = fun({variable, {type, domain_id}}) -> [System, 10, 11, 12];
                (Literal) when is_atom(Literal) -> [Literal]
             end,
    Paths = lists:usort([Path || #{pattern := Pattern} = Declaration <- erx_schema:declarations(),
                                 has_literals(Declaration),
                                 Path <- expand([Values(Segment) || Segment <- Pattern])]),
    ?assert(length(Paths) >= 6),
    [?assertEqual({Path, Scope, by_child(Path, Scope, Ask)}, {Path, Scope, shown(Ask({literals, Path}, Scope))})
     || Scope <- [all, {principal, 7}], Path <- Paths],
    ?assertEqual({ok, [cpus, domains, processes, time]}, Ask({literals, []}, {principal, 7})),
    ?assertEqual({ok, [budget, group]}, Ask({literals, [domains, 10]}, {principal, 7})),
    ?assertEqual({ok, []}, Ask({literals, [domains, 11]}, {principal, 7})),
    ?assertEqual({error, scope}, Ask({literals, [domains, System]}, {principal, 7})),
    ?assertEqual({ok, [budget, group, threads, modules, processes]}, Ask({literals, [domains, System]}, all)).

%% The literal children the tree showed below Path when it asked one query
%% per child: each declared child whose own query does not name nothing.
by_child(Path, Scope, Ask) ->
    {ok, #{children := {literals, Declared}}} = erx_schema:resolve(Path),
    [Literal || Literal <- Declared, erx_procfs_core:named(Ask({inspect, Path ++ [Literal], #{}}, Scope))].

has_literals(#{children := {literals, [_ | _]}}) -> true;
has_literals(_Declaration) -> false.

%% Every path whose segments are one of each list of choices, in order.
expand([]) -> [[]];
expand([Choices | Rest]) -> [[Choice | Tail] || Choice <- Choices, Tail <- expand(Rest)].

%% The literal children the tree shows from a literals answer: none for a
%% path that names nothing, whether outside the scope or gone.
shown({ok, Literals}) -> Literals;
shown({error, scope}) -> [].

kernel_record(budget, Domain) -> budget_record([domains, Domain, budget]);
kernel_record(group, Domain) -> #{schema => 1, path => [domains, Domain, group], kind => group, id => group,
                                  attrs => #{}, children => []}.

budget_record(Path) ->
    (budget(#{}))#{path := Path}.

%%% Helpers

%% A lookup that answers every path, as a facet of scope `all` answers the
%% root's literal children.
every({_Question, _Path}) -> {error, unsupported}.

%% A lookup that answers only `[processes]` among the machine's paths, as a
%% facet of a principal's scope does.
processes_only({literals, []}) -> {ok, [processes]};
processes_only({_Question, [processes]}) -> {error, unsupported};
processes_only({_Question, _Path}) -> {error, scope}.

%% The inspector as a facet of Scope answers it, the core at that scope.
scoped(Scope) ->
    fun({inspect, Path, Options}) -> erx_inspector:inspect(Path, Scope, Options);
       ({literals, Path}) -> erx_inspector:literals(Path, Scope)
    end.

flush() ->
    receive Message -> [Message | flush()]
    after 0 -> []
    end.


listing(Path, Children) ->
    {ok, Record} = erx_schema:validate_record(#{schema => 1, path => Path, kind => listing,
                                                id => lists:last(Path), attrs => #{},
                                                children => Children}),
    {ok, Record}.

budget(Attrs) ->
    #{schema => 1, path => [domains, 4, budget], kind => budget, id => budget, attrs => Attrs,
      children => []}.

process(Attrs) ->
    #{schema => 1, path => [processes, {pid, 4, 85, 0}], kind => process, id => {pid, 4, 85, 0},
      attrs => Attrs, children => []}.

%% A listing whose entries the inspector could not get.
unknown_listing(Path) ->
    {ok, Record} = listing(Path, []),
    {ok, Record#{children := unknown}}.

names(Entries) -> [Name || {Name, _Node} <- Entries].

rows(Text) ->
    [binary:split(Line, <<"\t">>, [global]) || Line <- binary:split(Text, <<"\n">>, [global, trim_all])].
