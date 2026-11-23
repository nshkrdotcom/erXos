%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of a domain's code server, erx_code_agent (docs/design-live.md, "The code
%% server"), on stock's emulator, loading real modules into it. The test process plays
%% the domain pid, which takes the server's report, and erx_code, which sends loads in the
%% system domain's envelope, serves pieces to an alias of its own, and says a load was
%% published by handing over a stub lifeline. The deadline is shortened to ?WAIT. This
%% module is also the stub release: lookup/1 answers the blobs a case put in it.

-module(erx_code_agent_tests).

-include_lib("eunit/include/eunit.hrl").

-export([lookup/1, hash/1]).

-define(SYSTEM, 4).
-define(WAIT, 300).
%% Pieces smaller than any test module, so every blob arrives in several.
-define(PIECE, 256).

%% The stub release.
lookup(Hash) ->
    case maps:find(Hash, persistent_term:get({?MODULE, release}, #{})) of
        {ok, Bytes} -> {ok, Bytes};
        error -> none
    end.

hash(_Module) -> none.

code_server_test_() ->
    {foreach, fun() -> ok end, fun(_) -> cleanup() end,
     [fun an_unconfirmed_ok_ends_the_server_at_its_deadline/0,
      fun the_lifelines_end_ends_a_server_that_runs_a_published_module/0,
      fun a_confirmed_empty_start_load_takes_no_monitor/0,
      fun a_domain_no_specification_restarts_keeps_an_unconfirmed_batch/0,
      fun a_refused_start_load_ends_the_start/0,
      fun the_plan_skips_current_modules_reads_the_release_and_fetches_in_order/0,
      fun a_blob_one_bit_off_its_hash_loads_nothing/0,
      fun a_load_whose_pieces_stop_is_abandoned_at_its_deadline/0,
      fun a_message_of_another_origin_is_dropped/0,
      fun replacing_its_own_module_twice_leaves_it_running/0,
      fun replacing_erx_code_batch_twice_leaves_it_running/0,
      fun a_runtime_below_a_floor_fails_its_start/0,
      fun a_load_that_arrives_during_another_waits_for_it/0,
      fun stale_and_stray_pieces_are_dropped_and_counted/0,
      fun a_supervised_start_returns_only_once_its_start_load_is_confirmed/0,
      fun a_piece_queued_before_the_deadline_is_not_taken_after_it/0]}.

%% A load sent while another is in flight is taken only once the first has answered:
%% nothing of it is asked for before then, and both load.
a_load_that_arrives_during_another_waits_for_it() ->
    Server = start_free(env(false)),
    [A, B] = [beam(m_agent_a, 1), beam(m_agent_b, 1)],
    [First, Second] = [alias(), alias()],
    to(Server, {erx_code_load, First, [entry(m_agent_a, A)]}),
    ?assertEqual(ok, receive {erx_code_get, First, _, 0} -> ok after 1000 -> no_request end),
    to(Server, {erx_code_load, Second, [entry(m_agent_b, B)]}),
    ?assertEqual(none, receive {erx_code_get, Second, _, _} -> asked after ?WAIT div 3 -> none end),
    to(Server, {erx_code_piece, First, sha(A), 0, binary:part(A, 0, ?PIECE)}),
    ?assertMatch({First, ok, _}, serve(Server, First, blobs([A]), [])),
    ?assertMatch({Second, ok, _}, serve(Server, Second, blobs([B]), [])),
    ?assertEqual([1, 1], [M:version() || M <- [m_agent_a, m_agent_b]]).

%% A piece of another load, of another blob, at another offset or after the load ended
%% changes nothing but the server's count of dropped messages, and the load goes on.
stale_and_stray_pieces_are_dropped_and_counted() ->
    Server = start_free(env(false)),
    A = beam(m_agent_a, 1),
    Hash = sha(A),
    Alias = alias(),
    to(Server, {erx_code_load, Alias, [entry(m_agent_a, A)]}),
    ?assertEqual(ok, receive {erx_code_get, Alias, Hash, 0} -> ok after 1000 -> no_request end),
    Stray = [{erx_code_piece, alias(), Hash, 0, A},
             {erx_code_piece, Alias, <<0:256>>, 0, A},
             {erx_code_piece, Alias, Hash, 1, A}],
    [to(Server, Piece) || Piece <- Stray],
    to(Server, {erx_code_piece, Alias, Hash, 0, A}),
    ?assertEqual(ok, receive {erx_code_loaded, Alias, R} -> R after 1000 -> no_answer end),
    to(Server, {erx_code_piece, Alias, Hash, 0, A}),
    ?assertMatch({idle, #{dropped := 4}}, sys:get_state(Server)).

%% A piece that was queued before the deadline but reaches the server after it is not
%% taken: the load ends first. The server is suspended so the piece waits in its mailbox
%% ahead of the deadline's timeout.
a_piece_queued_before_the_deadline_is_not_taken_after_it() ->
    Server = start_free(env(false)),
    A = beam(m_agent_a, 1),
    Alias = alias(),
    to(Server, {erx_code_load, Alias, [entry(m_agent_a, A)]}),
    ?assertEqual(ok, receive {erx_code_get, Alias, _, 0} -> ok after 1000 -> no_request end),
    ok = sys:suspend(Server),
    to(Server, {erx_code_piece, Alias, sha(A), 0, A}),
    timer:sleep(2 * ?WAIT),
    ok = sys:resume(Server),
    ?assertEqual(none, receive {erx_code_loaded, Alias, R} -> R after ?WAIT -> none end),
    ?assertEqual(false, code:is_loaded(m_agent_a)),
    ?assertMatch({idle, #{dropped := 1}}, sys:get_state(Server)).

%% A supervised server's start returns only after erx_code confirms its start load, not
%% at its answer.
a_supervised_start_returns_only_once_its_start_load_is_confirmed() ->
    Server = start(env(true)),
    {Alias, ok, []} = exchange(Server, [], #{}),
    ?assertEqual(none, receive {start, Early} -> Early after ?WAIT div 3 -> none end),
    publish(Server, Alias, spawn_lifeline()),
    ?assertEqual({ok, Server}, started()).

%% Loads that replace erx_code_batch, the module the server is running while it loads, twice,
%% leave the server running.
replacing_erx_code_batch_twice_leaves_it_running() ->
    Server = start_free(env(false)),
    {erx_code_batch, Own, _} = code:get_object_code(erx_code_batch),
    [V1, V2] = [variant(Own, N) || N <- [1, 2]],
    ?assertMatch({_, ok, _}, exchange(Server, [entry(erx_code_batch, V1)], blobs([V1]))),
    ?assertMatch({_, ok, _}, exchange(Server, [entry(erx_code_batch, V2)], blobs([V2]))),
    Probe = beam(m_agent_probe, 1),
    ?assertMatch({_, ok, _}, exchange(Server, [entry(m_agent_probe, Probe)], blobs([Probe]))),
    ?assert(is_process_alive(Server)).

cleanup() ->
    persistent_term:erase({?MODULE, release}),
    [begin _ = code:purge(M), _ = code:delete(M), _ = code:purge(M) end
     || M <- [m_agent_a, m_agent_b, m_agent_c, m_agent_d, m_agent_probe]],
    flush().

flush() ->
    receive _ -> flush() after 0 -> ok end.

%% The keep step: an ok never confirmed ends the server at its deadline, though the batch
%% loaded.
an_unconfirmed_ok_ends_the_server_at_its_deadline() ->
    {Server, _Lifeline} = start_supervised(),
    A = beam(m_agent_a, 1),
    ?assertMatch({_, ok, _}, exchange(Server, [entry(m_agent_a, A)], blobs([A]))),
    ?assertEqual({erx_code, unpublished}, server_exit(Server, 4 * ?WAIT)).

%% A confirmed load naming a module makes the server monitor the lifeline, whose end,
%% normal or killed, ends the server.
the_lifelines_end_ends_a_server_that_runs_a_published_module() ->
    [begin
         {Server, Lifeline} = start_supervised(),
         B = beam(m_agent_b, 1),
         {Alias, ok, _} = exchange(Server, [entry(m_agent_b, B)], blobs([B])),
         publish(Server, Alias, Lifeline),
         timer:sleep(50),
         ?assert(is_process_alive(Server)),
         End(Lifeline),
         ?assertEqual({End, {erx_code, down}}, {End, server_exit(Server, 1000)})
     end || End <- [fun(L) -> L ! stop end, fun(L) -> exit(L, kill) end]].

%% A confirmed empty start load leaves the server holding no published module, so it runs
%% on when the lifeline ends.
a_confirmed_empty_start_load_takes_no_monitor() ->
    {Server, Lifeline} = start_supervised(),
    Lifeline ! stop,
    timer:sleep(100),
    ?assert(is_process_alive(Server)),
    C = beam(m_agent_c, 1),
    {Alias, ok, _} = exchange(Server, [entry(m_agent_c, C)], blobs([C])),
    publish(Server, Alias, spawn_lifeline()),
    timer:sleep(50),
    ?assert(is_process_alive(Server)).

%% A domain no specification restarts keeps a batch no one confirms: erx_code's deadline
%% may pass just before the batch loads, and the domain runs on.
a_domain_no_specification_restarts_keeps_an_unconfirmed_batch() ->
    Server = start_free(env(false)),
    D = beam(m_agent_d, 1),
    ?assertMatch({_, ok, _}, exchange(Server, [entry(m_agent_d, D)], blobs([D]))),
    timer:sleep(3 * ?WAIT),
    ?assert(is_process_alive(Server)),
    ?assertEqual(1, m_agent_d:version()).

%% A start load the server refuses ends its start with {start_load, Result}.
a_refused_start_load_ends_the_start() ->
    Server = start(env(true)),
    A = beam(m_agent_a, 1),
    Bad = flip(A),
    {_, Result, _} = exchange(Server, [entry(m_agent_a, A)], #{sha(A) => Bad}),
    ?assertEqual({error, {hash_mismatch, <<"m_agent_a">>}}, Result),
    ?assertEqual({error, {start_load, Result}}, started()).

%% Step 1 and 2: a module already current is skipped, a blob the release lists is read
%% from it, and the rest are fetched blob after blob in manifest order, each piece only
%% after the one before it arrived.
the_plan_skips_current_modules_reads_the_release_and_fetches_in_order() ->
    Server = start_free(env(false)),
    Current = beam(m_agent_a, 1),
    ok = erx_code_batch:load([{<<"m_agent_a">>, sha(Current), Current}]),
    Released = beam(m_agent_b, 2),
    persistent_term:put({?MODULE, release}, #{sha(Released) => Released}),
    [C, D] = [beam(m_agent_c, 3), beam(m_agent_d, 4)],
    Manifest = [entry(m_agent_a, Current), entry(m_agent_c, C), entry(m_agent_b, Released), entry(m_agent_d, D)],
    {_, ok, Gets} = exchange(Server, Manifest, blobs([C, D])),
    ?assertEqual(pieces(C) ++ pieces(D), Gets),
    ?assertEqual([1, 2, 3, 4], [M:version() || M <- [m_agent_a, m_agent_b, m_agent_c, m_agent_d]]).

%% A blob whose bytes do not hash to its hash is refused and no module of the batch loads.
a_blob_one_bit_off_its_hash_loads_nothing() ->
    Server = start_free(env(false)),
    [A, B] = [beam(m_agent_a, 1), beam(m_agent_b, 1)],
    {_, Result, _} = exchange(Server, [entry(m_agent_a, A), entry(m_agent_b, B)],
                              #{sha(A) => A, sha(B) => flip(B)}),
    ?assertEqual({error, {hash_mismatch, <<"m_agent_b">>}}, Result),
    ?assertEqual([false, false], [code:is_loaded(M) || M <- [m_agent_a, m_agent_b]]).

%% A load whose pieces stop coming is abandoned at its deadline, with no answer, and the
%% server takes the next load.
a_load_whose_pieces_stop_is_abandoned_at_its_deadline() ->
    Server = start_free(env(false)),
    A = beam(m_agent_a, 1),
    Alias = alias(),
    to(Server, {erx_code_load, Alias, [entry(m_agent_a, A)]}),
    ?assertEqual(ok, receive {erx_code_get, Alias, _, 0} -> ok after 1000 -> no_request end),
    ?assertEqual(none, receive {erx_code_loaded, Alias, R} -> R after 3 * ?WAIT -> none end),
    ?assertEqual(false, code:is_loaded(m_agent_a)),
    ?assertMatch({_, ok, _}, exchange(Server, [entry(m_agent_a, A)], blobs([A]))).

%% A load in any envelope but the system domain's is dropped.
a_message_of_another_origin_is_dropped() ->
    Server = start_free(env(false)),
    A = beam(m_agent_a, 1),
    Alias = alias(),
    Server ! {erx_origin, 9, {erx_code_load, Alias, [entry(m_agent_a, A)]}},
    ?assertEqual(none, receive {erx_code_get, Alias, _, _} -> asked after 200 -> none end),
    ?assertMatch({_, ok, _}, exchange(Server, [entry(m_agent_a, A)], blobs([A]))).

%% Each load is entered through an external call, so loads that replace the server's own
%% module, twice, purge no code the server runs.
replacing_its_own_module_twice_leaves_it_running() ->
    Server = start_free(env(false)),
    {erx_code_agent, Own, _} = code:get_object_code(erx_code_agent),
    [V1, V2] = [variant(Own, N) || N <- [1, 2]],
    ?assertMatch({_, ok, _}, exchange(Server, [entry(erx_code_agent, V1)], blobs([V1]))),
    ?assertMatch({_, ok, _}, exchange(Server, [entry(erx_code_agent, V2)], blobs([V2]))),
    Probe = beam(m_agent_probe, 1),
    ?assertMatch({_, ok, _}, exchange(Server, [entry(m_agent_probe, Probe)], blobs([Probe]))),
    ?assert(is_process_alive(Server)).

%% A runtime whose limits are below the code protocol's floors fails its start before it
%% reports; one at the floors, and one whose limits are unknown, start.
a_runtime_below_a_floor_fails_its_start() ->
    Floors = #{max_frame => 4096, max_message_heap => 512, funnel_depth => 4},
    At = #{max_frame => 4096, max_message_heap => 512, funnel_depth => 4},
    Below = (env(false))#{limits => At#{max_message_heap => 511}, floors => Floors},
    spawn_starter(Below),
    ?assertEqual({error, {below_floor, max_message_heap}}, started()),
    ?assertEqual(none, receive {erx_code_agent, _} -> reported after 0 -> none end),
    _ = start_free((env(false))#{limits => At, floors => Floors}),
    ?assertEqual(ok, erx_code_agent_core:floor_check(At, Floors)),
    ?assertEqual(unknown, erx_code_agent_core:floor_check(unknown, Floors)).

%% Helpers.

env(Supervised) ->
    #{system => ?SYSTEM, domain_pid => self(), supervised => Supervised,
      limits => unknown, floors => #{}, release => ?MODULE, wait => ?WAIT}.

%% A server started from a process that reports how its start ended and then how the
%% server ended; the server's report reaches this process, the domain pid.
start(Env) ->
    spawn_starter(Env),
    receive {erx_code_agent, Server} -> Server after 1000 -> error(no_report) end.

spawn_starter(Env) ->
    Self = self(),
    spawn(fun() ->
                  process_flag(trap_exit, true),
                  case erx_code_agent:start_link(Env) of
                      {ok, Server} ->
                          Self ! {start, {ok, Server}},
                          receive {'EXIT', Server, Reason} -> Self ! {server_exit, Server, Reason} end;
                      Failed ->
                          Self ! {start, Failed}
                  end
          end).

started() ->
    receive {start, Result} -> Result after 2000 -> start_timeout end.

server_exit(Server, Timeout) ->
    receive {server_exit, Server, Reason} -> Reason after Timeout -> running end.

start_free(Env) ->
    Server = start(Env),
    {ok, Server} = started(),
    Server.

%% A supervised server past an empty start load that erx_code confirmed.
start_supervised() ->
    Server = start(env(true)),
    {Alias, ok, []} = exchange(Server, [], #{}),
    Lifeline = spawn_lifeline(),
    publish(Server, Alias, Lifeline),
    {ok, Server} = started(),
    {Server, Lifeline}.

spawn_lifeline() ->
    spawn(fun() -> receive stop -> ok end end).

publish(Server, Alias, Lifeline) ->
    to(Server, {erx_code_published, Alias, Lifeline}).

to(Server, Message) ->
    Server ! {erx_origin, ?SYSTEM, Message}.

%% One load as erx_code serves it: each piece asked for, from Blobs, until the answer.
%% Returns the alias, the answer and the pieces asked for, in order.
exchange(Server, Manifest, Blobs) ->
    Alias = alias(),
    to(Server, {erx_code_load, Alias, Manifest}),
    serve(Server, Alias, Blobs, []).

serve(Server, Alias, Blobs, Gets) ->
    receive
        {erx_code_get, Alias, Hash, Offset} ->
            Bytes = maps:get(Hash, Blobs),
            Piece = binary:part(Bytes, Offset, min(?PIECE, byte_size(Bytes) - Offset)),
            to(Server, {erx_code_piece, Alias, Hash, Offset, Piece}),
            serve(Server, Alias, Blobs, [{Hash, Offset} | Gets]);
        {erx_code_loaded, Alias, Result} ->
            {Alias, Result, lists:reverse(Gets)}
    after 2000 ->
        {Alias, no_answer, lists:reverse(Gets)}
    end.

entry(Module, Bytes) -> {atom_to_binary(Module), sha(Bytes), byte_size(Bytes)}.

blobs(List) -> maps:from_list([{sha(Bytes), Bytes} || Bytes <- List]).

pieces(Bytes) -> [{sha(Bytes), Offset} || Offset <- lists:seq(0, byte_size(Bytes) - 1, ?PIECE)].

sha(Bytes) -> crypto:hash(sha256, Bytes).

flip(<<First, Rest/binary>>) -> <<(First bxor 1), Rest/binary>>.

%% The same module with one more chunk, which the loader ignores, so its hash differs.
variant(Beam, N) ->
    {ok, _Module, Chunks} = beam_lib:all_chunks(Beam),
    {ok, Variant} = beam_lib:build_module(Chunks ++ [{"XVar", <<N>>}]),
    Variant.

%% A module whose version/0 returns Version.
beam(Module, Version) ->
    Forms = [{attribute, 1, module, Module},
             {attribute, 2, export, [{version, 0}]},
             {function, 3, version, 0, [{clause, 3, [], [], [{integer, 3, Version}]}]}],
    {ok, Module, Bytes} = compile:forms(Forms, [binary]),
    Bytes.
