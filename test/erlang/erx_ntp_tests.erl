%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the NTP codec erx_ntp_wire and the checks of one reply,
%% erx_ntp_sample (docs/design-time.md, "Checks on a reply" and "Verification
%% and testing"): the era conversion, the offset of a board at 1970 against a
%% 2026 server, each check refusing a reply built to break only it, the
%% kiss-o'-death, and the distance's clamp of a negative root delay; and what
%% one datagram is to an exchange (erx_ntp_exchange:classify/4).
-module(erx_ntp_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NS, 1000000000).
-define(UNIX_EPOCH, 2208988800).
-define(NONCE, 16#0123456789abcdef).

%% 2026-11-17 00:00:00 UTC, as seconds since 1970.
unix_2026() ->
    calendar:datetime_to_gregorian_seconds({{2026, 11, 17}, {0, 0, 0}})
        - calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).

%% The NTP timestamp of a time in nanoseconds since 1970, in 1968-2036.
timestamp(Ns) ->
    Seconds = Ns div ?NS + ?UNIX_EPOCH,
    (Seconds bsl 32) bor (((Ns rem ?NS) bsl 32) div ?NS).

%% A valid server reply to ?NONCE: stratum 2, receive and transmit at T2 and T3.
reply(T2, T3) ->
    #{leap => 0, version => 4, mode => 4, stratum => 2, poll => 6, precision => -20,
      root_delay => 16#00000800, root_dispersion => 16#00000400, reference_id => <<"GPS", 0>>,
      reference_time => timestamp(T2 - ?NS), originate_time => ?NONCE, receive_time => timestamp(T2),
      transmit_time => timestamp(T3)}.

%% A reply for an exchange sent at 5 s of uptime and answered 20 ms later, with the
%% server's 2026 times half a second past T, a fraction a timestamp holds exactly.
exchange() ->
    T = unix_2026() * ?NS,
    {reply(T + 500000000, T + 500000000), 5 * ?NS, 5 * ?NS + 20000000, T}.

