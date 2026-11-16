%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_hid_desc, the HID report descriptor's parser (docs/design-usb.md,
%% "The report descriptor"). Descriptors are written item by item with the encoders
%% below, which erx_hid_desc_fuzz shares; every number is written out here, so a value
%% changed in abi/formats/hid.txt fails a case instead of moving with the module.
-module(erx_hid_desc_tests).

-include_lib("eunit/include/eunit.hrl").

-export([usage_page/1, usage/1, usage_min/1, usage_max/1, logical_min/1, logical_max/1,
         report_size/1, report_count/1, report_id/1, input/1, output/1, feature/1,
         collection/1, end_collection/0, push/0, pop/0, boot_keyboard/0, boot_mouse/0,
         tablet/0]).

%% A short item (HID 1.11, section 6.2.2.2): the prefix's tag, type and size code, then
%% the value in the fewest bytes that hold it signed, as descriptors are written.
short(Type, Tag, 0) -> <<Tag:4, Type:2, 0:2>>;
short(Type, Tag, V) when V >= -16#80, V =< 16#7f -> <<Tag:4, Type:2, 1:2, V:8/signed>>;
short(Type, Tag, V) when V >= -16#8000, V =< 16#7fff -> <<Tag:4, Type:2, 2:2, V:16/little-signed>>;
short(Type, Tag, V) -> <<Tag:4, Type:2, 3:2, V:32/little>>.

input(Flags) -> short(0, 8, Flags).
output(Flags) -> short(0, 9, Flags).
collection(Kind) -> short(0, 10, Kind).
feature(Flags) -> short(0, 11, Flags).
end_collection() -> short(0, 12, 0).
usage_page(Page) -> short(1, 0, Page).
logical_min(V) -> short(1, 1, V).
logical_max(V) -> short(1, 2, V).
report_size(N) -> short(1, 7, N).
report_id(N) -> short(1, 8, N).
report_count(N) -> short(1, 9, N).
push() -> short(1, 10, 0).
pop() -> short(1, 11, 0).
usage(U) -> short(2, 0, U).
usage_min(U) -> short(2, 1, U).
usage_max(U) -> short(2, 2, U).

%% The Input item's data bits (HID 1.11, section 6.2.2.4).
-define(DATA_ARRAY_ABS, 0).
-define(CONSTANT, 1).
-define(DATA_VAR_ABS, 2).
-define(DATA_VAR_REL, 6).

