%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_hid_core, the HID function's fold (docs/design-usb.md, "From
%% reports to records"), over layouts erx_hid_desc parses from descriptors the
%% descriptor's cases write. Every evdev code is written out, so a code changed in
%% abi/formats/evdev.txt or hid.txt fails a case instead of moving with the module.
-module(erx_hid_core_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erx_hid_desc_tests, [usage_page/1, usage/1, usage_min/1, usage_max/1, logical_min/1, logical_max/1,
                             report_size/1, report_count/1, report_id/1, input/1]).

-define(KEY_LEFTCTRL, 29).
-define(KEY_A, 30).
-define(KEY_LEFTSHIFT, 42).
-define(KEY_C, 46).
-define(KEY_B, 48).
-define(BTN_LEFT, 16#110).
-define(BTN_RIGHT, 16#111).

layout(Descriptor) ->
    {ok, Layout} = erx_hid_desc:parse(iolist_to_binary(Descriptor)),
    Layout.

keyboard() -> layout(erx_hid_desc_tests:boot_keyboard()).
mouse() -> layout(erx_hid_desc_tests:boot_mouse()).
tablet() -> layout(erx_hid_desc_tests:tablet()).

%% Folds reports in turn and answers the records of each.
fold(Layout, Reports) ->
    {_, Records} = steps(Layout, Reports),
    Records.

%% Folds reports in turn: the state after the last, and the records of each.
steps(Layout, Reports) ->
    {Records, State} = lists:mapfoldl(fun(Report, S) ->
                                          {Next, Out} = erx_hid_core:step(Layout, Report, S),
                                          {Out, Next}
                                      end, erx_hid_core:new(Layout), Reports),
    {State, Records}.

%% A one-byte key array under report id Id.
key_array(Id) ->
    [report_id(Id), usage_page(7), usage_min(0), usage_max(101), logical_min(0), logical_max(101),
     report_size(8), report_count(1), input(0)].

the_held_set_gives_ups_then_downs_in_code_order_test() ->
    ?assertEqual([[{key, down, ?KEY_A}, {key, down, ?KEY_B}],
                  [{key, up, ?KEY_A}, {key, down, ?KEY_C}],
                  [{key, down, ?KEY_LEFTCTRL}, {key, down, ?KEY_LEFTSHIFT}],
                  [{key, up, ?KEY_LEFTCTRL}, {key, up, ?KEY_LEFTSHIFT}, {key, up, ?KEY_C}, {key, up, ?KEY_B}]],
                 fold(keyboard(), [<<0, 0, 16#05, 16#04, 0, 0, 0, 0>>,
                                   <<0, 0, 16#05, 16#06, 0, 0, 0, 0>>,
                                   <<2#11, 0, 16#05, 16#06, 0, 0, 0, 0>>,
                                   <<0, 0, 0, 0, 0, 0, 0, 0>>])).

a_rollover_report_changes_nothing_test() ->
    ?assertEqual([[{key, down, ?KEY_A}], [], [{key, up, ?KEY_A}]],
                 fold(keyboard(), [<<0, 0, 16#04, 0, 0, 0, 0, 0>>,
                                   <<2#10, 0, 1, 1, 1, 1, 1, 1>>,
                                   <<0, 0, 0, 0, 0, 0, 0, 0>>])).

an_absolute_position_normalizes_to_0_and_65535_at_its_ends_test() ->
    ?assertEqual([[{pointer, abs, 0, 0}], [{pointer, abs, 65535, 65535}], [], [{pointer, abs, 32766, 65535}]],
                 fold(tablet(), [<<1, 0, 0, 0, 0, 0>>,
                                 <<1, 0, 16#ff, 16#7f, 16#ff, 16#7f>>,
                                 <<1, 0, 16#ff, 16#7f, 16#ff, 16#7f>>,
                                 <<1, 0, 16#ff, 16#3f, 16#ff, 16#ff>>])).

a_report_of_id_2_leaves_id_1s_keys_held_test() ->
    ?assertEqual([[{key, down, ?KEY_A}], [{key, down, ?KEY_B}], [{key, up, ?KEY_B}], [{key, up, ?KEY_A}]],
                 fold(layout([key_array(1), key_array(2)]), [<<1, 16#04>>, <<2, 16#05>>, <<2, 0>>, <<1, 0>>])).

a_report_two_packets_long_folds_whole_test() ->
    Layout = layout([report_size(8), report_count(100), input(1), tl(key_array(1))]),
    ?assertEqual(101, erx_hid_core:transfer_length(Layout)),
    ?assertEqual([[{key, down, ?KEY_A}]], fold(Layout, [<<0:800, 16#04>>])).

moves_come_before_button_edges_test() ->
    ?assertEqual([[{pointer, rel, 5, -5}, {key, down, ?BTN_LEFT}],
                  [{key, down, ?BTN_RIGHT}],
                  [{pointer, rel, -1, 0}, {key, up, ?BTN_LEFT}, {key, up, ?BTN_RIGHT}]],
                 fold(mouse(), [<<2#001, 5, 16#fb>>, <<2#011, 0, 0>>, <<0, 16#ff, 0>>])).

the_wheel_is_clamped_to_its_record_range_test() ->
    Layout = layout([usage_page(1), usage(16#38), logical_min(-32768), logical_max(32767),
                     report_size(16), report_count(1), input(6)]),
    ?assertEqual([[{wheel, 127}], [], [{wheel, -128}], [{wheel, -3}]],
                 fold(Layout, [<<300:16/little>>, <<0:16>>, <<-300:16/little>>, <<-3:16/little>>])).

short_reports_and_unknown_ids_are_dropped_and_counted_test() ->
    Layout = tablet(),
    {State, Records} = steps(Layout, [<<1, 0, 0, 0>>, <<2, 0, 0, 0, 0, 0>>, <<>>]),
    ?assertEqual([[], [], []], Records),
    ?assertEqual(#{short => 2, unknown_id => 1, unmapped => 0}, erx_hid_core:counts(State)).

a_key_usage_with_no_code_is_dropped_and_counted_test() ->
    Layout = keyboard(),
    {State, Records} = erx_hid_core:step(Layout, <<0, 0, 16#02, 16#04, 0, 0, 0, 0>>, erx_hid_core:new(Layout)),
    ?assertEqual([{key, down, ?KEY_A}], Records),
    ?assertEqual(#{short => 0, unknown_id => 0, unmapped => 1}, erx_hid_core:counts(State)).

roles_come_from_usages_test() ->
    ?assertEqual([keys], erx_hid_core:roles(keyboard())),
    ?assertEqual([pointer, buttons], erx_hid_core:roles(mouse())),
    ?assertEqual([pointer, buttons], erx_hid_core:roles(tablet())),
    Flat = layout([usage_page(1), usage(16#30), usage(16#31), logical_min(5), logical_max(5),
                   report_size(8), report_count(2), input(2)]),
    ?assertEqual([], erx_hid_core:roles(Flat)),
    OnlyX = layout([usage_page(1), usage(16#30), report_size(8), report_count(1), input(6)]),
    ?assertEqual([], erx_hid_core:roles(OnlyX)).

the_transfer_carries_the_report_id_byte_test() ->
    ?assertEqual(8, erx_hid_core:transfer_length(keyboard())),
    ?assertEqual(6, erx_hid_core:transfer_length(tablet())).