era_test_() ->
    [?_assertEqual((16#80000000 - ?UNIX_EPOCH) * ?NS, erx_ntp_wire:time_ns(16#80000000 bsl 32)),
     ?_assertEqual((16#ffffffff - ?UNIX_EPOCH) * ?NS, erx_ntp_wire:time_ns(16#ffffffff bsl 32)),
     %% Past 2036-02-07 06:28:16 the seconds wrap to 0, era 1.
     ?_assertEqual((16#100000000 - ?UNIX_EPOCH) * ?NS, erx_ntp_wire:time_ns(0)),
     ?_assertEqual((16#100000000 - ?UNIX_EPOCH) * ?NS + 500000000, erx_ntp_wire:time_ns(16#80000000)),
     ?_assertEqual(unix_2026() * ?NS, erx_ntp_wire:time_ns(timestamp(unix_2026() * ?NS)))].

short_test_() ->
    [?_assertEqual(-4 * ?NS, erx_ntp_wire:short_ns(-4 * 65536)),
     ?_assertEqual(?NS div 2, erx_ntp_wire:short_ns(32768))].

codec_test_() ->
    {Reply, _, _, _} = exchange(),
    Bytes = erx_ntp_wire:encode(Reply),
    [?_assertEqual(48, byte_size(Bytes)),
     ?_assertEqual({ok, Reply}, erx_ntp_wire:decode(Bytes)),
     %% Extension fields and a MAC after the header are ignored.
     ?_assertEqual({ok, Reply}, erx_ntp_wire:decode(<<Bytes/binary, 0:160>>)),
     ?_assertEqual({error, short}, erx_ntp_wire:decode(binary:part(Bytes, 0, 47))),
     ?_assertEqual({error, short}, erx_ntp_wire:decode(not_a_binary)),
     %% A root delay with its top bit set is negative, not 18 hours.
     ?_assertMatch({ok, #{root_delay := -65536}},
                   erx_ntp_wire:decode(erx_ntp_wire:encode(Reply#{root_delay := -65536})))].

request_test() ->
    Request = erx_ntp_wire:request(?NONCE),
    ?assertEqual(<<16#23, 0:(39 * 8), ?NONCE:64>>, Request).

sample_test() ->
    {Reply, M1, M4, T} = exchange(),
    {sample, Sample} = erx_ntp_sample:check(Reply, ?NONCE, M1, M4),
    %% W = ((t2 - m1) + (t3 - m4)) div 2, the server's time less the monotonic time,
    %% exactly, though 1970 and 2026 are 56 years apart.
    ?assertEqual(T + 500000000 - 5 * ?NS - 10000000, maps:get(offset, Sample)),
    ?assertEqual(20000000, maps:get(delay, Sample)),
    %% (root delay 1/32 s + 20 ms) div 2 + root dispersion 1/64 s.
    ?assertEqual((31250000 + 20000000) div 2 + 15625000, maps:get(distance, Sample)),
    ?assertEqual(2, maps:get(stratum, Sample)).

%% Each check refuses a reply built to break it alone, with its reason.
checks_test_() ->
    {Reply, M1, M4, T} = exchange(),
    Check = fun(Broken) -> erx_ntp_sample:check(Broken, ?NONCE, M1, M4) end,
    [?_assertEqual({foreign, nonce}, Check(Reply#{originate_time := ?NONCE + 1})),
     ?_assertEqual({foreign, mode}, Check(Reply#{mode := 5})),
     ?_assertEqual({foreign, mode}, Check(Reply#{version := 3})),
     ?_assertEqual({drop, unsynchronized}, Check(Reply#{leap := 3})),
     ?_assertEqual({drop, stratum}, Check(Reply#{stratum := 16})),
     ?_assertEqual({drop, timestamps}, Check(Reply#{transmit_time := 0})),
     ?_assertEqual({drop, timestamps}, Check(Reply#{receive_time := 0})),
     ?_assertEqual({drop, timestamps}, Check(Reply#{receive_time := timestamp(T + ?NS)})),
     %% A receive time in 1969 lies before the range.
     ?_assertEqual({drop, timestamps}, Check(Reply#{receive_time := timestamp(0) - (1 bsl 32)})),
     ?_assertEqual({drop, reference}, Check(Reply#{reference_time := timestamp(T + 2 * ?NS)})),
     ?_assertMatch({sample, _}, Check(Reply#{reference_time := 0})),
     %% The server held the request 30 ms of a 20 ms exchange.
     ?_assertEqual({drop, delay}, Check(Reply#{transmit_time := timestamp(T + 540000000)})),
     ?_assertEqual({drop, distance}, Check(Reply#{root_dispersion := 65536}))].

%% A server time earlier than the uptime since 1970 implies a wall offset W below zero,
%% which no time page holds and the clock facet refuses, so it is no sample: a reply
%% that says 1970-01-01 00:00:01 to a client up for 5 s.
negative_offset_test() ->
    {Reply, M1, M4, _T} = exchange(),
    Early = Reply#{reference_time := 0, receive_time := timestamp(?NS), transmit_time := timestamp(?NS)},
    ?assertEqual({drop, timestamps}, erx_ntp_sample:check(Early, ?NONCE, M1, M4)).

%% A kiss is believed only after the nonce and mode checks, and nothing else of it is
%% read: not its leap indicator, nor its undefined timestamps.
kiss_test_() ->
    {Reply, M1, M4, _} = exchange(),
    Kiss = Reply#{stratum := 0, leap := 3, reference_id := <<"RATE">>, receive_time := 0, transmit_time := 0},
    [?_assertEqual({kiss, <<"RATE">>}, erx_ntp_sample:check(Kiss, ?NONCE, M1, M4)),
     ?_assertEqual({foreign, nonce}, erx_ntp_sample:check(Kiss, ?NONCE + 1, M1, M4))].

%% A negative root delay cancels neither the measured delay nor the dispersion.
distance_test_() ->
    {Reply, _, _, T} = exchange(),
    M1 = 5 * ?NS,
    M4 = M1 + 100000000,
    Negative = Reply#{root_delay := -4 * 65536, receive_time := timestamp(T), transmit_time := timestamp(T)},
    [?_assertEqual({drop, distance},
                   erx_ntp_sample:check(Negative#{root_dispersion := 2 * 65536}, ?NONCE, M1, M4)),
     ?_assertMatch({sample, #{distance := 50000000}},
                   erx_ntp_sample:check(Negative#{root_dispersion := 0}, ?NONCE, M1, M4))].

%% What a datagram on an exchange's socket is: one that does not decode, or answers
%% another request or another mode, is foreign, so the wait goes on; this exchange's
%% answer gets erx_ntp_sample's verdict, a sample or a reply that is none.
classify_test_() ->
    Nonce = 16#0123456789abcdef,
    T = (1794873600 + 2208988800) bsl 32,
    Reply = #{leap => 0, version => 4, mode => 4, stratum => 2, poll => 6, precision => -20,
              root_delay => 0, root_dispersion => 0, reference_id => <<"GPS", 0>>,
              reference_time => 0, originate_time => Nonce, receive_time => T, transmit_time => T},
    Classify = fun(Packet) -> erx_ntp_exchange:classify(Packet, Nonce, 5000000000, 5020000000) end,
    [?_assertEqual(foreign, Classify(<<0:47/unit:8>>)),
     ?_assertEqual(foreign, Classify(erx_ntp_wire:encode(Reply#{originate_time := Nonce + 1}))),
     ?_assertEqual(foreign, Classify(erx_ntp_wire:encode(Reply#{version := 3}))),
     ?_assertMatch({sample, #{stratum := 2}}, Classify(erx_ntp_wire:encode(Reply))),
     ?_assertEqual({drop, stratum}, Classify(erx_ntp_wire:encode(Reply#{stratum := 16}))),
     ?_assertEqual({kiss, <<"RATE">>}, Classify(erx_ntp_wire:encode(Reply#{stratum := 0, reference_id := <<"RATE">>})))].
