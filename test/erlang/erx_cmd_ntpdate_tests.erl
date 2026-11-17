%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the command shell's `ntpdate` (docs/design-time.md, "Setting
%% the clock from a server once"): the flags it takes and those it refuses,
%% -t's bounds, the operand count and length, and how it writes seconds.
-module(erx_cmd_ntpdate_tests).

-include_lib("eunit/include/eunit.hrl").

parse_test_() ->
    Ok = fun(Args) -> {ok, Options} = erx_cmd_ntpdate:parse(Args), Options end,
    [?_assertEqual(#{query => false, timeout_ms => 1000, servers => [<<"pool.example">>]},
                   Ok([<<"pool.example">>])),
     ?_assertEqual(#{query => true, timeout_ms => 1000, servers => [<<"192.0.2.1">>, <<"b">>]},
                   Ok([<<"-4bqu">>, <<"192.0.2.1">>, <<"b">>])),
     ?_assertMatch(#{timeout_ms := 200}, Ok([<<"-t">>, <<"0.2">>, <<"a">>])),
     ?_assertMatch(#{timeout_ms := 10000}, Ok([<<"-t10">>, <<"a">>])),
     ?_assertMatch(#{timeout_ms := 2500}, Ok([<<"-t">>, <<"9">>, <<"-t">>, <<"2.5">>, <<"a">>])),
     ?_assertMatch(#{servers := [<<"-q">>]}, Ok([<<"--">>, <<"-q">>])),
     ?_assertMatch(#{servers := [_, _, _, _, _, _, _, _]}, Ok(lists:duplicate(8, <<"a">>)))].

usage_test_() ->
    Usage = fun(Args) -> ?_assertEqual({error, usage}, erx_cmd_ntpdate:parse(Args)) end,
    [Usage([]),
     Usage([<<"-q">>]),
     Usage(lists:duplicate(9, <<"a">>)),
     Usage([<<>>]),
     Usage([binary:copy(<<"a">>, 254)]),
     %% Flags ntpdate(8) has that erXos does not offer.
     Usage([<<"-B">>, <<"a">>]),
     Usage([<<"-6">>, <<"a">>]),
     Usage([<<"-d">>, <<"a">>]),
     Usage([<<"-p">>, <<"4">>, <<"a">>]),
     %% -t one tenth past either edge, and timeouts that are not decimals.
     Usage([<<"-t">>, <<"0.1">>, <<"a">>]),
     Usage([<<"-t">>, <<"10.1">>, <<"a">>]),
     Usage([<<"-t">>, <<"1.25">>, <<"a">>]),
     Usage([<<"-t">>, <<"x">>, <<"a">>]),
     Usage([<<"-t">>, <<".5">>, <<"a">>]),
     Usage([<<"-t">>, <<"1.">>, <<"a">>]),
     Usage([<<"-t">>])].

seconds_test_() ->
    [?_assertEqual(<<"1234.567890">>, erx_cmd_ntpdate:seconds(1234567890123, 6)),
     ?_assertEqual(<<"-0.001500">>, erx_cmd_ntpdate:seconds(-1500000, 6)),
     ?_assertEqual(<<"0.000000">>, erx_cmd_ntpdate:seconds(0, 6)),
     ?_assertEqual(<<"0.01234">>, erx_cmd_ntpdate:seconds(12345678, 5))].

%% What a datagram on an exchange's socket is: one that does not decode, or answers
%% another request or another mode, is foreign, so the wait goes on; this exchange's
%% answer gets erx_ntp_sample's verdict, a sample or a reply that is none.
classify_test_() ->
    Nonce = 16#0123456789abcdef,
    T = (1794873600 + 2208988800) bsl 32,
    Reply = #{leap => 0, version => 4, mode => 4, stratum => 2, poll => 6, precision => -20,
              root_delay => 0, root_dispersion => 0, reference_id => <<"GPS", 0>>,
              reference_time => 0, originate_time => Nonce, receive_time => T, transmit_time => T},
    Classify = fun(Packet) -> erx_cmd_ntpdate:classify(Packet, Nonce, 5000000000, 5020000000) end,
    [?_assertEqual(foreign, Classify(<<0:47/unit:8>>)),
     ?_assertEqual(foreign, Classify(erx_ntp_wire:encode(Reply#{originate_time := Nonce + 1}))),
     ?_assertEqual(foreign, Classify(erx_ntp_wire:encode(Reply#{version := 3}))),
     ?_assertMatch({sample, #{stratum := 2}}, Classify(erx_ntp_wire:encode(Reply))),
     ?_assertEqual({drop, stratum}, Classify(erx_ntp_wire:encode(Reply#{stratum := 16}))),
     ?_assertEqual({kiss, <<"RATE">>}, Classify(erx_ntp_wire:encode(Reply#{stratum := 0, reference_id := <<"RATE">>})))].
