%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_waits_tests).
-moduledoc """
EUnit tests of a keeper's set of waiting requests, `erx_fs_waits`
(docs/design-files.md#verification-and-testing, "Waiting requests"): a
keeper that answers a thousand reads one by one holds no request and no
monitor afterwards; a flush of a request not yet begun is answered `eintr`
by the set, one of a begun request goes to the keeper once, and a grant's
end drops what it sent. The test process is the keeper; a fake grant
sends it requests and flushes as `erx_fs` does, each request on an alias
of its monitor of the keeper that the first reply deactivates, and hands
the test every answer it receives. test/host/erx_fs_test.rb runs these on
stock OTP and seeds a fault for each property.
""".

-include_lib("eunit/include/eunit.hrl").

-define(DEADLINE, 1000).
-define(READS, 1000).

a_keeper_that_answers_a_thousand_reads_holds_nothing_test() ->
    Monitors = monitors(),
    Grant = grant(),
    Grant ! {reads, ?READS},
    Waits = answer_reads(?READS, erx_fs_waits:new()),
    Expected = [{ok, integer_to_binary(N)} || N <- lists:seq(1, ?READS)],
    ?assertEqual(Expected, receive {read_all, Results} -> Results after ?DEADLINE -> timeout end),
    ?assertEqual([], erx_fs_waits:list(Waits)),
    ?assertEqual(Monitors, monitors()).

a_flush_of_a_request_not_yet_begun_is_answered_eintr_test() ->
    Monitors = monitors(),
    Grant = grant(),
    {Waits0, Wait} = hold(Grant, {read, 16}, erx_fs_waits:new()),
    Grant ! {flush, Wait},
    {flushed, Waits1} = erx_fs_waits:info(next(), Waits0),
    ?assertEqual({error, eintr}, answered(Wait)),
    ?assertEqual([], erx_fs_waits:list(Waits1)),
    ?assertEqual(Monitors, monitors()),
    %% The keeper's late answer finds nothing, and sends nothing.
    ?assertEqual([], erx_fs_waits:list(erx_fs_waits:answer(Wait, {ok, <<"late">>}, Waits1))),
    ?assertEqual(none, answered(Wait)).

a_flush_of_a_begun_request_waits_for_the_keepers_answer_test() ->
    Grant = grant(),
    {Waits0, Wait} = hold(Grant, {write, <<"bytes">>}, erx_fs_waits:new()),
    Waits1 = erx_fs_waits:began(Wait, Waits0),
    Grant ! {flush, Wait},
    {begun, Wait, {write, <<"bytes">>}, Waits2} = erx_fs_waits:info(next(), Waits1),
    ?assertEqual(none, answered(Wait)),
    ?assertEqual([{Wait, {write, <<"bytes">>}, begun}], erx_fs_waits:list(Waits2)),
    %% One flush waits for each request: a second reaches the keeper as settled.
    Grant ! {flush, Wait},
    {flushed, Waits3} = erx_fs_waits:info(next(), Waits2),
    Waits4 = erx_fs_waits:answer(Wait, {ok, 5, 0}, Waits3),
    ?assertEqual({ok, 5, 0}, answered(Wait)),
    ?assertEqual([], erx_fs_waits:list(Waits4)).

a_grants_end_drops_its_requests_test() ->
    Monitors = monitors(),
    Grant = grant(),
    Other = grant(),
    {Waits0, First} = hold(Grant, {read, 1}, erx_fs_waits:new()),
    {Waits1, Kept} = hold(Other, {read, 2}, Waits0),
    {Waits2, Second} = hold(Grant, {read, 3}, Waits1),
    Waits3 = erx_fs_waits:began(Second, Waits2),
    ?assertEqual([First, Kept, Second], [Wait || {Wait, _, _} <- erx_fs_waits:list(Waits3)]),
    exit(Grant, kill),
    Down = receive {'DOWN', _, process, Grant, _} = Message -> Message after ?DEADLINE -> no_down end,
    {dropped, Waits4} = erx_fs_waits:info(Down, Waits3),
    ?assertEqual([{Kept, {read, 2}, waiting}], erx_fs_waits:list(Waits4)),
    %% A begun effect's answer then finds nothing to answer.
    Waits5 = erx_fs_waits:answer(Second, {ok, <<"x">>}, Waits4),
    Waits6 = erx_fs_waits:answer(Kept, {ok, <<"y">>}, Waits5),
    ?assertEqual({ok, <<"y">>}, answered(Kept)),
    ?assertEqual([], erx_fs_waits:list(Waits6)),
    ?assertEqual(Monitors, monitors()).

messages_of_the_keepers_own_are_unknown_test() ->
    Waits = erx_fs_waits:new(),
    Ref = make_ref(),
    ?assertEqual(unknown, erx_fs_waits:info({'DOWN', Ref, process, self(), normal}, Waits)),
    ?assertEqual(unknown, erx_fs_waits:info({bytes, <<"a">>}, Waits)).

%% ---------------------------------------------------------------------------
%% The keeper's side: the test process
%% ---------------------------------------------------------------------------

%% Takes N reads one at a time, answering each with its number as it arrives.
answer_reads(0, Waits) ->
    Waits;
answer_reads(N, Waits0) ->
    {erx_fs_wait, Wait, {read, Number}} = Message = next(),
    Waits1 = erx_fs_waits:hold(Message, Waits0),
    answer_reads(N - 1, erx_fs_waits:answer(Wait, {ok, integer_to_binary(Number)}, Waits1)).

%% Has Grant send Request, and holds it.
hold(Grant, Request, Waits) ->
    Grant ! {send, Request},
    {erx_fs_wait, Wait, Request} = Message = next(),
    {erx_fs_waits:hold(Message, Waits), Wait}.

%% The next message for the keeper from a grant: a request, a flush or a grant's end.
next() ->
    receive
        {erx_fs_wait, _, _} = Message -> Message;
        {erx_fs_flush, _} = Message -> Message
    after ?DEADLINE -> timeout
    end.

%% The answer the grant received for Wait, or none within a short wait.
answered({_, Alias}) ->
    receive {answered, Alias, Result} -> Result after 100 -> none end.

monitors() ->
    {monitors, Monitors} = process_info(self(), monitors),
    Monitors.

%% ---------------------------------------------------------------------------
%% A fake grant: what erx_fs sends a keeper, and what it hears back
%% ---------------------------------------------------------------------------

grant() ->
    Keeper = self(),
    spawn(fun() -> grant_loop(Keeper) end).

grant_loop(Keeper) ->
    receive
        {send, Request} ->
            send(Keeper, Request),
            grant_loop(Keeper);
        {flush, Wait} ->
            Keeper ! {erx_fs_flush, Wait},
            grant_loop(Keeper);
        {reads, N} ->
            Keeper ! {read_all, [read(Keeper, Number) || Number <- lists:seq(1, N)]},
            grant_loop(Keeper);
        {erx_fs_answer, Alias, Result} ->
            Keeper ! {answered, Alias, Result},
            grant_loop(Keeper)
    end.

%% A request on an alias of the grant's monitor of the keeper, as rule 1 makes it.
send(Keeper, Request) ->
    Alias = erlang:monitor(process, Keeper, [{alias, reply_demonitor}]),
    Keeper ! {erx_fs_wait, {self(), Alias}, Request},
    Alias.

read(Keeper, Number) ->
    Alias = send(Keeper, {read, Number}),
    receive {erx_fs_answer, Alias, Result} -> Result after ?DEADLINE -> timeout end.
