%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of ntpd's pure core, erx_ntp_core (docs/design-time.md, "The
%% client" and "Verification and testing"): the start flags' server list, the
%% schedule over generated event sequences, and the clock facet request a
%% checked sample gives. Seeded faults: accepting a ninth entry passes the
%% nine-entry case; a poll floor of 8 s fails the spacing property; and a
%% wait of the 2 s burst gap after a clock answer, in place of the interval,
%% which leaves the interval itself within bounds, fails the property at its
%% spacing assertion (perform/3's poll clause).
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
    {{resolve, [<<"pool">>]}, S0} = erx_ntp_core:start([<<"pool">>]),
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

resolve_backoff_test() ->
    {_, S0} = erx_ntp_core:start([<<"pool">>]),
    {{wait, 15000}, S1} = erx_ntp_core:step({resolved, []}, S0),
    {{resolve, _}, S2} = erx_ntp_core:step(woke, S1),
    {{wait, 30000}, _} = erx_ntp_core:step({resolved, []}, S2).

deny_removes_address_test() ->
    {_, S0} = erx_ntp_core:start([<<"pool">>]),
    {{exchange, ?A, poll}, S1} = erx_ntp_core:step({resolved, [?A, ?B]}, S0),
    {{wait, ?MIN_POLL_MS}, S2} = erx_ntp_core:step({exchanged, {kiss, <<"DENY">>}}, S1),
    {{exchange, ?B, poll}, S3} = erx_ntp_core:step(woke, S2),
    %% A new resolution does not bring the denied address back.
    {{wait, ?MIN_POLL_MS}, S4} = erx_ntp_core:step({exchanged, {kiss, <<"RSTR">>}}, S3),
    {{resolve, _}, S5} = erx_ntp_core:step(woke, S4),
    {{wait, 15000}, _} = erx_ntp_core:step({resolved, [?A, ?B]}, S5).

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

%% Over generated runs: no two polls of an address closer than the 64 s
%% floor, a burst only after an address's first poll and at most three
%% burst exchanges a poll, and the interval within 64 s to 1024 s.
schedule_property_test() ->
    rand:seed(exsss, {1, 2, 3}),
    lists:foreach(fun(_) -> run(400) end, lists:seq(1, 200)).

run(Steps) ->
    {Action, State} = erx_ntp_core:start([<<"pool">>]),
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
    Found = lists:sublist([?A, ?B, {192, 0, 2, rand:uniform(3)}], rand:uniform(4) - 1),
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
    ?assertEqual(#{servers => [<<"pool">>], addresses => [], denied => [], interval_s => 64, resolve_wait_s => 15,
                   samples => unknown, dropped => unknown, kisses => unknown, silent => unknown, last => unknown},
                 erx_ntp_core:status(S0)),
    {_, S1} = erx_ntp_core:step({resolved, [?A, ?B]}, S0),
    {_, S2} = erx_ntp_core:step({exchanged, {kiss, <<"XYZW">>}}, S1),
    ?assertMatch(#{addresses := [?A, ?B], samples := 0, kisses := 1, silent := 0, dropped := 0,
                   last := {?A, other}}, erx_ntp_core:status(S2)).
