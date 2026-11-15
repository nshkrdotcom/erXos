%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_usb_desc, the USB descriptor decoder (docs/design-usb.md,
%% "Descriptors"). Descriptors are written with the encoders below, which
%% erx_usb_claim_tests and erx_usb_desc_fuzz share; every number is written out here,
%% so a value changed in abi/formats/usb.txt fails a case instead of moving with the
%% module.
%%
%% The fixtures are built from the design's own statements and the chapter 9 layouts
%% abi/formats/usb.txt cites, not captured from devices: a boot keyboard and a tablet,
%% whose HID descriptors name the report descriptors of erx_hid_desc_tests, a Bulk-Only
%% mass storage device and a multi-TT hub.
-module(erx_usb_desc_tests).

-include_lib("eunit/include/eunit.hrl").

-export([device/3, configuration/1, interface/5, endpoint/4, companion/3, hid/1, hub/3,
         string/1, boot_keyboard/0, tablet/0, storage/0, hub_multi_tt/0, ss_interrupt/1]).

%% A device descriptor of 18 bytes: USB 2.0, the class triple, EP0's packet size 64,
%% vendor 1234h, product 5678h, release 0100h, string indexes 1 to 3, one configuration.
device(Class, Subclass, Protocol) ->
    <<18, 1, 16#0200:16/little, Class, Subclass, Protocol, 64, 16#1234:16/little,
      16#5678:16/little, 16#0100:16/little, 1, 2, 3, 1>>.

%% A configuration of value 1, bus-powered at 100 mA, whose wTotalLength covers the
%% header and Descriptors.
configuration(Descriptors) ->
    Body = iolist_to_binary(Descriptors),
    <<9, 2, (9 + byte_size(Body)):16/little, 1, 1, 0, 16#80, 50, Body/binary>>.

interface(Number, Alternate, Class, Subclass, Protocol) ->
    <<9, 4, Number, Alternate, 1, Class, Subclass, Protocol, 0>>.

endpoint(Address, Type, MaxPacket, Interval) ->
    <<7, 5, Address, Type, MaxPacket:16/little, Interval>>.

companion(MaxBurst, Attributes, BytesPerInterval) ->
    <<6, 16#30, MaxBurst, Attributes, BytesPerInterval:16/little>>.

%% A HID 1.11 descriptor naming one report descriptor of Length bytes.
hid(Length) ->
    <<9, 16#21, 16#0111:16/little, 0, 1, 16#22, Length:16/little>>.

%% A hub descriptor with its two bitmaps of one byte each.
hub(Ports, Characteristics, PowerGood) ->
    <<9, 16#29, Ports, Characteristics:16/little, PowerGood, 0, 0, 16#ff>>.

%% A string descriptor around UTF-16LE bytes.
string(Utf16) ->
    <<(2 + byte_size(Utf16)), 3, Utf16/binary>>.

