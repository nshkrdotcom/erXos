%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_mount_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(BLOCK, 4096).
-define(SEGMENT, 512).
%% The fixture volume's blocks and its two packs' addresses.
-define(PARTITION, 16384).
-define(PACK1, 512).
-define(PACK2, 1024).
%% A 64-bit version just below its wrap.
-define(LAST_VERSION, 16#ffffffffffffffff).

%%% Fixtures: erx_f2fs_codec_tests' volume of 16384 blocks, its pack 1 of 8
%%% blocks with no payload at block 512, and pack 2 at block 1024 zeros
%%% unless a case writes one.

super() -> erx_f2fs_codec_tests:superblock_fields().

header() -> erx_f2fs_codec_tests:checkpoint_fields().

%% The SIT and NAT version bitmaps the fixture header holds, 64 bytes each.
bitmaps() -> binary:copy(<<16#a5>>, 128).

%% A pack at Start: its header and, at its last block, its copy.
pack(Start, Fields) -> pack(Start, Fields, Fields).

pack(Start, #{cp_pack_total_block_count := Total} = Fields, CopyFields) ->
    #{Start => erx_f2fs_codec_tests:checkpoint_block(Fields, bitmaps()),
      Start + Total - 1 => erx_f2fs_codec_tests:checkpoint_block(CopyFields, bitmaps())}.

volume(Super, Packs) ->
    Block = erx_f2fs_codec_tests:superblock_block(Super),
    maps:merge(#{0 => Block, 1 => Block}, Packs).

volume(Super) -> volume(Super, pack(?PACK1, header())).

%% Mounts from Blocks as the volume process does: each {need, Addresses}
%% is answered with those blocks, a zero block for any Blocks lacks, and the
%% mount runs again from the start. A mount that asks for a block it was
%% given, or asks more than eight times, fails the case.
mount(Partition, Blocks) -> mount(Partition, Blocks, #{}, 8).

mount(Partition, Blocks, Given, Rounds) ->
    case erx_f2fs_mount:mount(Partition, Given) of
        {need, Addresses} when Rounds > 0, Addresses =/= [] ->
            ?assertEqual([], [A || A <- Addresses, is_map_key(A, Given) orelse A >= Partition]),
            Read = maps:from_list([{A, maps:get(A, Blocks, <<0:(?BLOCK * 8)>>)} || A <- Addresses]),
            mount(Partition, Blocks, maps:merge(Given, Read), Rounds - 1);
        Answer ->
            Answer
    end.

mount(Blocks) -> mount(?PARTITION, Blocks).

mode(Blocks) ->
    {ok, #{mode := Mode}} = mount(Blocks),
    Mode.

failure(Blocks) ->
    {error, Failure} = mount(Blocks),
    Failure.

%%% The fixed corpora (docs/design-f2fs.md, "Corpora")

%% What each corpus image's mount answers, from its mkfs options
%% (erx_f2fs_corpus_tests) and the rules of docs/design-f2fs.md, "Scope:
%% features and forms": syzkaller's seeds without features or with
%% extra_attr alone mount read-write, those with the R features read-only,
%% the -s 2 seeds read-only naming their two segments per section, and
%% those with encrypt, fscrypt_f2fs and Fuchsia's image are refused naming
%% the bits.
expected("f2fs-fuchsia") ->
    {error, {superblock, {features, [encrypt, verity]}}};
expected("f2fs-syzkaller-fscrypt") ->
    {error, {superblock, {features, [encrypt]}}};
expected("f2fs-syzkaller-" ++ N) ->
    Seed = list_to_integer(N),
    Sections = [{segs_per_sec, 2} || (Seed div 4) rem 2 =:= 1],
    case Seed rem 4 of
        1 -> {error, {superblock, {features, [encrypt]}}};
        3 -> {ok, {read_only, [{features, [prjquota, flexible_inline_xattr, inode_crtime]}
                              | Sections]}};
        _ when Sections =:= [] -> {ok, read_write};
        _ -> {ok, {read_only, Sections}}
    end.

corpus_image(Pin) ->
    {ok, Image} = erx_f2fs_corpus:image(Pin, erx_f2fs_corpus:fetched(os:getenv("ERX_F2FS_CORPUS"), Pin)),
    Image.

image_blocks(Image) ->
    fun(Addresses) -> maps:from_list([{A, binary:part(Image, A * ?BLOCK, ?BLOCK)} || A <- Addresses]) end.

%% Mounts Image through the need loop, reading each block it asks for.
mount_image(Image) -> mount_image(Image, #{}, 8).

mount_image(Image, Given, Rounds) ->
    Partition = byte_size(Image) div ?BLOCK,
    case erx_f2fs_mount:mount(Partition, Given) of
        {need, Addresses} when Rounds > 0 ->
            ?assertEqual([], [A || A <- Addresses, is_map_key(A, Given) orelse A >= Partition]),
            mount_image(Image, maps:merge(Given, (image_blocks(Image))(Addresses)), Rounds - 1);
        {ok, #{mode := Mode}} -> {ok, Mode};
        Answer -> Answer
    end.

every_corpus_image_mounts_as_its_features_and_geometry_say_test_() ->
    {timeout, 600,
     fun() ->
             Pins = erx_f2fs_corpus:pins(os:getenv("ERX_DEPS_LOCK")),
             ?assertEqual(18, length(Pins)),
             Wrong = [{Id, Got, Want}
                      || #{id := Id} = Pin <- Pins,
                         Got <- [mount_image(corpus_image(Pin))],
                         Want <- [expected(Id)], Got =/= Want],
             ?assertEqual([], Wrong)
     end}.

%% Fuchsia's image with ENCRYPT and VERITY cleared in both copies (it has
%% no SB_CHKSUM, so no checksum to fix) has no feature outside W, and its
%% geometry asks for nothing read-only.
fuchsia_without_encrypt_and_verity_mounts_test_() ->
    {timeout, 600,
     fun() ->
             [Pin] = [Pin || #{id := "f2fs-fuchsia"} = Pin <- erx_f2fs_corpus:pins(os:getenv("ERX_DEPS_LOCK"))],
             Image = corpus_image(Pin),
             Cleared = lists:foldl(fun clear_features/2, Image, [0, 1]),
             ?assertEqual({ok, read_write}, mount_image(Cleared))
     end}.

clear_features(Copy, Image) ->
    At = Copy * ?BLOCK + ?ERX_F2FS_SUPER_OFFSET + ?ERX_F2FS_SUPER_BLOCK_OFF_FEATURE,
    <<Before:At/binary, Feature:32/little, After/binary>> = Image,
    ?assertEqual(0, Feature band ?ERX_F2FS_FEATURE_SB_CHKSUM),
    Clear = Feature band bnot (?ERX_F2FS_FEATURE_ENCRYPT bor ?ERX_F2FS_FEATURE_VERITY),
    <<Before/binary, Clear:32/little, After/binary>>.

%%% The need protocol

a_mount_asks_for_the_superblock_copies_first_test() ->
    ?assertEqual({need, [0, 1]}, erx_f2fs_mount:mount(?PARTITION, #{})).

the_fixture_mounts_read_write_from_pack_1_test() ->
    {ok, #{superblock := #{block_count := 16384}, pack := ?PACK1, bad_copies := [],
           checkpoint := #{checkpoint_ver := 1, sit_version_bitmap := Sit,
                           nat_version_bitmap := Nat},
           mode := read_write}} = mount(volume(super())),
    ?assertEqual(bitmaps(), <<Sit/binary, Nat/binary>>).

%% With one payload block the header holds the NAT bitmap and the payload
%% block after it the SIT bitmap ([F 20], [F 23]).
payload_volume(StartSum) ->
    Sit = binary:copy(<<16#3c>>, 64),
    Nat = binary:copy(<<16#c3>>, 64),
    Header = (header())#{cp_pack_total_block_count := 9, cp_pack_start_sum := StartSum},
    Block = erx_f2fs_codec_tests:checkpoint_block(Header, Nat),
    Payload = <<Sit/binary, 0:((?BLOCK - 64) * 8)>>,
    {volume((super())#{cp_payload := 1}, #{?PACK1 => Block, ?PACK1 + 1 => Payload, ?PACK1 + 8 => Block}),
     Sit, Nat}.

a_pack_with_a_payload_block_reads_its_sit_bitmap_there_test() ->
    {Blocks, Sit, Nat} = payload_volume(2),
    {ok, #{checkpoint := #{sit_version_bitmap := GotSit, nat_version_bitmap := GotNat}}} = mount(Blocks),
    ?assertEqual({Sit, Nat}, {GotSit, GotNat}).

summaries_starting_in_the_payload_fail_test() ->
    {Blocks, _Sit, _Nat} = payload_volume(1),
    ?assertEqual({error, {checkpoint, start_sum}}, mount(Blocks)).

%%% The superblock copy (docs/design-f2fs.md, "Mount", step 1)

a_bad_first_copy_leaves_the_second_test() ->
    Blocks = volume(super()),
    Bad = erx_f2fs_codec_tests:superblock_block((super())#{magic := 0}),
    {error, Rule} = erx_f2fs_codec:superblock(Bad),
    {ok, #{bad_copies := BadCopies, mode := read_write}} = mount(Blocks#{0 := Bad}),
    ?assertEqual([{0, Rule}], BadCopies).

both_bad_copies_fail_with_the_first_ones_rule_test() ->
    Blocks = volume((super())#{feature := ?ERX_F2FS_FEATURE_ENCRYPT}),
    Bad = erx_f2fs_codec_tests:superblock_block((super())#{magic := 0}),
    ?assertEqual({superblock, {features, [encrypt]}}, failure(Blocks#{1 := Bad})).

a_partition_without_both_copies_fails_before_any_read_test() ->
    ?assertEqual({error, {superblock, partition}}, erx_f2fs_mount:mount(1, #{})).

%% The fixture's areas moved a segment on, so its main area ends a segment
%% past block_count and the partition, under a valid segment_count.
main_area_past_the_partition() ->
    (super())#{segment0_blkaddr := 1024, cp_blkaddr := 1024, sit_blkaddr := 2048,
               nat_blkaddr := 3072, ssa_blkaddr := 4096, main_blkaddr := 4608}.

%% The fixture's areas moved a segment back, so pack 1 would start at block 0.
checkpoint_area_over_the_superblock() ->
    (super())#{segment0_blkaddr := 0, cp_blkaddr := 0, sit_blkaddr := 1024,
               nat_blkaddr := 2048, ssa_blkaddr := 3072, main_blkaddr := 3584,
               block_count := 15872}.

%% The fixture's checkpoint area cut to one segment and its SIT area grown
%% by one, so pack 2 would lie in the SIT.
checkpoint_area_of_one_segment() ->
    (super())#{segment_count_ckpt := 1, segment_count_sit := 3, sit_blkaddr := 1024}.

%% Device 0 named, its segments the volume's, so the codec's sum holds.
device_list() ->
    Super = super(),
    Named = #{path => <<"/dev/a", 0:(58 * 8)>>, total_segments => maps:get(segment_count, Super)},
    Super#{devs := [Named | tl(maps:get(devs, Super))]}.

superblock_cases() ->
    Super = super(),
    Feature = maps:get(feature, Super),
    [{partition, mount(?PARTITION - 1, volume(Super))},
     {partition, mount(volume(main_area_past_the_partition()))},
     {{features, [encrypt, verity]},
      mount(volume(Super#{feature := Feature bor ?ERX_F2FS_FEATURE_ENCRYPT bor
                                         ?ERX_F2FS_FEATURE_VERITY}))},
     {{features, [16#20000]}, mount(volume(Super#{feature := Feature bor 16#20000}))},
     {{needs_extra_attr, [inode_chksum]},
      mount(volume(Super#{feature := Feature band bnot ?ERX_F2FS_FEATURE_EXTRA_ATTR}))},
     {device_list, mount(volume(device_list()))},
     {checkpoint_area, mount(volume(checkpoint_area_of_one_segment()))},
     {checkpoint_area, mount(volume(checkpoint_area_over_the_superblock()))}].

each_superblock_rule_fails_with_its_name_test_() ->
    [{lists:flatten(io_lib:format("~p", [Rule])), ?_assertEqual({error, {superblock, Rule}}, Got)}
     || {Rule, Got} <- superblock_cases()].

%%% The mount's mode (docs/design-f2fs.md, "Scope: features and forms")

read_only_reasons_test_() ->
    Super = super(),
    Feature = maps:get(feature, Super),
    Small = Super#{block_count := 12288, segment_count := 23, section_count := 16,
                   segment_count_main := 16},
    [{"an R feature", ?_assertEqual({read_only, [{features, [inode_crtime]}]},
                                    mode(volume(Super#{feature := Feature bor
                                                           ?ERX_F2FS_FEATURE_INODE_CRTIME})))},
     {"two segments per section", ?_assertEqual({read_only, [{segs_per_sec, 2}]},
                                                mode(volume(Super#{segs_per_sec := 2,
                                                                   section_count := 12})))},
     {"a main area of 16 segments",
      ?_assertEqual({read_only, [{segment_count_main, 16}]},
                    mode(volume(Small, pack(?PACK1, (header())#{user_block_count := 4096}))))},
     {"FSCK and QUOTA_NEED_FSCK mount as they are",
      ?_assertEqual(read_write,
                    mode(volume(Super, pack(?PACK1, flags(?ERX_F2FS_CP_FSCK bor
                                                              ?ERX_F2FS_CP_QUOTA_NEED_FSCK)))))}].

flags(Flags) ->
    Header = header(),
    Header#{ckpt_flags := maps:get(ckpt_flags, Header) bor Flags}.

%%% The checkpoint pack (docs/design-f2fs.md, "Mount", step 2)

versions(V1, V2) ->
    Packs = maps:merge(pack(?PACK1, (header())#{checkpoint_ver := V1}),
                       pack(?PACK2, (header())#{checkpoint_ver := V2})),
    {ok, #{pack := Pack, checkpoint := #{checkpoint_ver := Version}}} = mount(volume(super(), Packs)),
    {Pack, Version}.

the_later_pack_wins_under_wrap_around_test_() ->
    [?_assertEqual({?PACK2, 2}, versions(1, 2)),
     ?_assertEqual({?PACK1, 2}, versions(2, 1)),
     ?_assertEqual({?PACK1, 3}, versions(3, 3)),
     ?_assertEqual({?PACK2, 0}, versions(?LAST_VERSION, 0)),
     ?_assertEqual({?PACK1, 0}, versions(0, ?LAST_VERSION))].

a_copy_of_another_version_leaves_the_other_pack_test() ->
    Header = header(),
    Packs = maps:merge(pack(?PACK1, Header#{checkpoint_ver := 5}, Header#{checkpoint_ver := 4}),
                       pack(?PACK2, Header#{checkpoint_ver := 3})),
    {ok, #{pack := ?PACK2}} = mount(volume(super(), Packs)).

no_valid_pack_names_each_packs_rule_test() ->
    Header = header(),
    Packs = pack(?PACK1, Header#{checkpoint_ver := 5}, Header#{checkpoint_ver := 4}),
    ?assertEqual({checkpoint, {no_valid_pack, [copy_version, checksum_offset]}},
                 failure(volume(super(), Packs))).

checkpoint_cases() ->
    H = header(),
    [{{flags, [error]}, flags(?ERX_F2FS_CP_ERROR)},
     {{flags, [large_nat_bitmap, disabled, resizefs]},
      flags(?ERX_F2FS_CP_LARGE_NAT_BITMAP bor ?ERX_F2FS_CP_DISABLED bor ?ERX_F2FS_CP_RESIZEFS)},
     {{flags, [16#8000]}, flags(16#8000)},
     {metadata_segments, H#{rsvd_segment_count := 24}},
     {metadata_segments, H#{rsvd_segment_count := 0}},
     {reserved_segments, H#{overprov_segment_count := 0}},
     {user_blocks, H#{user_block_count := 0}},
     {user_blocks, H#{user_block_count := 24 * ?SEGMENT}},
     {valid_blocks, H#{valid_block_count := 10241}},
     {valid_nodes, H#{valid_node_count := 455 * ?SEGMENT - 2}},
     {log_position, H#{cur_node_segno := [24 | tl(maps:get(cur_node_segno, H))]}},
     {log_position, H#{cur_data_blkoff := lists:duplicate(8, ?SEGMENT)}},
     {log_segments, H#{cur_data_segno := [3, 4, 4 | lists:duplicate(5, 16#ffffffff)]}},
     {log_segments, H#{cur_data_segno := [3, 4, 0 | lists:duplicate(5, 16#ffffffff)]}},
     {bitmap_size, H#{sit_ver_bitmap_bytesize := 32}},
     {bitmap_size, H#{nat_ver_bitmap_bytesize := 96}},
     {start_sum, H#{cp_pack_start_sum := 0}},
     {start_sum, H#{cp_pack_start_sum := 506}}].

each_checkpoint_rule_fails_with_its_name_test_() ->
    [{lists:flatten(io_lib:format("~p ~p", [Rule, N])),
      ?_assertEqual({checkpoint, Rule}, failure(volume(super(), pack(?PACK1, Fields))))}
     || {N, {Rule, Fields}} <- lists:enumerate(checkpoint_cases())].

%% A SIT of two segments has 512 blocks in each copy, so its version bitmap
%% of exactly 64 bytes covers 512 x 55 segments, and a main area of one more
%% segment needs a SIT block the bitmap has no bit for ([F 55]).
a_main_area_past_the_sit_bitmap_fails_test() ->
    Main = 512 * 55 + 1,
    Super = (super())#{segment_count_main := Main, section_count := Main,
                       segment_count := 7 + Main, block_count := 4096 + Main * ?SEGMENT},
    Blocks = volume(Super),
    ?assertEqual({error, {checkpoint, sit_bitmap_bits}}, mount(4096 + Main * ?SEGMENT, Blocks)).

%% NAT bits take the last blocks of the pack's segment: with a NAT of 2 x
%% 32256 segments, each of the two bitmaps of nat_bits is 2064384 bytes,
%% 1009 blocks together, which no segment holds beside a pack ([F 27]).
nat_bits_past_the_segment_fail_test() ->
    Nat = 2 * 32256,
    NatBlocks = Nat div 2 * ?SEGMENT,
    Main = 24,
    Super = (super())#{segment_count_nat := Nat, ssa_blkaddr := 2560 + Nat * ?SEGMENT,
                       main_blkaddr := 3072 + Nat * ?SEGMENT,
                       segment_count := 5 + Nat + Main,
                       block_count := 3072 + (Nat + Main) * ?SEGMENT},
    Header = (flags(?ERX_F2FS_CP_NAT_BITS))#{nat_ver_bitmap_bytesize := NatBlocks div 8},
    Partition = maps:get(block_count, Super),
    ?assertEqual({error, {checkpoint, nat_bits_room}}, mount(Partition, volume(Super, pack(?PACK1, Header)))).
