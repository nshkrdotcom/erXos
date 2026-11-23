%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_code, the code service, loading real modules into the emulator that
%% runs the tests: the missing-blob exchange end to end, a blob one bit off its hash, a
%% batch with one bad module, a module whose name differs from its bytes', a stored blob
%% whose bytes changed, reloads that purge old code, a rollback, and the requests the
%% service refuses. Each module is compiled here, returning its version from version/0,
%% so what runs is observed by calling it. erx_bytes is the host stand-in
%% (test/erlang/host_bytes).

-module(erx_code_tests).

%% The logger handler callback that forwards start-load records to the test.
-export([log/2]).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(A, erx_code_tests_target_a).
-define(B, erx_code_tests_target_b).

service_test_() ->
    {foreach, fun start/0, fun stop/1,
     [fun the_exchange_sends_only_missing_blobs_and_loads_them/0,
      fun a_blob_one_bit_off_its_hash_never_loads/0,
      fun a_batch_with_one_bad_module_changes_no_module/0,
      fun a_module_whose_name_differs_from_its_bytes_never_loads/0,
      fun a_batch_the_code_server_refuses_purges_nothing/0,
      fun a_module_with_an_on_load_function_never_loads/0,
      fun a_stored_blob_whose_bytes_changed_never_loads/0,
      fun reloads_purge_old_code_and_a_rollback_loads_an_older_hash/0,
      fun refused_requests_change_nothing/0,
      fun the_longest_refusal_fits_the_facet_frame_floor/0]}.