boot_keyboard() ->
    configuration([interface(0, 0, 3, 1, 1), hid(byte_size(erx_hid_desc_tests:boot_keyboard())),
                   endpoint(16#81, 3, 8, 10)]).

tablet() ->
    configuration([interface(0, 0, 3, 0, 0), hid(byte_size(erx_hid_desc_tests:tablet())),
                   endpoint(16#81, 3, 8, 10)]).

storage() ->
    configuration([interface(0, 0, 8, 6, 16#50), endpoint(16#81, 2, 512, 0),
                   endpoint(16#02, 2, 512, 0)]).

%% A multi-TT hub's two settings, each with its status-change endpoint.
hub_multi_tt() ->
    configuration([interface(0, 0, 9, 0, 1), endpoint(16#81, 3, 1, 12),
                   interface(0, 1, 9, 0, 2), endpoint(16#81, 3, 1, 12)]).

%% A SuperSpeed HID interface: an interrupt endpoint of packet size 64 and burst 0,
%% whose companion declares BytesPerInterval.
ss_interrupt(BytesPerInterval) ->
    configuration([interface(0, 0, 3, 0, 0), hid(52), endpoint(16#81, 3, 64, 4),
                   companion(0, 0, BytesPerInterval)]).

settings(Bytes) ->
    {ok, #{settings := Settings}} = erx_usb_desc:configuration(Bytes),
    Settings.

the_device_descriptor_is_exactly_18_bytes_of_type_1_test() ->
    D = device(0, 0, 0),
    ?assertMatch({ok, #{usb := 16#0200, max_packet_size0 := 64, vendor := 16#1234,
                        product := 16#5678, release := 16#0100, manufacturer_index := 1,
                        product_index := 2, serial_index := 3, configurations := 1}},
                 erx_usb_desc:device(D)),
    ?assertEqual({error, malformed_descriptor}, erx_usb_desc:device(<<D/binary, 0>>)),
    ?assertEqual({error, malformed_descriptor}, erx_usb_desc:device(binary:part(D, 0, 8))),
    <<_, Rest/binary>> = D,
    ?assertEqual({error, malformed_descriptor}, erx_usb_desc:device(<<19, Rest/binary>>)),
    <<L, _, Tail/binary>> = D,
    ?assertEqual({error, malformed_descriptor}, erx_usb_desc:device(<<L, 2, Tail/binary>>)).

the_fixtures_decode_to_their_interfaces_and_endpoints_test() ->
    Keyboard = byte_size(erx_hid_desc_tests:boot_keyboard()),
    Tablet = byte_size(erx_hid_desc_tests:tablet()),
    ?assertMatch({ok, #{value := 1, attributes := 16#80, max_power := 50,
                        settings := #{{0, 0} := #{class := 3, subclass := 1, protocol := 1,
                                                  hid := #{report_length := Keyboard},
                                                  endpoints := [#{address := 16#81, type := interrupt,
                                                                  max_packet := 8, interval := 10,
                                                                  companion := none}]}}}},
                 erx_usb_desc:configuration(boot_keyboard())),
    ?assertMatch(#{{0, 0} := #{class := 3, hid := #{report_length := Tablet}}}, settings(tablet())),
    ?assertMatch(#{{0, 0} := #{class := 8, subclass := 6, protocol := 16#50, hid := none,
                               endpoints := [#{address := 16#81, type := bulk, max_packet := 512},
                                             #{address := 16#02, type := bulk, max_packet := 512}]}},
                 settings(storage())),
    ?assertMatch(#{{0, 0} := #{protocol := 1, endpoints := [#{address := 16#81}]},
                   {0, 1} := #{protocol := 2, endpoints := [#{address := 16#81}]}},
                 settings(hub_multi_tt())).

%% The design's seed: bytes past wTotalLength, here an interface the claim would take,
%% are never walked.
the_walk_stops_at_wtotallength_test() ->
    Vendor = configuration([interface(0, 0, 16#ff, 0, 0)]),
    Trailing = iolist_to_binary([interface(1, 0, 3, 1, 1), hid(63), endpoint(16#82, 3, 8, 10)]),
    Bytes = <<Vendor/binary, Trailing/binary>>,
    ?assertEqual([{0, 0}], maps:keys(settings(Bytes))),
    {ok, Device} = erx_usb_desc:device(device(0, 0, 0)),
    {ok, Configuration} = erx_usb_desc:configuration(Bytes),
    ?assertEqual({ok, []}, erx_usb_claim:functions(full, Device, Configuration)).

wtotallength_is_bounded_and_must_be_received_whole_test() ->
    <<Header:2/binary, _:16, Rest/binary>> = Keyboard = boot_keyboard(),
    WithTotal = fun(Total) -> <<Header/binary, Total:16/little, Rest/binary>> end,
    ?assertEqual({error, descriptor_too_long}, erx_usb_desc:configuration(WithTotal(4097))),
    ?assertEqual({error, malformed_descriptor}, erx_usb_desc:configuration(WithTotal(8))),
    ?assertEqual({error, malformed_descriptor},
                 erx_usb_desc:configuration(binary:part(Keyboard, 0, byte_size(Keyboard) - 1))),
    Longest = configuration([<<(255), 16#ff, 0:253/unit:8>> || _ <- lists:seq(1, 16)]
                            ++ [<<(4096 - 9 - 16 * 255), 16#ff, 0:(4096 - 9 - 16 * 255 - 2)/unit:8>>]),
    ?assertEqual(4096, byte_size(Longest)),
    ?assertMatch({ok, #{settings := #{}}}, erx_usb_desc:configuration(Longest)),
    ?assertEqual({error, malformed_descriptor}, erx_usb_desc:configuration(<<9, 2, 9:16/little>>)),
    ?assertEqual({error, malformed_descriptor}, erx_usb_desc:configuration(<<>>)).

each_descriptor_lies_inside_wtotallength_with_its_least_length_test() ->
    Accepts = fun(Ds) -> element(1, erx_usb_desc:configuration(configuration(Ds))) end,
    ?assertEqual(ok, Accepts([<<2, 16#ff>>, interface(0, 0, 3, 0, 0), <<2, 16#24>>,
                              endpoint(16#81, 3, 8, 1)])),
    ?assertEqual(error, Accepts([<<1>>])),
    ?assertEqual(error, Accepts([<<0, 16#ff>>])),
    ?assertEqual(error, Accepts([<<3, 16#ff>>])),
    ?assertEqual(error, Accepts([binary:part(interface(0, 0, 3, 0, 0), 0, 8)])),
    Short = fun(D) -> <<(byte_size(D) - 1), (binary:part(D, 1, byte_size(D) - 2))/binary>> end,
    ?assertEqual(error, Accepts([Short(interface(0, 0, 3, 0, 0))])),
    ?assertEqual(error, Accepts([interface(0, 0, 3, 0, 0), Short(endpoint(16#81, 3, 8, 1))])),
    ?assertEqual(error, Accepts([interface(0, 0, 3, 0, 0), endpoint(16#81, 3, 8, 1),
                                 Short(companion(0, 0, 8))])),
    ?assertEqual(error, Accepts([interface(0, 0, 3, 0, 0), Short(hid(63))])).

an_endpoint_before_any_interface_is_refused_test() ->
    ?assertEqual({error, malformed_descriptor},
                 erx_usb_desc:configuration(configuration([endpoint(16#81, 3, 8, 1),
                                                           interface(0, 0, 3, 0, 0)]))).

a_second_definition_of_an_interface_setting_is_refused_test() ->
    Bytes = configuration([interface(0, 0, 3, 1, 1), endpoint(16#81, 3, 8, 10),
                           interface(0, 0, 16#ff, 0, 0)]),
    ?assertEqual({error, duplicate_interface}, erx_usb_desc:configuration(Bytes)),
    ?assertMatch(#{{0, 0} := _, {0, 1} := _, {1, 0} := _},
                 settings(configuration([interface(0, 0, 3, 0, 0), interface(0, 1, 3, 0, 0),
                                         interface(1, 0, 3, 0, 0)]))).

an_endpoint_numbered_0_is_refused_test() ->
    [?assertEqual({error, endpoint_zero},
                  erx_usb_desc:configuration(configuration([interface(0, 0, 3, 0, 0),
                                                            endpoint(Address, 3, 8, 1)])))
     || Address <- [16#00, 16#80, 16#10, 16#f0]].

an_address_keeps_its_direction_and_number_alone_test() ->
    ?assertMatch(#{{0, 0} := #{endpoints := [#{address := 16#81}, #{address := 16#02}]}},
                 settings(configuration([interface(0, 0, 3, 0, 0), endpoint(16#f1, 3, 8, 1),
                                         endpoint(16#72, 2, 64, 0)]))).

a_companion_belongs_to_the_endpoint_just_before_it_test() ->
    ?assertMatch(#{{0, 0} := #{endpoints := [#{companion := #{max_burst := 0, attributes := 0,
                                                                bytes_per_interval := 8}}]}},
                 settings(ss_interrupt(8))),
    ?assertMatch(#{{0, 0} := #{endpoints := [#{companion := none}, #{companion := #{max_burst := 3}}]}},
                 settings(configuration([interface(0, 0, 8, 6, 16#50), endpoint(16#81, 2, 1024, 0),
                                         endpoint(16#02, 2, 1024, 0), companion(3, 0, 0)]))),
    Refused = fun(Ds) -> erx_usb_desc:configuration(configuration(Ds)) end,
    ?assertEqual({error, malformed_descriptor}, Refused([interface(0, 0, 3, 0, 0), companion(0, 0, 8)])),
    ?assertEqual({error, malformed_descriptor},
                 Refused([interface(0, 0, 3, 0, 0), endpoint(16#81, 3, 64, 4), companion(0, 0, 8),
                          companion(0, 0, 8)])),
    ?assertEqual({error, malformed_descriptor},
                 Refused([interface(0, 0, 3, 0, 0), endpoint(16#81, 3, 64, 4), <<2, 16#ff>>,
                          companion(0, 0, 8)])).

a_hid_descriptor_names_its_report_descriptor_once_a_setting_test() ->
    Refused = fun(Ds) -> erx_usb_desc:configuration(configuration(Ds)) end,
    ?assertMatch({ok, #{settings := #{{0, 0} := #{hid := none}}}}, Refused([hid(63), interface(0, 0, 3, 0, 0)])),
    ?assertEqual({error, malformed_descriptor}, Refused([interface(0, 0, 3, 0, 0), hid(63), hid(63)])),
    <<Head:6/binary, _, Tail/binary>> = hid(63),
    ?assertEqual({error, malformed_descriptor},
                 Refused([interface(0, 0, 3, 0, 0), <<Head/binary, 16#23, Tail/binary>>])),
    ?assertMatch(#{{0, 0} := #{hid := #{report_length := 63}}, {1, 0} := #{hid := #{report_length := 4096}}},
                 settings(configuration([interface(0, 0, 3, 0, 0), hid(63), interface(1, 0, 3, 0, 0),
                                         hid(4096)]))).

%% Type 21h under a class other than HID is that class's own: a DFU functional
%% descriptor and a CCID class descriptor are skipped, and the HID interface beside
%% them is still claimed.
type_21h_is_hid_only_under_a_hid_interface_test() ->
    Dfu = <<9, 16#21, 16#0b, 16#ff, 0, 16#00, 16#04, 16#10, 16#01>>,
    Ccid = <<54, 16#21, 16#10, 16#01, 0:(50 * 8)>>,
    Bytes = configuration([interface(0, 0, 3, 1, 1), hid(63), endpoint(16#81, 3, 8, 10),
                           interface(1, 0, 16#0b, 0, 0), Ccid, endpoint(16#02, 2, 64, 0),
                           interface(2, 0, 16#fe, 1, 2), Dfu]),
    ?assertMatch(#{{1, 0} := #{hid := none}, {2, 0} := #{hid := none}}, settings(Bytes)),
    {ok, Device} = erx_usb_desc:device(device(0, 0, 0)),
    {ok, Configuration} = erx_usb_desc:configuration(Bytes),
    ?assertMatch({ok, [#{driver := erx_usb_hid, interface := 0}]},
                 erx_usb_claim:functions(full, Device, Configuration)).

a_hub_descriptor_names_1_to_15_ports_test() ->
    ?assertEqual({ok, #{ports => 4, think_time => 2, power_good => 50}},
                 erx_usb_desc:hub(hub(4, 16#0040, 50))),
    ?assertMatch({ok, #{ports := 15}}, erx_usb_desc:hub(hub(15, 0, 0))),
    ?assertEqual({error, too_many_ports}, erx_usb_desc:hub(hub(16, 0, 0))),
    ?assertEqual({error, malformed_descriptor}, erx_usb_desc:hub(hub(0, 0, 0))),
    ?assertMatch({ok, #{ports := 1}}, erx_usb_desc:hub(<<7, 16#29, 1, 0:16, 10, 0>>)),
    ?assertEqual({error, malformed_descriptor}, erx_usb_desc:hub(<<6, 16#29, 1, 0:16, 10>>)),
    ?assertMatch({ok, #{ports := 10}}, erx_usb_desc:hub(<<11, 16#29, 10, 0:16, 10, 0, 0, 0, 16#ff>>)),
    ?assertEqual({error, malformed_descriptor}, erx_usb_desc:hub(<<7, 16#28, 1, 0:16, 10, 0>>)).

a_string_is_decoded_to_utf8_test() ->
    Utf16 = fun(Text) -> unicode:characters_to_binary(Text, utf8, {utf16, little}) end,
    ?assertEqual({ok, <<"Keyboard">>}, erx_usb_desc:string(string(Utf16(<<"Keyboard">>)))),
    ?assertEqual({ok, <<"x", 240, 159, 152, 128>>}, erx_usb_desc:string(string(<<$x, 0, 16#3d, 16#d8, 16#00, 16#de>>))),
    ?assertEqual({ok, <<239, 191, 189, $a, 239, 191, 189>>},
                 erx_usb_desc:string(string(<<16#00, 16#de, $a, 0, 16#3d, 16#d8>>))),
    ?assertEqual({ok, <<"ab">>}, erx_usb_desc:string(<<7, 3, $a, 0, $b, 0, $c, 0>>)),
    ?assertEqual({ok, <<>>}, erx_usb_desc:string(<<2, 3>>)),
    ?assertEqual({error, malformed_descriptor}, erx_usb_desc:string(<<6, 3, $a, 0>>)),
    ?assertEqual({error, malformed_descriptor}, erx_usb_desc:string(<<1, 3>>)),
    ?assertEqual({error, malformed_descriptor}, erx_usb_desc:string(<<4, 2, $a, 0>>)).

the_language_table_prefers_english_test() ->
    ?assertEqual({ok, [16#0407, 16#0809, 16#0409]},
                 erx_usb_desc:languages(string(<<16#0407:16/little, 16#0809:16/little, 16#0409:16/little>>))),
    ?assertEqual(16#0809, erx_usb_desc:language([16#0407, 16#0809, 16#0409])),
    ?assertEqual(16#0407, erx_usb_desc:language([16#0407, 16#040c])),
    ?assertEqual(none, erx_usb_desc:language([])),
    ?assertEqual({ok, []}, erx_usb_desc:languages(<<2, 3>>)).
