%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_wifi_memory (docs/design-wifi.md, "Failure memory"): a BSS's hold from its
%% first failure, 10 s doubling to 300 s; a secret's from the third consecutive
%% `secret` end, 300 s doubling to an hour; what forgets each; the bound of 32 BSS
%% records; all compared with the time each call is given, in milliseconds.
-module(erx_wifi_memory_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, <<1, 0, 0, 0, 0, 1>>).
-define(B, <<1, 0, 0, 0, 0, 2>>).
-define(SSID, <<"home">>).
-define(S, 1000).

fails(Memory, Class, Bssid, Times) ->
    lists:foldl(fun(Now, M) -> erx_wifi_memory:fail(M, {Class, Bssid, ?SSID}, Now) end, Memory, Times).

a_bss_is_held_from_its_first_failure_doubling_to_300_s_test() ->
    M1 = fails(erx_wifi_memory:new(), bss, ?A, [0]),
    ?assertEqual({bss, 10 * ?S}, erx_wifi_memory:held(M1, {?A, ?SSID}, 0)),
    ?assertEqual({bss, 10 * ?S}, erx_wifi_memory:held(M1, {?A, ?SSID}, 10 * ?S - 1)),
    ?assertEqual(none, erx_wifi_memory:held(M1, {?A, ?SSID}, 10 * ?S)),
    ?assertEqual(none, erx_wifi_memory:held(M1, {?B, ?SSID}, 0)),
    Holds = [begin
                 M = fails(erx_wifi_memory:new(), bss, ?A, lists:duplicate(N, 0)),
                 {bss, Until} = erx_wifi_memory:held(M, {?A, ?SSID}, 0),
                 Until
             end || N <- lists:seq(1, 8)],
    ?assertEqual([10, 20, 40, 80, 160, 300, 300, 300], [Until div ?S || Until <- Holds]).

a_none_end_counts_nothing_test() ->
    M = fails(erx_wifi_memory:new(), none, ?A, [0, 1, 2]),
    ?assertEqual(none, erx_wifi_memory:held(M, {?A, ?SSID}, 0)).

a_port_that_stayed_open_forgets_its_records_test() ->
    M = fails(erx_wifi_memory:new(), secret, ?A, [0, 0, 0]),
    Ok = erx_wifi_memory:ok(M, {?A, ?SSID}),
    ?assertEqual(none, erx_wifi_memory:held(Ok, {?A, ?SSID}, 0)),
    ?assertEqual({bss, 10 * ?S}, erx_wifi_memory:held(fails(Ok, bss, ?A, [0]), {?A, ?SSID}, 0)).

a_bss_record_is_forgotten_an_hour_after_its_hold_ended_test() ->
    M = fails(erx_wifi_memory:new(), bss, ?A, [0, 0]),
    Before = 20 * ?S + 3600 * ?S - 1,
    ?assertEqual({bss, Before + 40 * ?S}, erx_wifi_memory:held(fails(M, bss, ?A, [Before]), {?A, ?SSID}, Before)),
    After = 20 * ?S + 3600 * ?S,
    ?assertEqual({bss, After + 10 * ?S}, erx_wifi_memory:held(fails(M, bss, ?A, [After]), {?A, ?SSID}, After)).

one_secret_end_holds_only_the_bss_as_a_lost_frame_may_test() ->
    M = fails(erx_wifi_memory:new(), secret, ?A, [0]),
    ?assertEqual({bss, 10 * ?S}, erx_wifi_memory:held(M, {?A, ?SSID}, 0)),
    ?assertEqual(none, erx_wifi_memory:held(M, {?B, ?SSID}, 0)).

the_third_secret_end_holds_the_secret_doubling_to_an_hour_test() ->
    Two = fails(erx_wifi_memory:new(), secret, ?A, [0, 0]),
    ?assertEqual(none, erx_wifi_memory:held(Two, {?B, ?SSID}, 0)),
    Holds = [begin
                 M = fails(erx_wifi_memory:new(), secret, ?A, lists:duplicate(N, 0)),
                 {secret_failed, Until} = erx_wifi_memory:held(M, {?B, ?SSID}, 0),
                 ?assertEqual({secret_failed, Until}, erx_wifi_memory:held(M, {?A, ?SSID}, 0)),
                 Until
             end || N <- lists:seq(3, 8)],
    ?assertEqual([300, 600, 1200, 2400, 3600, 3600], [Until div ?S || Until <- Holds]).

the_ctl_names_command_ends_every_secret_hold_test() ->
    M = erx_wifi_memory:forget_secrets(fails(erx_wifi_memory:new(), secret, ?A, [0, 0, 0])),
    ?assertEqual(none, erx_wifi_memory:held(M, {?B, ?SSID}, 0)),
    ?assertMatch({bss, _}, erx_wifi_memory:held(M, {?A, ?SSID}, 0)),
    ?assertMatch({bss, _}, erx_wifi_memory:held(fails(M, secret, ?A, [0]), {?A, ?SSID}, 0)).

at_most_32_bss_records_dropping_the_one_whose_hold_ends_first_test() ->
    Bssids = [<<2, 0, 0, 0, 0, N>> || N <- lists:seq(1, 33)],
    M = lists:foldl(fun({N, Bssid}, Acc) -> erx_wifi_memory:fail(Acc, {bss, Bssid, ?SSID}, N) end,
                    erx_wifi_memory:new(), lists:enumerate(Bssids)),
    [First | Rest] = Bssids,
    ?assertEqual(none, erx_wifi_memory:held(M, {First, ?SSID}, 33)),
    ?assert(lists:all(fun(Bssid) -> erx_wifi_memory:held(M, {Bssid, ?SSID}, 33) =/= none end, Rest)).

a_bss_just_counted_is_held_even_when_its_hold_ends_first_test() ->
    Full = lists:foldl(fun(N, Acc) -> fails(Acc, bss, <<2, 0, 0, 0, 0, N>>, lists:duplicate(6, 0)) end,
                       erx_wifi_memory:new(), lists:seq(1, 32)),
    M = fails(Full, bss, ?A, [?S]),
    ?assertEqual({bss, 11 * ?S}, erx_wifi_memory:held(M, {?A, ?SSID}, ?S)),
    Held = [N || N <- lists:seq(1, 32), erx_wifi_memory:held(M, {<<2, 0, 0, 0, 0, N>>, ?SSID}, ?S) =/= none],
    ?assertEqual(31, length(Held)).

a_held_secret_reads_until_the_later_of_its_two_holds_test() ->
    Secret = fails(erx_wifi_memory:new(), secret, ?A, [0, 0, 0]),
    ?assertEqual({secret_failed, 300 * ?S}, erx_wifi_memory:held(Secret, {?A, ?SSID}, 0)),
    Later = fails(Secret, bss, ?A, [250 * ?S]),
    ?assertEqual({secret_failed, 330 * ?S}, erx_wifi_memory:held(Later, {?A, ?SSID}, 250 * ?S)),
    ?assertEqual({secret_failed, 300 * ?S}, erx_wifi_memory:held(Later, {?B, ?SSID}, 250 * ?S)),
    ?assertEqual({bss, 330 * ?S}, erx_wifi_memory:held(Later, {?A, ?SSID}, 300 * ?S)).
