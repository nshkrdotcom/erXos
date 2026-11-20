%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_pcie_cfg, the configuration-space parser and BAR sizing
%% (docs/design-pcie.md, "Host tests of the pure cores"). Snapshots are written field by
%% field with the helpers below, which erx_pcie_cfg_fuzz shares; every offset and bit is
%% written out here, as sys/dev/pci/pcireg.h gives it, so a value changed in
%% abi/formats/pcie.txt fails a case instead of moving with the module.
-module(erx_pcie_cfg_tests).

-include_lib("eunit/include/eunit.hrl").

-export([blank/0, put/4, endpoint/0, root_port/0, bar/3]).

%% 256 bytes of zeros: a function with nothing set.
blank() -> <<0:2048>>.

%% Snapshot with the little-endian Value of Bytes bytes written at Offset.
put(Snapshot, Offset, Bytes, Value) ->
    <<Head:Offset/binary, _:Bytes/binary, Tail/binary>> = Snapshot,
    <<Head/binary, Value:Bytes/little-unit:8, Tail/binary>>.

puts(Snapshot, Fields) ->
    lists:foldl(fun({Offset, Bytes, Value}, S) -> put(S, Offset, Bytes, Value) end,
                Snapshot, Fields).

%% A multifunction network endpoint: a 32-bit memory BAR, an I/O BAR, a 64-bit
%% prefetchable BAR in registers 2 and 3, and MSI-X at 0x40 (its table in BAR 2),
%% 64-bit MSI with per-vector masking at 0x50 and PCI Express with FLR at 0x70.
endpoint() ->
    puts(blank(),
         [{16#00, 2, 16#1af4}, {16#02, 2, 16#1041}, {16#04, 2, 16#0006}, {16#06, 2, 16#0010},
          {16#08, 1, 16#01}, {16#09, 3, 16#020000}, {16#0e, 1, 16#80},
          {16#10, 4, 16#febd1000}, {16#14, 4, 16#0000c041},
          {16#18, 4, 16#fe00000c}, {16#1c, 4, 16#00000001},
          {16#2c, 2, 16#1af4}, {16#2e, 2, 16#1100}, {16#34, 1, 16#40}, {16#3d, 1, 1},
          %% MSI-X: enabled, three entries, table at offset 0x2000 of BAR 2.
          {16#40, 1, 16#11}, {16#41, 1, 16#50}, {16#42, 2, 16#8002}, {16#44, 4, 16#00002002},
          %% MSI: per-vector mask, 64-bit, four vectors capable.
          {16#50, 1, 16#05}, {16#51, 1, 16#70}, {16#52, 2, 16#0184},
          {16#54, 4, 16#fee00000}, {16#58, 4, 0}, {16#5c, 2, 16#4021}, {16#60, 4, 1},
          %% PCI Express: version 2 endpoint, FLR.
          {16#70, 1, 16#10}, {16#71, 1, 0}, {16#72, 2, 16#0002}, {16#74, 4, 16#10008000}]).

%% A root port: a type-1 header with bus numbers and windows and a PCI Express
%% capability of device type 4 at 0x48, reached through a pointer whose low bits are set.
root_port() ->
    puts(blank(),
         [{16#00, 2, 16#14e4}, {16#02, 2, 16#2711}, {16#04, 2, 16#0006}, {16#06, 2, 16#0010},
          {16#08, 1, 16#20}, {16#09, 3, 16#060400}, {16#0e, 1, 16#01},
          {16#18, 1, 0}, {16#19, 1, 1}, {16#1a, 1, 1}, {16#1c, 1, 16#f0}, {16#1d, 1, 16#00},
          {16#20, 2, 16#f800}, {16#22, 2, 16#f810}, {16#24, 2, 16#fff1}, {16#26, 2, 16#0001},
          {16#28, 4, 16#ffffffff}, {16#2c, 4, 0}, {16#34, 1, 16#4b}, {16#3e, 2, 16#0010},
          {16#48, 1, 16#10}, {16#49, 1, 0}, {16#4a, 2, 16#0042}, {16#4c, 4, 0}]).

%% A BAR of the read value, for sizing.
bar(Index, Kind, Wide) ->
    #{index => Index, kind => Kind, addr64 => Wide, prefetchable => false, address => 0}.

refused(Snapshot) ->
    {error, Reason} = erx_pcie_cfg:parse(Snapshot),
    Reason.

parsed(Snapshot) ->
    {ok, Read} = erx_pcie_cfg:parse(Snapshot),
    Read.

an_endpoint_decodes_its_header_and_bars_test() ->
    Read = parsed(endpoint()),
    ?assertMatch(#{vendor := 16#1af4, device_id := 16#1041, command := 16#0006,
                   class_code := 16#020000, revision := 1, header := normal,
                   multifunction := true, subsystem_vendor := 16#1af4,
                   subsystem := 16#1100, pin := 1, bridge := none}, Read),
    ?assertEqual([#{index => 0, kind => memory, addr64 => false, prefetchable => false,
                    address => 16#febd1000},
                  #{index => 1, kind => io, addr64 => false, prefetchable => false,
                    address => 16#c040},
                  #{index => 2, kind => memory, addr64 => true, prefetchable => true,
                    address => 16#1fe000000},
                  #{index => 3, kind => absent, addr64 => false, prefetchable => false,
                    address => 0},
                  #{index => 4, kind => memory, addr64 => false, prefetchable => false,
                    address => 0},
                  #{index => 5, kind => memory, addr64 => false, prefetchable => false,
                    address => 0}],
                 maps:get(bars, Read)).

an_endpoint_decodes_its_capabilities_test() ->
    Read = parsed(endpoint()),
    ?assertEqual(#{offset => 16#40, control => 16#8002, table_size => 3, table_bar => 2, table_offset => 16#2000,
                   enabled => true, function_mask => false},
                 maps:get(msix, Read)),
    ?assertEqual(#{offset => 16#50, control => 16#0184, addr64 => true, vector_mask => true, vectors_log2 => 2,
                   enabled => false, mme => 0, address => 16#fee00000, data => 16#4021,
                   mask => 1},
                 maps:get(msi, Read)),
    ?assertEqual(#{offset => 16#70, type => 0, flr => true}, maps:get(express, Read)).

a_32_bit_msi_reads_its_data_after_the_low_address_test() ->
    S = puts(endpoint(), [{16#52, 2, 16#0001}, {16#58, 2, 16#0031}, {16#5c, 2, 16#ffff}]),
    ?assertEqual(#{offset => 16#50, control => 16#0001, addr64 => false, vector_mask => false, vectors_log2 => 0,
                   enabled => true, mme => 0, address => 16#fee00000, data => 16#0031,
                   mask => none},
                 maps:get(msi, parsed(S))).

a_root_port_decodes_its_bridge_registers_test() ->
    Read = parsed(root_port()),
    ?assertMatch(#{vendor := 16#14e4, device_id := 16#2711, class_code := 16#060400,
                   header := bridge, multifunction := false, subsystem_vendor := 0,
                   subsystem := 0, pin := 0, msi := none, msix := none,
                   express := #{offset := 16#48, type := 4, flr := false}}, Read),
    ?assertEqual(#{primary_bus => 0, secondary_bus => 1, subordinate_bus => 1,
                   io_base => 16#f0, io_limit => 0, memory_base => 16#f800,
                   memory_limit => 16#f810, prefetch_base => 16#fff1,
                   prefetch_limit => 16#0001, prefetch_base_upper => 16#ffffffff,
                   prefetch_limit_upper => 0, io_base_upper => 0, io_limit_upper => 0,
                   bridge_control => 16#0010},
                 maps:get(bridge, Read)),
    ?assertEqual([absent, absent, absent, absent],
                 [K || #{kind := K} <- lists:nthtail(2, maps:get(bars, Read))]).

the_list_is_not_followed_without_the_status_bit_test() ->
    S = puts(endpoint(), [{16#06, 2, 0}, {16#34, 1, 16#08}]),
    ?assertMatch(#{msi := none, msix := none, express := none}, parsed(S)).

a_snapshot_of_another_length_is_refused_test() ->
    ?assertEqual(snapshot, refused(binary:part(endpoint(), 0, 255))),
    ?assertEqual(snapshot, refused(<<(endpoint())/binary, 0>>)).

a_header_type_above_1_is_refused_test() ->
    ?assertEqual(header_type, refused(put(endpoint(), 16#0e, 1, 16#82))).

a_pin_above_intd_is_refused_test() ->
    ?assertEqual(pin, refused(put(endpoint(), 16#3d, 1, 5))).

a_pointer_below_0x40_is_refused_test() ->
    ?assertEqual(capability_pointer, refused(put(endpoint(), 16#34, 1, 16#3c))),
    ?assertEqual(capability_pointer, refused(put(endpoint(), 16#71, 1, 16#3f))).

forty_eight_capabilities_are_read_test() ->
    Chain = [{At, 2, ((At + 4) band 16#ff) bsl 8 bor 16#01} || At <- lists:seq(16#40, 16#fc, 4)],
    S = puts(blank(), [{16#06, 2, 16#0010}, {16#34, 1, 16#40} | Chain]),
    ?assertMatch(#{msi := none, msix := none, express := none}, parsed(S)).

a_looping_list_is_refused_test() ->
    S = puts(blank(), [{16#06, 2, 16#0010}, {16#34, 1, 16#40}, {16#40, 1, 16#01}, {16#41, 1, 16#40}]),
    ?assertEqual(capability_list, refused(S)).

a_capability_past_offset_255_is_refused_test() ->
    Last = fun(Id, Fields) ->
                   puts(blank(), [{16#06, 2, 16#0010}, {16#34, 1, 16#fc}, {16#fc, 1, Id} | Fields])
           end,
    ?assertEqual(msi, refused(Last(16#05, []))),
    ?assertEqual(msix, refused(Last(16#11, []))),
    ?assertEqual(express, refused(Last(16#10, []))),
    %% A 64-bit MSI with per-vector masking at 0xf0 needs 20 bytes; a 32-bit one 10.
    Msi = fun(Control) ->
                  puts(blank(), [{16#06, 2, 16#0010}, {16#34, 1, 16#f0}, {16#f0, 1, 16#05},
                                 {16#f2, 2, Control}])
          end,
    ?assertEqual(msi, refused(Msi(16#0180))),
    %% Its pending bits at +0x14 end the 64-bit layout with masking, though the parser
    %% reads only up to the mask; MSI-X ends with its pending-bit array register at +8,
    %% PCI Express with its device status at +0x0a.
    At = fun(Offset, Id, Control) ->
                 puts(blank(), [{16#06, 2, 16#0010}, {16#34, 1, Offset}, {Offset, 1, Id},
                                {Offset + 2, 2, Control}])
         end,
    ?assertEqual(msi, refused(At(16#ec, 16#05, 16#0180))),
    ?assertMatch(#{msi := #{offset := 16#e8, mask := 0}}, parsed(At(16#e8, 16#05, 16#0180))),
    ?assertEqual(msix, refused(At(16#f8, 16#11, 0))),
    ?assertMatch(#{msix := #{offset := 16#f4, table_bar := 0}}, parsed(At(16#f4, 16#11, 0))),
    ?assertEqual(express, refused(At(16#f8, 16#10, 0))),
    ?assertMatch(#{express := #{offset := 16#f4}}, parsed(At(16#f4, 16#10, 0))),
    ?assertMatch(#{msi := #{offset := 16#f0, mask := none}}, parsed(Msi(16#0100))),
    ?assertMatch(#{msi := #{offset := 16#f0, addr64 := true}}, parsed(Msi(16#0080))).

a_64_bit_bar_in_the_last_register_is_refused_test() ->
    ?assertEqual({bar, 5}, refused(put(endpoint(), 16#24, 4, 16#00000004))),
    ?assertEqual({bar, 1}, refused(put(root_port(), 16#14, 4, 16#0000000c))).

an_msix_table_bar_indicator_above_5_is_refused_test() ->
    ?assertEqual(msix_table_bar, refused(put(endpoint(), 16#44, 4, 16#00002006))),
    ?assertEqual(msix_table_bar, refused(put(endpoint(), 16#44, 4, 16#00002007))).

an_msix_table_in_an_io_upper_half_or_absent_bar_is_refused_test() ->
    ?assertEqual(msix_table_bar, refused(put(endpoint(), 16#44, 4, 16#00002001))),
    ?assertEqual(msix_table_bar, refused(put(endpoint(), 16#44, 4, 16#00002003))),
    Bridge = puts(root_port(), [{16#49, 1, 16#50}, {16#50, 1, 16#11},
                                {16#52, 2, 0}, {16#54, 4, 16#00001002}]),
    ?assertEqual(msix_table_bar, refused(Bridge)).

an_msix_table_past_4_gib_is_refused_test() ->
    Full = fun(Offset) -> puts(endpoint(), [{16#42, 2, 16#07ff}, {16#44, 4, Offset bor 2}]) end,
    ?assertEqual(msix_table_offset, refused(Full(16#ffff8008))),
    ?assertMatch(#{msix := #{table_size := 2048, table_offset := 16#ffff8000}},
                 parsed(Full(16#ffff8000))).

a_second_msi_msix_or_express_is_refused_test() ->
    Again = fun(Id) -> puts(endpoint(), [{16#71, 1, 16#80}, {16#80, 1, Id}, {16#81, 1, 0}]) end,
    ?assertEqual({duplicate, msi}, refused(Again(16#05))),
    ?assertEqual({duplicate, msix}, refused(Again(16#11))),
    ?assertEqual({duplicate, express}, refused(Again(16#10))).

sizing_gives_each_kind_its_hardware_size_test() ->
    ?assertEqual({ok, 12}, erx_pcie_cfg:size(bar(0, memory, false), 16#fffff000)),
    ?assertEqual({ok, 12}, erx_pcie_cfg:size(bar(0, memory, false), 16#fffff008)),
    ?assertEqual({ok, 4}, erx_pcie_cfg:size(bar(0, memory, false), 16#fffffff0)),
    ?assertEqual({ok, 5}, erx_pcie_cfg:size(bar(1, io, false), 16#ffffffe1)),
    ?assertEqual({ok, 16}, erx_pcie_cfg:size(bar(2, memory, true), 16#ffffffffffff000c)),
    ?assertEqual({ok, 31}, erx_pcie_cfg:size(bar(2, memory, true), 16#ffffffff8000000c)).

sizing_refuses_a_noncontiguous_mask_test() ->
    ?assertEqual({error, {bar_mask, 0}}, erx_pcie_cfg:size(bar(0, memory, false), 16#fff0f000)),
    ?assertEqual({error, {bar_mask, 2}}, erx_pcie_cfg:size(bar(2, memory, true), 16#00000000fff0000c)).

%% An I/O BAR is sized from its lowest base bit, as FreeBSD's pci_mapsize sizes
%% it: one decoding 16 address bits reads back zero in its upper half.
an_io_bar_decoding_16_bits_is_sized_from_its_low_16_test() ->
    ?assertEqual({ok, 4}, erx_pcie_cfg:size(bar(1, io, false), 16#0000fff1)),
    ?assertEqual({ok, 8}, erx_pcie_cfg:size(bar(1, io, false), 16#0000ff01)).

%% A 64-bit BAR whose size needs the high word is sized whole, so its report carries
%% the true size; the walk reports it unplaced.
sizing_gives_a_64_bit_bar_that_needs_the_high_word_its_true_size_test() ->
    ?assertEqual({ok, 32}, erx_pcie_cfg:size(bar(2, memory, true), 16#ffffffff0000000c)),
    ?assertEqual({ok, 33}, erx_pcie_cfg:size(bar(4, memory, true), 16#fffffffe00000004)),
    ?assertEqual({ok, 63}, erx_pcie_cfg:size(bar(4, memory, true), 16#8000000000000004)).

an_unimplemented_or_absent_bar_has_no_size_test() ->
    ?assertEqual(absent, erx_pcie_cfg:size(bar(4, memory, false), 16#00000000)),
    ?assertEqual(absent, erx_pcie_cfg:size(bar(4, memory, false), 16#0000000f)),
    ?assertEqual(absent, erx_pcie_cfg:size(bar(3, absent, false), 16#ffffffff)).