start() ->
    _ = [unload(Module) || Module <- [?A, ?B]],
    {ok, Pid} = erx_code:start_link(#{limit => 1 bsl 20}),
    unlink(Pid),
    Pid.

stop(Pid) ->
    gen_server:stop(Pid),
    _ = [unload(Module) || Module <- [?A, ?B]],
    ok.

unload(Module) ->
    _ = code:purge(Module),
    _ = code:delete(Module),
    _ = code:purge(Module),
    ok.

%% A module whose version/0 returns Version and whose wait/0 waits for a message, so a
%% process can stay in one version's code.
beam(Module, Version) ->
    beam(Module, Version, []).

beam(Module, Version, Attributes) ->
    Forms = [{attribute, 1, module, Module},
             {attribute, 2, export, [{version, 0}, {wait, 0}]}]
        ++ Attributes
        ++ [{function, 3, version, 0, [{clause, 3, [], [], [{integer, 3, Version}]}]},
            {function, 4, wait, 0, [{clause, 4, [], [], [{'receive', 4, [{clause, 4, [{atom, 4, stop}], [], [{atom, 4, ok}]}]}]}]}],
    {ok, Module, Bytes} = compile:forms(Forms, [binary]),
    Bytes.

%% A process waiting in the code of Module's version current now.
waiting(Module) ->
    spawn(Module, wait, []).

hash(Bytes) -> crypto:hash(sha256, Bytes).

name(Module) -> atom_to_binary(Module).

%% Sends a blob in pieces of 64 KiB, as the host does.
send(Bytes) ->
    send(hash(Bytes), Bytes, 0).

send(Hash, Bytes, Offset) ->
    Piece = binary:part(Bytes, Offset, min(65536, byte_size(Bytes) - Offset)),
    case erx_code:put_piece(Hash, byte_size(Bytes), Offset, Piece) of
        {ok, {next, Next}} -> send(Hash, Bytes, Next);
        Reply -> Reply
    end.

version(Module) ->
    Module:version().

the_exchange_sends_only_missing_blobs_and_loads_them() ->
    One = beam(?A, 1),
    Two = beam(?B, 2),
    {ok, stored} = send(One),
    ?assertEqual({ok, [hash(Two)]}, erx_code:missing([hash(One), hash(Two)])),
    ?assertEqual({ok, stored}, send(Two)),
    ?assertEqual({ok, []}, erx_code:missing([hash(One), hash(Two)])),
    ?assertEqual(ok, erx_code:load([{name(?A), hash(One)}, {name(?B), hash(Two)}])),
    ?assertEqual({1, 2}, {version(?A), version(?B)}),
    ?assertMatch({ok, [{<<_:256>>, _}]}, erx_code:history(4, ?A)),
    {ok, [{Hash, _Time}]} = erx_code:history(4, name(?A)),
    ?assertEqual(hash(One), Hash),
    ?assertEqual(binary_to_list(binary:encode_hex(hash(One), lowercase)) ++ ".beam", code:which(?A)).

a_blob_one_bit_off_its_hash_never_loads() ->
    One = beam(?A, 1),
    <<First, Rest/binary>> = beam(?A, 2),
    Wrong = <<(First bxor 16#80), Rest/binary>>,
    Named = hash(<<First, Rest/binary>>),
    ok = load_one(?A, One),
    ?assertEqual({error, hash_mismatch}, send(Named, Wrong, 0)),
    ?assertEqual({error, {missing, [Named]}}, erx_code:load([{name(?A), Named}])),
    ?assertEqual(1, version(?A)),
    ?assertEqual(1, length(element(2, erx_code:history(4, ?A)))).

a_batch_with_one_bad_module_changes_no_module() ->
    ok = load_one(?A, beam(?A, 0)),
    Waiting = waiting(?A),
    ok = load_one(?A, beam(?A, 1)),
    ok = load_one(?B, beam(?B, 1)),
    Good = beam(?A, 2),
    Bad = <<"FOR1 not a module">>,
    {ok, stored} = send(Good),
    {ok, stored} = send(Bad),
    ?assertEqual({error, {not_loaded, [{name(?B), badfile}]}},
                 erx_code:load([{name(?A), hash(Good)}, {name(?B), hash(Bad)}])),
    ?assertEqual({1, 1}, {version(?A), version(?B)}),
    ?assert(erlang:check_old_code(?A)),
    ?assert(is_process_alive(Waiting)),
    ?assertEqual(2, length(element(2, erx_code:history(4, ?A)))).

%% The code server refuses a preloaded module, which is sticky, only once the batch is
%% prepared; the old code of the batch's other module, and the process in it, stay.
a_batch_the_code_server_refuses_purges_nothing() ->
    ok = load_one(?A, beam(?A, 0)),
    Waiting = waiting(?A),
    ok = load_one(?A, beam(?A, 1)),
    Two = beam(?A, 2),
    Sticky = beam(erl_prim_loader, 1),
    {ok, stored} = send(Two),
    {ok, stored} = send(Sticky),
    ?assertEqual({error, {not_loaded, [{<<"erl_prim_loader">>, sticky_directory}]}},
                 erx_code:load([{name(?A), hash(Two)}, {<<"erl_prim_loader">>, hash(Sticky)}])),
    ?assertEqual(1, version(?A)),
    ?assert(erlang:check_old_code(?A)),
    ?assert(is_process_alive(Waiting)).

a_module_with_an_on_load_function_never_loads() ->
    OnLoad = beam(?A, 1, [{attribute, 2, on_load, {version, 0}}]),
    {ok, stored} = send(OnLoad),
    ?assertEqual({error, {not_loaded, [{name(?A), on_load_not_allowed}]}}, erx_code:load([{name(?A), hash(OnLoad)}])),
    ?assertEqual(false, code:is_loaded(?A)).

%% The longest answer erx_code gives a code facet, a load of code_modules_max modules
%% with 255-byte names that each fail, fits a frame of code_facet_max_frame_min, the
%% floor the manifest check holds a code facet's grantee to (abi/services/code.txt,
%% tools/lib/erx/abi_code_bounds.rb), in gen_server's reply envelope with a reference
%% of the longest node name; a frame's payload is the term with its version byte.
the_longest_refusal_fits_the_facet_frame_floor() ->
    Bytes = beam(?A, 1),
    {ok, stored} = send(Bytes),
    Names = [iolist_to_binary([integer_to_list(I),
                               lists:duplicate(255 - length(integer_to_list(I)), $m)])
             || I <- lists:seq(1, ?ERX_CODE_MODULES_MAX)],
    Reply = erx_code:load([{Name, hash(Bytes)} || Name <- Names]),
    ?assertMatch({error, {not_loaded, Failed}}
                   when length(Failed) =:= ?ERX_CODE_MODULES_MAX, Reply),
    Node = binary:copy(<<$n>>, 255),
    Ref = binary_to_term(<<131, 90, 5:16, 119, 255, Node/binary,
                           1:32, 1:32, 2:32, 3:32, 4:32, 5:32>>),
    ?assert(erlang:external_size({[alias | Ref], Reply})
            =< ?ERX_CODE_FACET_MAX_FRAME_MIN).

a_module_whose_name_differs_from_its_bytes_never_loads() ->
    Bytes = beam(?A, 1),
    {ok, stored} = send(Bytes),
    ?assertEqual({error, {not_loaded, [{name(?B), badfile}]}}, erx_code:load([{name(?B), hash(Bytes)}])),
    ?assertEqual(false, code:is_loaded(?B)),
    ?assertEqual({ok, []}, erx_code:history(4, ?B)).

a_stored_blob_whose_bytes_changed_never_loads() ->
    ok = load_one(?A, beam(?A, 1)),
    Two = beam(?A, 2),
    {ok, stored} = send(Two),
    %% The store's memory changed after the blob was checked in.
    %% The store is the first field of erx_code's state record.
    sys:replace_state(erx_code, fun(State) ->
                                        #{blobs := Blobs} = Store = element(2, State),
                                        <<First, Rest/binary>> = map_get(hash(Two), Blobs),
                                        Changed = Blobs#{hash(Two) := <<(First bxor 1), Rest/binary>>},
                                        setelement(2, State, Store#{blobs := Changed})
                                end),
    ?assertEqual({error, {hash_mismatch, name(?A)}}, erx_code:load([{name(?A), hash(Two)}])),
    ?assertEqual(1, version(?A)).

reloads_purge_old_code_and_a_rollback_loads_an_older_hash() ->
    Versions = [beam(?A, Version) || Version <- lists:seq(1, 5)],
    [?assertEqual(ok, load_one(?A, Bytes)) || Bytes <- Versions],
    ?assertEqual(5, version(?A)),
    {ok, History} = erx_code:history(4, ?A),
    ?assertEqual(lists:reverse([hash(Bytes) || Bytes <- Versions]), [Hash || {Hash, _Time} <- History]),
    ?assertEqual({ok, []}, erx_code:missing([hash(hd(Versions))])),
    ?assertEqual(ok, erx_code:load([{name(?A), hash(hd(Versions))}])),
    ?assertEqual(1, version(?A)).

refused_requests_change_nothing() ->
    ok = load_one(?A, beam(?A, 1)),
    ?assertEqual({error, bad_request}, erx_code:call({load})),
    ?assertEqual({error, bad_request}, erx_code:call(make_ref())),
    ?assertEqual({error, {bad_manifest, {bad_entry, 1}}}, erx_code:load([{<<"no such/module">>, hash(<<>>)}])),
    ?assertEqual({error, scope}, erx_code:history(5, ?A)),
    ?assertEqual(1, version(?A)).

load_one(Module, Bytes) ->
    {ok, stored} = send(Bytes),
    erx_code:load([{name(Module), hash(Bytes)}]).

%% A crash's reason may hold the host's code: the crash report and the terminate report, which
%% the system domain filters no further, show only the reason's leading atom.
format_status_hides_the_reason_test() ->
    ?assertEqual(#{reason => badmatch},
                 erx_code:format_status(#{reason => {badmatch, <<"SECRET">>}})).

%% A request shows as its leading atom: a request tuple headed by the host's bytes shows none
%% of them.
format_status_hides_a_request_headed_by_bytes_test() ->
    Shown = erx_code:format_status(#{message => {request, {<<"SECRET">>, 1}}}),
    ?assertEqual(nomatch, string:find(io_lib:format("~p", [Shown]), "SECRET")),
    ?assertEqual(#{message => {request, none}}, Shown).

%% Start loads (docs/design-live.md, "The effect layer" and its Verification rows), with stub
%% domain pids and code servers that forward what they receive to the test, and the
%% deadline shortened to ?WAIT. A code server's message reaches erx_code as the runtime
%% delivers one sent to the load's alias: in its domain's envelope, through the alias.

-define(WAIT, 300).
-define(ROW, {configured, storage}).

start_loads_test_() ->
    {foreach, fun start_loads/0, fun stop_loads/1,
     [fun a_start_load_answered_ok_is_published_with_the_lifeline/0,
      fun the_next_domain_ends_the_first_domains_start_load/0,
      fun a_silent_code_server_ends_at_the_deadline_with_one_log_record/0,
      fun a_domain_pid_end_ends_the_start_load_without_a_log_record/0,
      fun an_ok_held_past_the_deadline_publishes_nothing/0,
      fun a_restarted_erx_code_holds_nothing_of_its_predecessors_start_load/0]}.

start_loads() ->
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => self()}),
    {ok, Pid} = erx_code:start_link(#{load_wait => ?WAIT}),
    unlink(Pid),
    Pid.

stop_loads(_) ->
    ok = logger:remove_handler(?MODULE),
    _ = [gen_server:stop(Pid) || Pid <- [whereis(erx_code)], is_pid(Pid)],
    ok.

log(#{msg := {"erx_code: the start load" ++ _, Args}}, #{config := Test}) -> Test ! {logged, Args};
log(_, _) -> ok.

a_start_load_answered_ok_is_published_with_the_lifeline() ->
    log_here(),
    {DomainPid, Agent} = domain(),
    ok = erx_code:started(5, ?ROW, DomainPid, Agent),
    Alias = start_load(Agent),
    Alias ! {erx_origin, 5, {erx_code_loaded, Alias, ok}},
    receive
        {Agent, {erx_code_published, Alias, Lifeline}} -> ?assert(is_process_alive(Lifeline))
    after 1000 -> error(no_word_of_publication)
    end,
    assert_ended(Alias),
    assert_no_log().

the_next_domain_ends_the_first_domains_start_load() ->
    log_here(),
    {D1, A1} = domain(),
    ok = erx_code:started(5, ?ROW, D1, A1),
    Alias1 = start_load(A1),
    {D2, A2} = domain(),
    ok = erx_code:started(6, ?ROW, D2, A2),
    Alias2 = start_load(A2),
    Alias1 ! {erx_origin, 5, {erx_code_loaded, Alias1, ok}},
    Alias2 ! {erx_origin, 6, {erx_code_loaded, Alias2, ok}},
    receive {A2, {erx_code_published, Alias2, _}} -> ok after 1000 -> error(no_word_of_publication) end,
    %% Each stub forwards on its own, so the first domain's word, if sent, may arrive late.
    receive {A1, Late} -> error({published, Late}) after 200 -> ok end,
    assert_ended(Alias1),
    assert_ended(Alias2),
    assert_no_log().

a_silent_code_server_ends_at_the_deadline_with_one_log_record() ->
    log_here(),
    {DomainPid, Agent} = domain(),
    ok = erx_code:started(5, ?ROW, DomainPid, Agent),
    Alias = start_load(Agent),
    receive {logged, Args} -> ?assertEqual([?ROW, 0, {error, timeout}], Args)
    after ?WAIT + 1000 -> error(no_log_record)
    end,
    assert_ended(Alias),
    assert_no_log().

a_domain_pid_end_ends_the_start_load_without_a_log_record() ->
    log_here(),
    {DomainPid, Agent} = domain(),
    ok = erx_code:started(5, ?ROW, DomainPid, Agent),
    Alias = start_load(Agent),
    exit(DomainPid, kill),
    receive {logged, Args} -> error({logged, Args}) after ?WAIT + 200 -> ok end,
    assert_ended(Alias).

%% An ok queued ahead of the load's timer, while erx_code is held past the deadline, is
%% taken after the deadline: it publishes nothing, and the load ends as timed out.
an_ok_held_past_the_deadline_publishes_nothing() ->
    log_here(),
    {DomainPid, Agent} = domain(),
    ok = erx_code:started(5, ?ROW, DomainPid, Agent),
    Alias = start_load(Agent),
    ok = sys:suspend(erx_code),
    Alias ! {erx_origin, 5, {erx_code_loaded, Alias, ok}},
    timer:sleep(?WAIT + 100),
    ok = sys:resume(erx_code),
    receive {logged, Args} -> ?assertEqual([?ROW, 0, {error, timeout}], Args)
    after 1000 -> error(no_log_record)
    end,
    receive {Agent, Word} -> error({published, Word}) after 0 -> ok end,
    assert_ended(Alias).

%% erx_code killed while a supervised domain's start load is in flight: the code server's
%% ok to the old alias reaches no process, and the restarted erx_code holds no alias,
%% timer or monitor of it and sends the next domain an empty start load.
a_restarted_erx_code_holds_nothing_of_its_predecessors_start_load() ->
    {D1, A1} = domain(),
    ok = erx_code:started(5, ?ROW, D1, A1),
    Alias1 = start_load(A1),
    Old = whereis(erx_code),
    Down = monitor(process, Old),
    exit(Old, kill),
    receive {'DOWN', Down, process, Old, killed} -> ok end,
    {ok, New} = erx_code:start_link(#{load_wait => ?WAIT}),
    unlink(New),
    Alias1 ! {erx_origin, 5, {erx_code_loaded, Alias1, ok}},
    ?assertEqual({monitors, []}, process_info(New, monitors)),
    ?assertEqual({message_queue_len, 0}, process_info(New, message_queue_len)),
    {D2, A2} = domain(),
    ok = erx_code:started(6, ?ROW, D2, A2),
    Alias2 = start_load(A2),
    ?assertNotEqual(Alias1, Alias2).

%% A stub domain pid, and a stub code server that forwards what it receives to the test.
domain() ->
    Test = self(),
    {spawn(fun() -> receive stop -> ok end end),
     spawn(fun Forward() -> receive Message -> Test ! {self(), Message}, Forward() end end)}.

%% The empty start load the stub code server Agent received, and its alias.
start_load(Agent) ->
    receive {Agent, {erx_code_load, Alias, []}} -> Alias
    after 1000 -> error(no_start_load)
    end.

%% A load's end deactivated its alias, so a message sent to it reaches no process, and
%% removed the domain pid's monitor.
assert_ended(Alias) ->
    Erx = whereis(erx_code),
    _ = sys:get_state(Erx),
    ok = sys:suspend(Erx),
    Alias ! {erx_origin, 5, {erx_code_loaded, Alias, ok}},
    Queued = process_info(Erx, message_queue_len),
    ok = sys:resume(Erx),
    ?assertEqual({message_queue_len, 0}, Queued),
    ?assertEqual({monitors, []}, process_info(Erx, monitors)).

%% Start-load log records reach the case that calls it: the foreach's setup runs in
%% another process.
log_here() ->
    ok = logger:update_handler_config(?MODULE, config, self()).

assert_no_log() ->
    receive {logged, Args} -> error({logged, Args}) after 200 -> ok end.

%% The lifeline (docs/design-live.md, "When erx_code ends") ends with erx_code however
%% erx_code ends, normal included.
the_lifeline_ends_with_erx_code_test_() ->
    [{atom_to_list(Reason), fun() -> lifeline_ends(Reason) end} || Reason <- [normal, shutdown, kill]].

lifeline_ends(Reason) ->
    {ok, Pid} = erx_code:start_link(#{}),
    unlink(Pid),
    {DomainPid, Agent} = domain(),
    ok = erx_code:started(5, ?ROW, DomainPid, Agent),
    Alias = start_load(Agent),
    Alias ! {erx_origin, 5, {erx_code_loaded, Alias, ok}},
    Lifeline = receive {Agent, {erx_code_published, Alias, L}} -> L after 1000 -> error(no_word) end,
    Down = monitor(process, Lifeline),
    case Reason of
        kill -> exit(Pid, kill);
        _ -> gen_server:stop(Pid, Reason, infinity)
    end,
    receive {'DOWN', Down, process, Lifeline, _} -> ok
    after 1000 -> exit(Lifeline, kill), error(lifeline_outlived_erx_code)
    end.
