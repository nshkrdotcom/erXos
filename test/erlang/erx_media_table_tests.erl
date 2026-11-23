%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Host tests of erx_media_table (docs/design-drives.md, "Host tests"), over the
%% media erx_media_table_cases writes. test/host/erx_media_table_test.rb runs them
%% against the reader as it is and against each seeded fault it lists.

-module(erx_media_table_tests).
-include_lib("eunit/include/eunit.hrl").

-import(erx_media_table_cases, [read/2, mbr/1, mbr_sector/2, fat_boot/1, gpt/3]).

-define(C, 4096).

%% Each volume as {number, first, length, serve}.
spans({Scheme, Volumes}) when is_list(Volumes) ->
    {Scheme, [{N, F, L, S} || #{number := N, first := F, length := L, serve := S} <- Volumes]};
spans(Answer) ->
    Answer.

table(Capacity, Image) -> spans(read(Capacity, Image)).

%% MBR.

an_mbr_with_one_entry_test() ->
    ?assertEqual({mbr, [{1, 2048, 1000, yes}]}, table(?C, mbr([{16#80, 16#0c, 2048, 1000}]))),
    ?assertMatch({mbr, [#{type := 16#0c}]}, read(?C, mbr([{16#80, 16#0c, 2048, 1000}]))).

an_mbr_with_four_entries_test() ->
    ?assertEqual({mbr, [{1, 63, 100, yes}, {2, 200, 100, yes}, {3, 300, 3000, yes}, {4, 3300, 796, yes}]},
                 table(?C, mbr([{0, 16#83, 63, 100}, {0, 16#0b, 200, 100}, {0, 16#0c, 300, 3000},
                                {0, 16#07, 3300, 796}]))).

a_fat_boot_sector_with_no_entries_is_no_table_test() ->
    ?assertEqual({none, [{1, 0, ?C, yes}]}, table(?C, fat_boot([]))).

a_boot_sector_whose_status_bytes_are_code_is_no_table_test() ->
    Code = binary:copy(<<16#33, 16#c0, 16#8e, 16#d0>>, 16),
    Sector = <<0:(446 * 8), Code/binary, 16#55, 16#aa>>,
    ?assertEqual({none, [{1, 0, ?C, yes}]}, table(?C, #{0 => Sector})).

an_unsigned_sector_is_no_table_test() ->
    ?assertEqual({none, [{1, 0, ?C, yes}]}, table(?C, #{})).

empty_and_zero_entries_are_skipped_test() ->
    ?assertEqual({mbr, [{4, 200, 10, yes}]},
                 table(?C, mbr([{0, 0, 100, 10}, {0, 16#83, 0, 10}, {0, 16#83, 100, 0}, {0, 16#83, 200, 10}]))).

an_extended_entry_is_listed_and_not_served_test() ->
    ?assertEqual({mbr, [{1, 63, 100, yes}, {2, 200, 100, extended}, {3, 300, 10, extended},
                        {4, 400, 10, extended}]},
                 table(?C, mbr([{0, 16#0c, 63, 100}, {0, 16#05, 200, 100}, {0, 16#0f, 300, 10},
                                {0, 16#85, 400, 10}]))).

an_entry_past_the_end_refuses_the_table_test() ->
    ?assertEqual({refused, {past_the_end, [2]}}, table(?C, mbr([{0, 16#83, 63, 100}, {0, 16#83, 4000, 97}]))),
    ?assertMatch({mbr, _}, table(?C, mbr([{0, 16#83, 63, 100}, {0, 16#83, 4000, 96}]))).

an_extended_entry_is_checked_too_test() ->
    ?assertEqual({refused, {overlap, [1, 2]}}, table(?C, mbr([{0, 16#83, 63, 100}, {0, 16#05, 100, 100}]))).

overlapping_entries_refuse_the_table_in_either_order_test() ->
    ?assertEqual({refused, {overlap, [1, 2]}}, table(?C, mbr([{0, 16#83, 100, 100}, {0, 16#83, 150, 100}]))),
    ?assertEqual({refused, {overlap, [1, 2]}}, table(?C, mbr([{0, 16#83, 150, 100}, {0, 16#83, 100, 100}]))).

%% GPT.

a_gpt_behind_its_protective_entry_test() ->
    Answer = read(?C, gpt(?C, [{100, 199}, {200, 4062}], #{})),
    ?assertEqual({gpt, [{1, 100, 100, yes}, {2, 200, 3863, yes}]}, spans(Answer)),
    {gpt, [#{name := Name, guid := Guid} | _]} = Answer,
    ?assertEqual(<<"v", 0, "o", 0, "l", 0, "1", 0, 0:(64 * 8)>>, Name),
    ?assertEqual(<<1:128>>, Guid).

backup(Primary) ->
    table(?C, gpt(?C, [{100, 199}], #{primary => Primary, backup_entries => [{300, 399}]})).

a_primary_header_without_its_signature_is_read_from_the_backup_test() ->
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{signature => <<"EFI PARX">>})).

a_primary_header_whose_crc_fails_is_read_from_the_backup_test() ->
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{crc => bad})),
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{revision => 16#0000ffff})),
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{size => 91})),
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{self => 2})).

a_primary_usable_area_out_of_bounds_is_read_from_the_backup_test() ->
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{last => ?C + 10})),
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{last => ?C - 1})),
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{first => 1})),
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{first => 500, last => 400})).

a_primary_array_out_of_bounds_is_read_from_the_backup_test() ->
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{entries => 0})),
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{entry_size => 100})),
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{entry_size => 132})),
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{table => ?C - 10})),
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, backup(#{alternate => ?C})).

an_array_of_17_kib_is_refused_test() ->
    ?assertEqual({gpt, [{1, 300, 100, yes}]},
                 table(?C, gpt(?C, [{100, 199}], #{primary_array_entries => 136, usable => {40, ?C - 40},
                                                    backup_entries => [{300, 399}]}))).

a_failing_primary_array_is_read_from_the_backup_at_the_alternate_test() ->
    Image = gpt(?C, [{100, 199}], #{backup_lba => 4000, usable => {34, 3900}, primary => #{array_crc => 0},
                                     backup_entries => [{300, 399}]}),
    ?assertEqual({gpt, [{1, 300, 100, yes}]}, table(?C, Image)).

both_copies_failing_refuse_the_table_test() ->
    ?assertEqual({refused, {gpt_header, primary}},
                 table(?C, gpt(?C, [{100, 199}], #{primary => #{crc => bad}, backup => #{crc => bad}}))),
    ?assertEqual({refused, {gpt_array, primary}},
                 table(?C, gpt(?C, [{100, 199}], #{primary => #{array_crc => 0}, backup => #{array_crc => 0}}))).

a_protective_entry_over_a_fat_boot_sector_is_never_mounted_whole_test() ->
    ?assertEqual({refused, {gpt_header, primary}}, table(?C, fat_boot([{16#12, 16#ee, 1, ?C - 1}]))).

nine_used_entries_serve_eight_test() ->
    Entries = [{100 + 10 * I, 109 + 10 * I} || I <- lists:seq(0, 8)],
    {gpt, Spans} = table(?C, gpt(?C, Entries, #{})),
    ?assertEqual([yes, yes, yes, yes, yes, yes, yes, yes, over_bound], [S || {_, _, _, S} <- Spans]).

an_entry_running_backwards_refuses_the_table_test() ->
    ?assertEqual({refused, {backwards, [2]}}, table(?C, gpt(?C, [{100, 199}, {300, 250}], #{}))).

an_entry_outside_the_usable_area_refuses_the_table_test() ->
    ?assertEqual({refused, {before_the_first_usable_sector, [1]}}, table(?C, gpt(?C, [{33, 199}], #{}))),
    ?assertEqual({refused, {past_the_end, [1]}}, table(?C, gpt(?C, [{100, 4063}], #{}))).

a_usable_area_that_meets_a_header_is_refused_test() ->
    ?assertEqual({refused, {gpt_metadata, primary}}, table(?C, gpt(?C, [{100, 199}], #{backup_lba => 2000}))).

%% g_part_gpt.c:513-524: a header whose array starts below sector 2, ends on the
%% medium's last sector, or has an end inside the usable area fails, and the backup
%% is read.
an_array_out_of_its_place_fails_its_header_test() ->
    Sector0 = mbr_sector(<<0:(446 * 8)>>, [{0, 16#ee, 1, ?C - 1}]),
    AtSector0 = #{table => 0, entries => 4, array_crc => erlang:crc32(Sector0)},
    ?assertEqual({gpt, [{1, 300, 100, yes}]},
                 table(?C, gpt(?C, [{100, 199}], #{sector0 => Sector0, primary => AtSector0,
                                                    backup_entries => [{300, 399}]}))),
    %% An array on the last sector leaves no room for the backup header read there.
    ?assertEqual({refused, {gpt_header, primary}},
                 table(?C, gpt(?C, [{100, 199}], #{backup_lba => 4000, usable => {34, 3900}, primary_table => ?C - 32,
                                                    backup_entries => [{300, 399}]}))),
    ?assertEqual({gpt, [{1, 300, 100, yes}]},
                 table(?C, gpt(?C, [{200, 299}], #{primary_table => 100, backup_entries => [{300, 399}]}))),
    ?assertEqual({gpt, [{1, 300, 100, yes}]},
                 table(?C, gpt(?C, [{100, 199}], #{primary_table => 20, backup_entries => [{300, 399}]}))).

both_arrays_in_their_usable_area_refuse_the_table_test() ->
    ?assertEqual({refused, {gpt_header, primary}},
                 table(?C, gpt(?C, [{200, 299}], #{primary_table => 100, backup_table => 3000}))).

a_usable_area_that_meets_the_other_array_is_refused_test() ->
    ?assertEqual({refused, {gpt_metadata, primary}},
                 table(?C, gpt(?C, [{100, 199}], #{usable => {34, 4070}, backup => #{last => 4000}}))).

an_array_that_encloses_the_usable_area_is_refused_test() ->
    ?assertEqual({refused, {gpt_metadata, primary}}, table(?C, gpt(?C, [{12, 18}], #{usable => {10, 20}}))).

%% place/3.

place_keeps_a_request_inside_its_volume_test() ->
    Volume = #{number => 1, first => 100, length => 10, type => 16#83, serve => yes},
    ?assertEqual({ok, 100}, erx_media_table:place(Volume, 0, 10)),
    ?assertEqual({ok, 109}, erx_media_table:place(Volume, 9, 1)),
    ?assertEqual({error, erange}, erx_media_table:place(Volume, 9, 2)),
    ?assertEqual({error, erange}, erx_media_table:place(Volume, 10, 1)),
    ?assertEqual({error, erange}, erx_media_table:place(Volume, -1, 1)),
    ?assertEqual({error, erange}, erx_media_table:place(Volume, 0, 0)).

%% The property: for every table the generator writes, the served volumes are the
%% ones written when every entry is good, the table is refused when one entry ends a
%% sector past its limit, and either way every served volume lies inside the medium,
%% apart from the others and from the metadata, and place/3 stays inside it.

every_written_table_reads_back_inside_the_medium_test() ->
    rand:seed(exsss, {20, 26, 11}),
    [property(Scheme, Edge) || Scheme <- [mbr, gpt], Edge <- [false, true], _ <- lists:seq(1, 300)].

property(Scheme, Edge) ->
    Capacity = 200 + rand:uniform(100000),
    {Low, High, Metadata, Count} =
        case Scheme of
            mbr -> {1, Capacity - 1, [{0, 0}], 4};
            gpt -> {34, Capacity - 34, [{0, 33}, {Capacity - 33, Capacity - 1}], 12}
        end,
    Spans = spans_between(Low, High, rand:uniform(Count)),
    Written = case Edge of
                  true -> lists:droplast(Spans) ++ [{element(1, lists:last(Spans)), High + 1}];
                  false -> Spans
              end,
    Answer = read(Capacity, image(Scheme, Capacity, Written)),
    case Edge of
        true -> ?assertMatch({refused, {past_the_end, _}}, Answer);
        false -> ?assertEqual({Scheme, [{F, L - F + 1} || {F, L} <- Spans]},
                              {element(1, Answer), [{F, N} || #{first := F, length := N} <- element(2, Answer)]})
    end,
    inside(Answer, Capacity, Metadata).

image(mbr, _Capacity, Spans) -> mbr([{0, 16#83, F, L - F + 1} || {F, L} <- Spans]);
image(gpt, Capacity, Spans) -> gpt(Capacity, Spans, #{}).

%% Count disjoint spans between Low and High in order, the last ending at High.
spans_between(Low, High, Count) ->
    Cuts = lists:usort([Low + rand:uniform(High - Low) - 1 || _ <- lists:seq(1, 2 * Count - 1)]),
    Bounds = [Low | Cuts] ++ [High + 1],
    pairs(lists:usort(Bounds)).

pairs([A, B | Rest]) when B > A -> [{A, B - 1} | pairs(Rest)];
pairs(_) -> [].

inside({refused, _}, _Capacity, _Metadata) ->
    ok;
inside({_Scheme, Volumes}, Capacity, Metadata) ->
    Served = [{F, F + L - 1, V} || V = #{first := F, length := L, serve := yes} <- Volumes],
    [begin
         ?assert(F >= 0 andalso L < Capacity),
         [?assertNot(F =< B andalso A =< L) || {A, B} <- Metadata],
         Offset = rand:uniform(L - F + 3) - 2,
         case erx_media_table:place(V, Offset, 1) of
             {ok, Sector} -> ?assert(Sector >= F andalso Sector =< L);
             {error, erange} -> ?assert(Offset < 0 orelse Offset > L - F)
         end
     end || {F, L, V} <- Served],
    [?assertNot(F1 =< L2 andalso F2 =< L1) || {F1, L1, V1} <- Served, {F2, L2, V2} <- Served, V1 =/= V2],
    ok.