%% A descriptor of the boot keyboard's report of HID 1.11, Appendix B.1: eight modifier
%% bits, a reserved byte, five LED bits and their padding as output, and six key bytes.
boot_keyboard() ->
    iolist_to_binary(
      [usage_page(1), usage(6), collection(1),
       usage_page(7), usage_min(16#e0), usage_max(16#e7), logical_min(0), logical_max(1),
       report_size(1), report_count(8), input(?DATA_VAR_ABS),
       report_count(1), report_size(8), input(?CONSTANT),
       report_count(5), report_size(1), usage_page(8), usage_min(1), usage_max(5), output(?DATA_VAR_ABS),
       report_count(1), report_size(3), output(?CONSTANT),
       report_count(6), report_size(8), logical_min(0), logical_max(101),
       usage_page(7), usage_min(0), usage_max(101), input(?DATA_ARRAY_ABS),
       end_collection()]).

%% A descriptor of the boot mouse's report of HID 1.11, Appendix B.2: three button bits,
%% five bits of padding, and a relative X and Y byte.
boot_mouse() ->
    iolist_to_binary(
      [usage_page(1), usage(2), collection(1), usage(1), collection(0),
       usage_page(9), usage_min(1), usage_max(3), logical_min(0), logical_max(1),
       report_count(3), report_size(1), input(?DATA_VAR_ABS),
       report_count(1), report_size(5), input(?CONSTANT),
       usage_page(1), usage(16#30), usage(16#31), logical_min(-127), logical_max(127),
       report_size(8), report_count(2), input(?DATA_VAR_REL),
       end_collection(), end_collection()]).

%% A tablet of report id 1: one button, padding, and an absolute X and Y of 15 bits.
tablet() ->
    iolist_to_binary(
      [usage_page(1), usage(2), collection(1), report_id(1),
       usage_page(9), usage(1), logical_min(0), logical_max(1), report_size(1), report_count(1),
       input(?DATA_VAR_ABS), report_size(7), input(?CONSTANT),
       usage_page(1), usage(16#30), usage(16#31), logical_min(0), logical_max(16#7fff),
       report_size(16), report_count(2), input(?DATA_VAR_ABS),
       end_collection()]).

parse(Items) -> erx_hid_desc:parse(iolist_to_binary(Items)).

%% A variable input byte under report id Id.
byte_of(Id) -> [report_id(Id), report_size(8), report_count(1), input(?DATA_VAR_ABS)].

boot_keyboard_parses_to_the_report_of_appendix_b1_test() ->
    Modifiers = #{offset => 0, size => 1, count => 8, min => 0, max => 1,
                  usages => [{16#700e0, 16#700e7}], variable => true, relative => false},
    Keys = #{offset => 16, size => 8, count => 6, min => 0, max => 101,
             usages => [{16#70000, 16#70065}], variable => false, relative => false},
    ?assertEqual({ok, #{reports => #{0 => #{fields => [Modifiers, Keys], bytes => 8}},
                        numbered => false, largest => 8}},
                 erx_hid_desc:parse(boot_keyboard())).

boot_mouse_parses_to_buttons_and_relative_axes_test() ->
    Buttons = #{offset => 0, size => 1, count => 3, min => 0, max => 1,
                usages => [{16#90001, 16#90003}], variable => true, relative => false},
    Axes = #{offset => 8, size => 8, count => 2, min => -127, max => 127,
             usages => [{16#10030, 16#10030}, {16#10031, 16#10031}], variable => true, relative => true},
    ?assertEqual({ok, #{reports => #{0 => #{fields => [Buttons, Axes], bytes => 3}},
                        numbered => false, largest => 3}},
                 erx_hid_desc:parse(boot_mouse())).

report_ids_place_fields_at_positions_of_their_own_test() ->
    {ok, #{reports := Reports, numbered := true, largest := 3}} =
        parse([byte_of(1), byte_of(2), report_size(16), input(?DATA_VAR_ABS), byte_of(1)]),
    ?assertEqual([{0, 8}, {8, 8}], [{O, S} || #{offset := O, size := S} <- maps:get(fields, maps:get(1, Reports))]),
    ?assertEqual([{0, 8}, {8, 16}], [{O, S} || #{offset := O, size := S} <- maps:get(fields, maps:get(2, Reports))]),
    ?assertEqual(2, maps:get(bytes, maps:get(1, Reports))),
    ?assertEqual(3, maps:get(bytes, maps:get(2, Reports))).

three_pushes_are_accepted_and_a_fourth_is_refused_test() ->
    Byte = [report_size(8), report_count(1), input(?DATA_VAR_ABS)],
    ?assertMatch({ok, _}, parse([push(), push(), push(), Byte, pop(), pop(), pop()])),
    ?assertEqual({error, push_too_deep}, parse([push(), push(), push(), push(), Byte])).

pop_restores_the_globals_pushed_test() ->
    {ok, #{reports := #{0 := #{fields := [Field]}}}} =
        parse([report_size(8), report_count(1), logical_max(9), push(), report_size(4), logical_max(3), pop(),
               input(?DATA_VAR_ABS)]),
    ?assertMatch(#{size := 8, max := 9}, Field).

pop_restores_the_report_id_and_its_position_test() ->
    {ok, #{reports := Reports}} = parse([byte_of(1), push(), byte_of(2), byte_of(2), pop(), input(?DATA_VAR_ABS)]),
    ?assertEqual([0, 8], [O || #{offset := O} <- maps:get(fields, maps:get(1, Reports))]).

pop_without_push_is_refused_test() ->
    ?assertEqual({error, pop_without_push}, parse([push(), pop(), pop()])).

end_collection_without_collection_is_refused_test() ->
    ?assertEqual({error, unbalanced_collection}, parse([collection(1), end_collection(), end_collection()])),
    ?assertMatch({ok, _}, parse([collection(1), collection(0), end_collection()])).

a_65th_usage_of_one_main_item_is_refused_test() ->
    Usages = [usage(U) || U <- lists:seq(1, 64)],
    Field = [report_size(1), report_count(64), input(?DATA_VAR_ABS)],
    ?assertMatch({ok, _}, parse([Usages, Field, Usages, Field])),
    ?assertEqual({error, too_many_usages}, parse([Usages, usage(65), Field])),
    ?assertEqual({error, too_many_usages}, parse([Usages, usage_min(1), usage_max(2), Field])).

a_report_count_above_2048_is_refused_test() ->
    ?assertMatch({ok, _}, parse([report_size(1), report_count(2048), input(?DATA_VAR_ABS)])),
    ?assertEqual({error, report_count_too_large}, parse([report_size(1), report_count(2049), output(?DATA_VAR_ABS)])).

the_report_bound_counts_the_id_byte_test() ->
    Bytes = fun(N) -> [report_size(8), report_count(N), input(?DATA_ARRAY_ABS)] end,
    ?assertMatch({ok, #{largest := 1024}}, parse(Bytes(1024))),
    ?assertEqual({error, report_too_large}, parse(Bytes(1025))),
    ?assertMatch({ok, #{largest := 1023}}, parse([report_id(1), Bytes(1023)])),
    ?assertEqual({error, report_too_large}, parse([report_id(1), Bytes(1024)])).

a_sixteenth_report_id_is_refused_test() ->
    Fifteen = [byte_of(Id) || Id <- lists:seq(1, 15)],
    {ok, #{reports := Reports}} = parse([Fifteen, byte_of(15), byte_of(1)]),
    ?assertEqual(lists:seq(1, 15), lists:sort(maps:keys(Reports))),
    ?assertEqual({error, too_many_report_ids}, parse([Fifteen, report_id(16)])).

a_report_id_outside_one_byte_is_refused_test() ->
    ?assertEqual({error, bad_report_id}, parse([report_id(0)])),
    ?assertEqual({error, bad_report_id}, parse([report_id(256)])),
    ?assertMatch({ok, _}, parse([report_id(255)])).

fields_outside_and_inside_numbered_reports_are_refused_test() ->
    Byte = [report_size(8), report_count(1), input(?DATA_VAR_ABS)],
    ?assertEqual({error, mixed_report_ids}, parse([Byte, byte_of(1)])),
    ?assertMatch({ok, #{numbered := true}}, parse([output(?DATA_VAR_ABS), byte_of(1)])).

truncated_items_are_refused_test() ->
    ?assertEqual({error, truncated}, erx_hid_desc:parse(<<16#75>>)),
    ?assertEqual({error, truncated}, erx_hid_desc:parse(<<16#77, 1, 2, 3>>)),
    ?assertEqual({error, truncated}, erx_hid_desc:parse(<<16#fe, 3, 16#10, 1, 2>>)),
    ?assertEqual({error, truncated}, erx_hid_desc:parse(<<16#fe, 0>>)).

a_long_item_is_skipped_whole_test() ->
    Long = <<16#fe, 3, 16#10, 16#75, 16#08, 16#81>>,
    ?assertEqual(erx_hid_desc:parse(boot_mouse()), erx_hid_desc:parse(<<Long/binary, (boot_mouse())/binary>>)).

a_four_byte_usage_names_its_own_page_test() ->
    {ok, #{reports := #{0 := #{fields := [#{usages := Usages}]}}}} =
        parse([usage_page(1), usage(16#30), <<16#0b, 16#38, 0, 16#0c, 0>>,
               report_size(8), report_count(2), input(?DATA_VAR_REL)]),
    ?assertEqual([{16#10030, 16#10030}, {16#c0038, 16#c0038}], Usages).

usage_ranges_follow_hid_c_test() ->
    Field = [report_size(1), report_count(1), input(?DATA_VAR_ABS)],
    UsagesOf = fun(Items) ->
                       {ok, #{reports := #{0 := #{fields := [#{usages := U}]}}}} = parse([usage_page(9), Items, Field]),
                       U
               end,
    ?assertEqual([], UsagesOf([usage_min(3), usage_max(1)])),
    ?assertEqual([{16#90001, 16#90001}], UsagesOf([usage_min(2), usage(1), usage_max(3)])),
    ?assertEqual([{16#90002, 16#90004}], UsagesOf([usage_max(4), usage_min(2)])).

the_locals_are_cleared_at_each_main_item_test() ->
    {ok, #{reports := #{0 := #{fields := [#{usages := First}, #{usages := Second}]}}}} =
        parse([usage_page(9), usage(1), report_size(1), report_count(1), input(?DATA_VAR_ABS),
               input(?DATA_VAR_ABS)]),
    ?assertEqual({[{16#90001, 16#90001}], []}, {First, Second}).

a_descriptor_above_its_bound_is_refused_test() ->
    ?assertMatch({ok, #{reports := #{}}}, erx_hid_desc:parse(binary:copy(<<0>>, 4096))),
    ?assertEqual({error, too_long}, erx_hid_desc:parse(binary:copy(<<0>>, 4097))).

an_input_field_wider_than_32_bits_is_refused_test() ->
    ?assertMatch({ok, _}, parse([report_size(32), report_count(1), input(?DATA_VAR_ABS)])),
    ?assertEqual({error, field_too_wide}, parse([report_size(33), report_count(1), input(?DATA_VAR_ABS)])),
    {ok, #{reports := #{0 := #{fields := [], bytes := 8}}}} =
        parse([report_size(64), report_count(1), input(?CONSTANT)]).

output_and_feature_items_keep_positions_of_their_own_test() ->
    {ok, #{reports := #{0 := #{fields := [#{offset := 0}], bytes := 1}}}} =
        parse([report_size(8), report_count(4), output(?DATA_VAR_ABS), feature(?DATA_VAR_ABS),
               report_count(1), input(?DATA_VAR_ABS)]).

a_tablet_has_absolute_axes_in_report_one_test() ->
    {ok, #{reports := #{1 := #{fields := [_Button, Axes], bytes := 5}}, numbered := true, largest := 5}} =
        erx_hid_desc:parse(tablet()),
    ?assertMatch(#{offset := 8, size := 16, count := 2, min := 0, max := 16#7fff, relative := false}, Axes).

one_byte_values_from_0x80_are_unsigned_where_hid_c_reads_them_so_test() ->
    %% Usage Page 7, Usage Minimum E0h, Usage Maximum E7h, Report Size 1 and Report
    %% Count 80h, each in one byte, then a variable Input, as Appendix B.1 writes them.
    {ok, #{reports := #{0 := #{fields := [Field], bytes := 16}}}} =
        erx_hid_desc:parse(<<16#05, 16#07, 16#19, 16#e0, 16#29, 16#e7, 16#75, 16#01, 16#95, 16#80, 16#81, 16#02>>),
    ?assertMatch(#{count := 128, size := 1, usages := [{16#700e0, 16#700e7}]}, Field).
