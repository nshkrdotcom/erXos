%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of ntpd's pure core, erx_ntp_core (docs/design-time.md, "The
%% client" and "Verification and testing"): the start flags' server list, the
%% schedule over generated event sequences, and the clock facet request a
%% checked sample gives. Seeded faults: accepting a ninth entry passes the
%% nine-entry case; a poll floor of 8 s fails the spacing property; and a
%% wait of the 2 s burst gap after a clock answer, in place of the interval,
%% which leaves the interval itself within bounds, fails the property at its
%% spacing assertion (perform/3's poll clause); and a 15 s wait in place of
%% 2 s before the first poll fails late_network_test.
-module(erx_ntp_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, {10, 0, 2, 100}).
-define(B, {192, 0, 2, 7}).
-define(MIN_POLL_MS, 64000).
-define(MAX_POLL_MS, 1024000).

%%% The server list

servers_test_() ->
    Long = binary:copy(<<"a">>, 63),
    Name253 = <<Long/binary, ".", Long/binary, ".", Long/binary, ".", (binary:copy(<<"b">>, 61))/binary>>,
    [?_assertEqual({ok, [<<"pool.ntp.org">>]}, erx_ntp_core:servers(<<"pool.ntp.org">>)),
     ?_assertEqual({ok, [<<"10.0.2.100">>, <<"ntp.example.net">>]},
                   erx_ntp_core:servers(<<"  10.0.2.100   ntp.example.net ">>)),
     ?_assertEqual({ok, [Name253]}, erx_ntp_core:servers(Name253)),
     ?_assertEqual({ok, lists:duplicate(8, <<"a">>)}, erx_ntp_core:servers(<<"a a a a a a a a">>)),
     ?_assertEqual({error, no_servers}, erx_ntp_core:servers(<<>>)),
     ?_assertEqual({error, no_servers}, erx_ntp_core:servers(<<"   ">>)),
     ?_assertEqual({error, bad_flags}, erx_ntp_core:servers(<<"a a a a a a a a a">>)),
     ?_assertEqual({error, bad_flags}, erx_ntp_core:servers(<<Name253/binary, "c">>)),
     ?_assertEqual({error, bad_flags}, erx_ntp_core:servers(<<Long/binary, "a.org">>)),
     ?_assertEqual({error, bad_flags}, erx_ntp_core:servers(<<"pool..org">>)),
     ?_assertEqual({error, bad_flags}, erx_ntp_core:servers(<<"pool.org.">>)),
     ?_assertEqual({error, bad_flags}, erx_ntp_core:servers(<<"po_ol.org">>)),
     ?_assertEqual({error, bad_flags}, erx_ntp_core:servers(<<"a\tb">>)),
     %% RFC 1123's labels neither start nor end with a hyphen, so no flag is a name.
     ?_assertEqual({error, bad_flags}, erx_ntp_core:servers(<<"-q">>)),
     ?_assertEqual({error, bad_flags}, erx_ntp_core:servers(<<"pool-.org">>)),
     ?_assertEqual({ok, [<<"a-b.org">>]}, erx_ntp_core:servers(<<"a-b.org">>))].

%%% The facet request

request_test() ->
    Sample = #{offset => 1795000000000000000, delay => 2000000, distance => 3000000, stratum => 2},
    ?assertEqual({sample, 1795000000000000000, 3000000, 2, ?A}, erx_ntp_core:request(Sample, ?A)).

%%% The schedule

sample(Delay) -> {sample, #{offset => 5, delay => Delay, distance => Delay div 2, stratum => 2}}.

start_resolves_then_bursts_test() ->
    {{resolve, <<"pool">>}, S0} = erx_ntp_core:start([<<"pool">>]),
    {{exchange, ?A, poll}, S1} = erx_ntp_core:step({resolved, [?A, ?B, ?A]}, S0),
    {{wait, 2000}, S2} = erx_ntp_core:step({exchanged, sample(900)}, S1),
    {{exchange, ?A, burst}, S3} = erx_ntp_core:step(woke, S2),
    {{wait, 2000}, S4} = erx_ntp_core:step({exchanged, sample(300)}, S3),
    {{exchange, ?A, burst}, S5} = erx_ntp_core:step(woke, S4),
    {{wait, 2000}, S6} = erx_ntp_core:step({exchanged, timeout}, S5),
    {{exchange, ?A, burst}, S7} = erx_ntp_core:step(woke, S6),
    %% The poll's sample is the reply of least delay.
    {{submit, #{delay := 300}, ?A}, S8} = erx_ntp_core:step({exchanged, sample(500)}, S7),
    {{wait, ?MIN_POLL_MS}, S9} = erx_ntp_core:step({clock, {ok, held}}, S8),
    ?assertEqual(2 * ?MIN_POLL_MS, erx_ntp_core:interval(S9)),
    %% A later poll of the same address is one exchange.
    {{exchange, ?A, poll}, S10} = erx_ntp_core:step(woke, S9),
    {{submit, _, ?A}, _} = erx_ntp_core:step({exchanged, sample(100)}, S10).

error_answer_keeps_interval_test() ->
    S = submitting(),
    {{wait, ?MIN_POLL_MS}, After} = erx_ntp_core:step({clock, {error, failed}}, S),
    ?assertEqual(?MIN_POLL_MS, erx_ntp_core:interval(After)).

%% Once every address has failed, the names are resolved again only after the
%% doubled interval, which stands in for the answers' TTL.
reresolve_after_doubled_interval_test() ->
    {_, S0} = erx_ntp_core:start([<<"10.0.2.100">>]),
    {_, S1} = erx_ntp_core:step({resolved, [?A]}, S0),
    Silent = lists:foldl(fun(_, S) ->
                                 {{wait, 2000}, W} = erx_ntp_core:step({exchanged, {error, timeout}}, S),
                                 {_, Next} = erx_ntp_core:step(woke, W),
                                 Next
                         end, S1, lists:seq(1, 3)),
    {{wait, 128000}, S2} = erx_ntp_core:step({exchanged, {error, timeout}}, Silent),
    {{resolve, _}, _} = erx_ntp_core:step(woke, S2).

%% A run that has polled no address yet retries a round that found none after
%% 2 s, thirty times, then backs off from 15 s.
resolve_backoff_test() ->
    {_, S0} = erx_ntp_core:start([<<"pool">>]),
    Quick = lists:foldl(fun(_, S) ->
                                {{wait, 2000}, Waiting} = erx_ntp_core:step({resolved, []}, S),
                                {{resolve, _}, Next} = erx_ntp_core:step(woke, Waiting),
                                Next
                        end, S0, lists:seq(1, 30)),
    {{wait, 15000}, S1} = erx_ntp_core:step({resolved, []}, Quick),
    {{resolve, _}, S2} = erx_ntp_core:step(woke, S1),
    {{wait, 30000}, _} = erx_ntp_core:step({resolved, []}, S2).

%% A denied address is gone: the next, never polled, is polled at once, and a
%% round that finds only denied addresses waits the resolution backoff.
deny_removes_address_test() ->
    {_, S0} = erx_ntp_core:start([<<"pool">>]),
    {{exchange, ?A, poll}, S1} = erx_ntp_core:step({resolved, [?A, ?B]}, S0),
    {{exchange, ?B, poll}, S2} = erx_ntp_core:step({exchanged, {kiss, <<"DENY">>}}, S1),
    {{wait, 15000}, S3} = erx_ntp_core:step({exchanged, {kiss, <<"RSTR">>}}, S2),
    %% A new resolution does not bring the denied addresses back.
    {{resolve, <<"pool">>}, S4} = erx_ntp_core:step(woke, S3),
    {{wait, 30000}, _} = erx_ntp_core:step({resolved, [?A, ?B]}, S4).

rate_doubles_and_other_kiss_is_discarded_test() ->
    {_, S0} = erx_ntp_core:start([<<"10.0.2.100">>]),
    {{exchange, ?A, poll}, S1} = erx_ntp_core:step({resolved, [?A]}, S0),
    {{wait, 2000}, S2} = erx_ntp_core:step({exchanged, sample(10)}, S1),
    {{exchange, ?A, burst}, S3} = erx_ntp_core:step(woke, S2),
    %% RATE ends the burst, doubles the interval, and keeps the sample it had.
    {{submit, _, ?A}, S4} = erx_ntp_core:step({exchanged, {kiss, <<"RATE">>}}, S3),
    ?assertEqual(2 * ?MIN_POLL_MS, erx_ntp_core:interval(S4)),
    {_, T0} = erx_ntp_core:start([<<"10.0.2.100">>]),
    {_, T1} = erx_ntp_core:step({resolved, [?A]}, T0),
    {{wait, 2000}, _} = erx_ntp_core:step({exchanged, {kiss, <<"XFOO">>}}, T1).

%%% Elapsed time (T-R1), and the denied list's bound, over simulated runs

%% A run of the schedule from start(Names) for Steps actions, each answered by
%% Answer(Action, Resolutions), the resolutions asked so far this one included,
%% as an event and the milliseconds it took; the actions asked, each with the
%% simulated time it was asked at.
%% An Answer of three arguments is also given the simulated time.
simulate(Names, Answer, Steps) when is_function(Answer, 2) ->
    simulate(Names, fun(Action, Resolutions, _Now) -> Answer(Action, Resolutions) end, Steps);
simulate(Names, Answer, Steps) ->
    {Action, State} = erx_ntp_core:start(Names),
    simulate(Steps, Answer, Action, State, 0, 0, []).

simulate(0, _Answer, _Action, _State, _Now, _Resolutions, Trace) ->
    lists:reverse(Trace);
simulate(Steps, Answer, Action, State, Now, Resolutions0, Trace) ->
    Resolutions = case Action of
                      {resolve, _} -> Resolutions0 + 1;
                      _ -> Resolutions0
                  end,
    {Event, Ms} = Answer(Action, Resolutions, Now),
    {Next, State1} = erx_ntp_core:step(Event, State),
    simulate(Steps - 1, Answer, Next, State1, Now + Ms, Resolutions, [{Now, Action} | Trace]).

%% A silent address costs its four exchanges and their gaps; a responsive one
%% answers in 10 ms; the clock steps.
answer({exchange, Address, _}, Silent) ->
    case lists:member(Address, Silent) of
        true -> {{exchanged, {error, timeout}}, 2000};
        false -> {{exchanged, sample(10)}, 10}
    end;
answer({submit, _, _}, _Silent) -> {{clock, {ok, {stepped, 1}}}, 10};
answer({wait, Ms}, _Silent) -> {woke, Ms}.

first_sample(Trace) ->
    hd([Now || {Now, {submit, _, _}} <- Trace]).

%% A pool whose first address is silent and whose second answers: the second's
%% first poll follows the first's failed burst at once, so the clock has a
%% sample within T-R1's minute.
silent_first_address_test() ->
    Answer = fun({resolve, _}, _) -> {{resolved, [?A, ?B]}, 100};
                (Action, _) -> answer(Action, [?A])
             end,
    Trace = simulate([<<"pool">>], Answer, 40),
    ?assertMatch({_, {submit, _, ?B}}, lists:keyfind(first_sample(Trace), 1, Trace)),
    ?assert(first_sample(Trace) < 60000).

%% A network that has no address for its first 20 s, and so answers no address
%% for the name at once, then answers it: the address is first asked within 2 s
%% of the network's address, not after the resolution backoff, and the clock
%% has its sample after that address's burst.
late_network_test() ->
    Up = 20000,
    Answer = fun({resolve, _}, _, Now) when Now < Up -> {{resolved, []}, 5};
                ({resolve, _}, _, _Now) -> {{resolved, [?A]}, 50};
                (Action, _, _Now) -> answer(Action, [])
             end,
    Trace = simulate([<<"pool">>], Answer, 60),
    FirstAsked = hd([Now || {Now, {exchange, ?A, _}} <- Trace]),
    ?assert(FirstAsked < Up + 2100),
    ?assert(first_sample(Trace) < FirstAsked + 6100).

%% A reachable literal before seven names whose resolution times out after 10 s:
%% the literal's address is polled once it is resolved, not after the others.
resolution_in_order_test() ->
    Names = [<<"10.0.2.100">> | [<<"slow", (integer_to_binary(N))/binary, ".example">> || N <- lists:seq(1, 7)]],
    Resolve = fun(<<"10.0.2.100">>) -> {[?A], 0};
                 (_Slow) -> {[], 10000}
              end,
    Answer = fun({resolve, Asked}, _) ->
                     {Found, Ms} = Resolve(Asked),
                     {{resolved, Found}, Ms};
                (Action, _) -> answer(Action, [])
             end,
    Trace = simulate(Names, Answer, 40),
    ?assert(first_sample(Trace) < 60000).

%% A pool that gives a new address at each resolution, each of which denies,
%% past the denied list's bound, after two silent addresses polled first: no
%% denied address is polled again, however many denials the run has had, and
%% an address polled before is still polled. The last resolutions offer the
%% first address denied, which a list keeping the latest denials forgets;
%% the fortieth, past the bound of 32, which the list never held; and ?B,
%% polled before, which denies once the list is full and so is never held.
denied_stay_denied_test() ->
    Denying = [{198, 51, 100, N} || N <- lists:seq(1, 70)],
    Last = [hd(Denying), lists:nth(40, Denying), ?B, ?A],
    Answer = fun({resolve, _}, 1) -> {{resolved, [?A, ?B]}, 0};
                ({resolve, _}, N) when N =< 71 -> {{resolved, [lists:nth(N - 1, Denying)]}, 0};
                ({resolve, _}, _) -> {{resolved, Last}, 0};
                ({exchange, ?B, _}, N) when N >= 72 -> {{exchanged, {kiss, <<"DENY">>}}, 10};
                ({exchange, Address, _}, _) ->
                     case lists:member(Address, Denying) of
                         true -> {{exchanged, {kiss, <<"DENY">>}}, 10};
                         false -> {{exchanged, {error, timeout}}, 2000}
                     end;
                (Action, _) -> answer(Action, [])
             end,
    Trace = simulate([<<"pool">>], Answer, 600),
    Exchanged = [Address || {_, {exchange, Address, _}} <- Trace],
    ?assertEqual([], [D || D <- Denying, length([X || X <- Exchanged, X =:= D]) > 1]),
    {_, AfterFull} = lists:split(length(lists:takewhile(fun(Action) -> Action =/= {resolve, 72} end,
                                                        resolutions(Trace))), resolutions(Trace)),
    ?assertEqual(1, length([B || {exchange, ?B = B, _} <- AfterFull])),
    ?assertEqual(?A, lists:last(Exchanged)).

%% The actions of a trace, each resolution numbered: {resolve, N} for the Nth.
resolutions(Trace) ->
    {Numbered, _} = lists:mapfoldl(fun({_, {resolve, _}}, N) -> {{resolve, N + 1}, N + 1};
                                      ({_, Action}, N) -> {Action, N}
                                   end, 0, Trace),
    Numbered.

%% Over generated runs: no two polls of an address closer than the 64 s
%% floor, a burst only after an address's first poll and at most three
%% burst exchanges a poll, and the interval within 64 s to 1024 s. Two names
%% share the generated addresses, so a round appends a name's addresses to
%% those already failed.
schedule_property_test() ->
    rand:seed(exsss, {1, 2, 3}),
    lists:foreach(fun(_) -> run(400) end, lists:seq(1, 200)).

run(Steps) ->
    {Action, State} = erx_ntp_core:start([<<"pool">>, <<"pool2">>]),
    run(Steps, Action, State, 0, #{}).

run(0, _Action, _State, _Now, _Seen) ->
    ok;
run(Steps, Action, State, Now, Seen) ->
    Interval = erx_ntp_core:interval(State),
    ?assert(Interval >= ?MIN_POLL_MS andalso Interval =< ?MAX_POLL_MS),
    {Event, Elapsed, Seen1} = perform(Action, Now, Seen),
    {Next, State1} = erx_ntp_core:step(Event, State),
    run(Steps - 1, Next, State1, Now + Elapsed, Seen1).

perform({resolve, _Names}, _Now, Seen) ->
    %% A pool of 40 addresses besides, so runs fill the denied list too.
    Found = lists:sublist([?A, ?B, {192, 0, 2, rand:uniform(3)}, {203, 0, 113, rand:uniform(40)}], rand:uniform(5) - 1),
    {{resolved, Found}, rand:uniform(5000), Seen};
perform({exchange, Address, poll}, Now, Seen) ->
    case maps:find({poll, Address}, Seen) of
        {ok, Last} -> ?assert(Now - Last >= ?MIN_POLL_MS);
        error -> ok
    end,
    Burst = case maps:is_key({poll, Address}, Seen) of
                true -> spent;
                false -> 0
            end,
    {{exchanged, verdict()}, rand:uniform(2000),
     Seen#{{poll, Address} => Now, {burst, Address} => Burst}};
perform({exchange, Address, burst}, _Now, Seen) ->
    Count = maps:get({burst, Address}, Seen),
    ?assert(is_integer(Count) andalso Count < 3),
    {{exchanged, verdict()}, rand:uniform(2000), Seen#{{burst, Address} => Count + 1}};
perform({submit, #{}, _Address}, _Now, Seen) ->
    Answer = lists:nth(rand:uniform(3), [{ok, held}, {ok, {stepped, 7}}, {error, failed}]),
    {{clock, Answer}, rand:uniform(100), Seen};
perform({wait, Ms}, _Now, Seen) ->
    {woke, Ms, Seen}.

verdict() ->
    lists:nth(rand:uniform(8), [sample(rand:uniform(1000)), sample(rand:uniform(1000)), timeout, {error, econnrefused},
                                {drop, stratum}, {kiss, <<"RATE">>}, {kiss, <<"DENY">>}, {kiss, <<"INIT">>}]).

submitting() ->
    {_, S0} = erx_ntp_core:start([<<"10.0.2.100">>]),
    {_, S1} = erx_ntp_core:step({resolved, [?A]}, S0),
    {{wait, _}, S2} = erx_ntp_core:step({exchanged, timeout}, S1),
    {_, S3} = erx_ntp_core:step(woke, S2),
    {_, S4} = erx_ntp_core:step({exchanged, timeout}, S3),
    {_, S5} = erx_ntp_core:step(woke, S4),
    {_, S6} = erx_ntp_core:step({exchanged, timeout}, S5),
    {_, S7} = erx_ntp_core:step(woke, S6),
    {{submit, _, ?A}, S8} = erx_ntp_core:step({exchanged, sample(5)}, S7),
    S8.

%% What /proc/ntp shows (docs/design-time.md, "What /proc shows"): the interval and the
%% resolution backoff in seconds, and the counts and the last answer unknown before the
%% first exchange; a kiss is one of the known atoms, never the server's bytes.
status_test() ->
    {_, S0} = erx_ntp_core:start([<<"pool">>]),
    ?assertEqual(#{servers => [<<"pool">>], addresses => [], denied => [], interval_s => 64, resolve_wait_s => 2,
                   samples => unknown, dropped => unknown, kisses => unknown, silent => unknown, last => unknown},
                 erx_ntp_core:status(S0)),
    {_, S1} = erx_ntp_core:step({resolved, [?A, ?B]}, S0),
    {_, S2} = erx_ntp_core:step({exchanged, {kiss, <<"XYZW">>}}, S1),
    ?assertMatch(#{addresses := [?A, ?B], samples := 0, kisses := 1, silent := 0, dropped := 0,
                   last := {?A, other}}, erx_ntp_core:status(S2)).
