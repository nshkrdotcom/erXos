%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_f2fs_codec (docs/design-f2fs.md, "Reading the medium" and
%% "Unit and property tests"), run on stock OTP by test/host/erx_f2fs_codec_test.rb,
%% which also runs them against seeded faults.
%%
%% The fixtures are a 64 MiB volume's superblock and checkpoint header built field by
%% field with erx_abi_packed:encode/2 and their checksums computed by crc_reference/2, a
%% bitwise CRC written from the facts record's definition ([F 49]) and independent of
%% the codec's use of erlang:crc32/2. Agreeing with that definition does not settle
%% whether Linux's CRC routine is the same (open question 1 of the facts record): the
%% CRCs of Linux-made images do, when the oracle guest makes them. Each rejection case breaks one rule of a fixture,
%% refreshes the checksum so the rule itself is what fails, and expects that rule.
%% erx_f2fs_fuzz builds its seeds from the same fixtures.
-module(erx_f2fs_codec_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([superblock_fields/0, superblock_block/1, checkpoint_fields/0,
         checkpoint_block/2, orphan_block/2, crc_reference/2]).

-define(BLOCK, 4096).

%%% Fixtures

%% A volume of 16384 blocks: segment 0 at block 512, then 2 checkpoint, 2 SIT,
%% 2 NAT and 1 SSA segments and a main area of 24, ending at the volume's end.
superblock_fields() ->
    Empty = maps:from_list([{Field, 0} || Field <- integer_fields(erx_f2fs_super_block)]),
    Empty#{magic => ?ERX_F2FS_MAGIC, major_ver => 1, minor_ver => 16,
           log_sectorsize => 9, log_sectors_per_block => 3,
           log_blocksize => 12, log_blocks_per_seg => 9,
           segs_per_sec => 1, secs_per_zone => 1,
           checksum_offset => ?ERX_F2FS_SUPER_BLOCK_OFF_CRC,
           block_count => 16384, section_count => 24, segment_count => 31,
           segment_count_ckpt => 2, segment_count_sit => 2,
           segment_count_nat => 2, segment_count_ssa => 1,
           segment_count_main => 24,
           segment0_blkaddr => 512, cp_blkaddr => 512, sit_blkaddr => 1536,
           nat_blkaddr => 2560, ssa_blkaddr => 3584, main_blkaddr => 4096,
           root_ino => 3, node_ino => 1, meta_ino => 2,
           uuid => binary:copy(<<16#5a>>, 16),
           volume_name => <<0:8192>>,
           extension_list => lists:duplicate(64, <<0:64>>),
           version => <<0:2048>>, init_version => <<0:2048>>,
           feature => ?ERX_F2FS_FEATURE_EXTRA_ATTR bor
                          ?ERX_F2FS_FEATURE_INODE_CHKSUM bor
                          ?ERX_F2FS_FEATURE_SB_CHKSUM,
           encrypt_pw_salt => <<0:128>>,
           devs => lists:duplicate(8, #{path => <<0:512>>, total_segments => 0}),
           qf_ino => [0, 0, 0],
           s_stop_reason => <<0:256>>, s_errors => <<0:128>>}.

%% The superblock's block: 1024 bytes before the record, the record with its
%% checksum computed when SB_CHKSUM asks for one, and zeros after it.
superblock_block(#{feature := Feature} = Fields) ->
    Unsigned = erx_abi_packed:encode(erx_f2fs_super_block, Fields#{crc => 0}),
    Record = case Feature band ?ERX_F2FS_FEATURE_SB_CHKSUM of
                 0 -> erx_abi_packed:encode(erx_f2fs_super_block, Fields);
                 _ -> with_crc(Unsigned, ?ERX_F2FS_SUPER_BLOCK_OFF_CRC)
             end,
    Tail = ?BLOCK - ?ERX_F2FS_SUPER_OFFSET - byte_size(Record),
    <<0:(?ERX_F2FS_SUPER_OFFSET * 8), Record/binary, 0:(Tail * 8)>>.

%% Pack 1 of the volume's first checkpoint: 64-byte SIT and NAT bitmaps (one
%% bit per block of one copy of a one-segment table) and the checksum in the
%% header's last word.
checkpoint_fields() ->
    Empty = maps:from_list([{Field, 0} || Field <- integer_fields(erx_f2fs_checkpoint)]),
    Empty#{checkpoint_ver => 1, user_block_count => 10240,
           rsvd_segment_count => 2, overprov_segment_count => 4,
           free_segment_count => 18,
           cur_node_segno => [0, 1, 2 | lists:duplicate(5, 16#ffffffff)],
           cur_node_blkoff => lists:duplicate(8, 1),
           cur_data_segno => [3, 4, 5 | lists:duplicate(5, 16#ffffffff)],
           cur_data_blkoff => lists:duplicate(8, 1),
           ckpt_flags => ?ERX_F2FS_CP_UMOUNT bor ?ERX_F2FS_CP_CRC_RECOVERY,
           cp_pack_total_block_count => 8, cp_pack_start_sum => 1,
           valid_node_count => 1, valid_inode_count => 1, next_free_nid => 4,
           sit_ver_bitmap_bytesize => 64, nat_ver_bitmap_bytesize => 64,
           checksum_offset => ?BLOCK - 4,
           alloc_type => <<0:128>>}.

%% A header block: the fixed part, then Bitmaps, the bytes the bitmaps occupy
%% in the header, then zeros, and the checksum at checksum_offset.
checkpoint_block(#{checksum_offset := At} = Fields, Bitmaps) ->
    Fixed = erx_abi_packed:encode(erx_f2fs_checkpoint, Fields),
    Body = <<Fixed/binary, Bitmaps/binary>>,
    Unsigned = <<Body/binary, 0:((?BLOCK - byte_size(Body)) * 8)>>,
    with_crc(Unsigned, At).

orphan_block(Inodes, Used) ->
    Slots = Inodes ++ lists:duplicate(?ERX_F2FS_ORPHANS_PER_BLOCK - length(Inodes), 0),
    erx_abi_packed:encode(erx_f2fs_orphan_block,
                          #{ino => Slots, blk_addr => 1, blk_count => 1,
                            entry_count => Used, check_sum => 0}).

%% Bytes with the 32-bit checksum at At replaced by the CRC of every other
%% byte, seeded with the magic ([F 13], [F 51]).
with_crc(Bytes, At) ->
    <<Before:At/binary, _:32, After/binary>> = Bytes,
    Crc = crc_reference(?ERX_F2FS_MAGIC, <<Before/binary, After/binary>>),
    <<Before/binary, Crc:32/little, After/binary>>.

%% The CRC as [F 49] defines it, one bit at a time: the reflected polynomial
%% 0xEDB88320, bytes in order, least significant bit first, from the seed and
%% with no inversion at either end.
crc_reference(Seed, Data) ->
    lists:foldl(fun(Byte, Crc) -> crc_bits(Crc bxor Byte, 8) end,
                Seed, binary_to_list(Data)).

crc_bits(Crc, 0) -> Crc;
crc_bits(Crc, Left) when Crc band 1 =:= 1 ->
    crc_bits((Crc bsr 1) bxor 16#EDB88320, Left - 1);
crc_bits(Crc, Left) -> crc_bits(Crc bsr 1, Left - 1).

%% The fields of a layout whose decoded value is an integer.
integer_fields(Layout) ->
    Size = case Layout of
               erx_f2fs_super_block -> ?ERX_F2FS_SUPER_BLOCK_SIZE;
               erx_f2fs_checkpoint -> ?ERX_F2FS_CHECKPOINT_SIZE
           end,
    Decoded = erx_abi_packed:decode(Layout, <<0:(Size * 8)>>),
    [Field || {Field, Value} <- maps:to_list(Decoded), is_integer(Value)].

superblock(Fields) -> erx_f2fs_codec:superblock(superblock_block(Fields)).

header(Fields) -> checkpoint_block(Fields, binary:copy(<<16#a5>>, 128)).

%% A header read with its payload, under a superblock whose cp_payload is the
%% payload's length.
pack(Block, Payload) ->
    Super = (superblock_fields())#{cp_payload => length(Payload)},
    erx_f2fs_codec:checkpoint(Super, Block, Payload).

%%% The CRC

crc_matches_the_definition_from_any_seed_test() ->
    Cases = [{0, <<>>}, {16#ffffffff, <<"123456789">>},
             {?ERX_F2FS_MAGIC, <<"F2FS">>},
             {16#12345678, binary:copy(<<0, 255, 16#a5>>, 1365)}],
    [?assertEqual({Seed, Data, crc_reference(Seed, Data)},
                  {Seed, Data, erx_f2fs_codec:crc(Seed, Data)})
     || {Seed, Data} <- Cases].

crc_continues_over_iodata_test() ->
    Whole = erx_f2fs_codec:crc(?ERX_F2FS_MAGIC, <<"abcdef">>),
    ?assertEqual(Whole, erx_f2fs_codec:crc(?ERX_F2FS_MAGIC, [<<"abc">>, <<"def">>])),
    Partial = erx_f2fs_codec:crc(?ERX_F2FS_MAGIC, <<"abc">>),
    ?assertEqual(Whole, erx_f2fs_codec:crc(Partial, <<"def">>)).

%%% The superblock

a_valid_superblock_reads_as_its_fields_test() ->
    Fields = superblock_fields(),
    {ok, Super} = superblock(Fields),
    ?assertEqual(Fields#{crc => maps:get(crc, Super)}, Super).

a_superblock_without_sb_chksum_is_not_checked_test() ->
    Fields = (superblock_fields())#{feature => ?ERX_F2FS_FEATURE_EXTRA_ATTR,
                                    checksum_offset => 0, crc => 16#dead},
    ?assertMatch({ok, #{crc := 16#dead}}, superblock(Fields)).

a_changed_byte_under_the_checksum_fails_it_test() ->
    <<Before:1100/binary, Byte, After/binary>> = superblock_block(superblock_fields()),
    Changed = <<Before/binary, (Byte bxor 1), After/binary>>,
    ?assertEqual({error, {superblock, crc}}, erx_f2fs_codec:superblock(Changed)).

%% Each case breaks one rule of [F 54] and keeps every other.
each_superblock_rule_fails_with_its_name_test_() ->
    Valid = superblock_fields(),
    Cases =
        [{magic, #{magic => ?ERX_F2FS_MAGIC + 1}},
         {checksum_offset, #{checksum_offset => 3064}},
         {log_blocksize, #{log_blocksize => 13}},
         {log_blocks_per_seg, #{log_blocks_per_seg => 10}},
         {log_sectorsize, #{log_sectorsize => 8, log_sectors_per_block => 4}},
         {log_sectorsize, #{log_sectors_per_block => 2}},
         {segment_count, #{segment_count => 8}},
         {segment_count, #{segment_count => ?ERX_F2FS_SEGMENT_COUNT_MAX + 1}},
         {section_count, #{section_count => 0}},
         {section_count, #{section_count => 25}},
         {segs_per_sec, #{segs_per_sec => 0}},
         {segs_per_sec, #{segs_per_sec => 32}},
         {segment_count_main, #{section_count => 12}},
         {segment_count_main, #{segs_per_sec => 2, section_count => 24,
                                segment_count_main => 48}},
         {block_count, #{block_count => 31 * 512 - 1}},
         {secs_per_zone, #{secs_per_zone => 0}},
         {secs_per_zone, #{secs_per_zone => 25}},
         {cp_payload, #{cp_payload => 504}},
         {extensions, #{extension_count => 65}},
         {extensions, #{hot_ext_count => 65}},
         {extensions, #{extension_count => 40, hot_ext_count => 25}},
         {reserved_inodes, #{root_ino => 4}},
         {reserved_inodes, #{node_ino => 2}},
         {reserved_inodes, #{meta_ino => 3}},
         {devices, #{devs => [#{path => <<"/dev/a", 0:464>>,
                                total_segments => 30}
                              | lists:duplicate(7, #{path => <<0:512>>,
                                                     total_segments => 0})]}},
         {areas, #{cp_blkaddr => 1024}},
         {areas, #{sit_blkaddr => 1537}},
         {areas, #{nat_blkaddr => 2048}},
         {areas, #{ssa_blkaddr => 3072}},
         {areas, #{main_blkaddr => 4608}},
         {areas, #{segment_count_main => 25, section_count => 25}}],
    [{atom_to_list(Rule), ?_assertEqual({error, {superblock, Rule}},
                                        superblock(maps:merge(Valid, Broken)))}
     || {Rule, Broken} <- Cases].

named_devices_whose_segments_add_up_are_accepted_test() ->
    Devices = [#{path => <<"/dev/a", 0:464>>, total_segments => 20},
               #{path => <<"/dev/b", 0:464>>, total_segments => 11}
               | lists:duplicate(6, #{path => <<0:512>>, total_segments => 99})],
    ?assertMatch({ok, _}, superblock((superblock_fields())#{devs => Devices})).

a_superblock_block_of_another_size_fails_test() ->
    Block = superblock_block(superblock_fields()),
    ?assertEqual({error, {superblock, block_size}},
                 erx_f2fs_codec:superblock(binary:part(Block, 0, 4095))).

%%% The checkpoint pack

a_valid_header_reads_as_its_fields_test() ->
    Fields = checkpoint_fields(),
    ?assertEqual({ok, Fields}, erx_f2fs_codec:checkpoint(header(Fields))).

the_checksum_may_sit_before_the_blocks_end_test() ->
    Fields = (checkpoint_fields())#{checksum_offset => 4000},
    ?assertEqual({ok, Fields}, erx_f2fs_codec:checkpoint(header(Fields))).

a_changed_byte_after_the_checksum_fails_it_test() ->
    Block = header((checkpoint_fields())#{checksum_offset => 4000}),
    <<Before:4090/binary, Byte, After/binary>> = Block,
    ?assertEqual({error, {checkpoint, crc}},
                 erx_f2fs_codec:checkpoint(<<Before/binary, (Byte bxor 1), After/binary>>)).

each_header_rule_fails_with_its_name_test_() ->
    Valid = checkpoint_fields(),
    Cases = [{checksum_offset, #{checksum_offset => ?ERX_F2FS_CHECKPOINT_SIZE - 1}},
             {checksum_offset, #{checksum_offset => ?BLOCK - 3}},
             {pack_blocks, #{cp_pack_total_block_count => 2}},
             {pack_blocks, #{cp_pack_total_block_count => 513}}],
    [{atom_to_list(Rule), ?_assertEqual({error, {checkpoint, Rule}},
                                        erx_f2fs_codec:checkpoint(raw_header(maps:merge(Valid, Broken))))}
     || {Rule, Broken} <- Cases].

%% A header whose checksum_offset lies outside the block has nowhere to
%% carry a checksum, so its block is built without one.
raw_header(#{checksum_offset := At} = Fields) when At > ?BLOCK - 4 ->
    Fixed = erx_abi_packed:encode(erx_f2fs_checkpoint, Fields),
    <<Fixed/binary, 0:((?BLOCK - byte_size(Fixed)) * 8)>>;
raw_header(Fields) -> header(Fields).

the_header_holds_both_bitmaps_without_payload_test() ->
    Sit = binary:copy(<<16#81>>, 64),
    Nat = binary:copy(<<16#18>>, 64),
    Block = checkpoint_block(checkpoint_fields(), <<Sit/binary, Nat/binary>>),
    ?assertMatch({ok, #{sit_version_bitmap := Sit, nat_version_bitmap := Nat}},
                 pack(Block, [])).

the_payload_holds_the_sit_bitmap_test() ->
    Sit = binary:copy(<<16#81>>, 5000),
    Nat = binary:copy(<<16#18>>, 64),
    Fields = (checkpoint_fields())#{sit_ver_bitmap_bytesize => 5000},
    Block = checkpoint_block(Fields, Nat),
    <<First:4096/binary, Rest/binary>> = <<Sit/binary, 0:(3192 * 8)>>,
    ?assertMatch({ok, #{sit_version_bitmap := Sit, nat_version_bitmap := Nat}},
                 pack(Block, [First, Rest])).

%% Bitmaps one byte larger than the room before the checksum, or than the
%% payload, are refused before they are read ([F 23]).
bitmaps_past_their_room_fail_test_() ->
    Room = ?BLOCK - 4 - ?ERX_F2FS_CHECKPOINT_SIZE,
    Header = fun(Sit, Nat) ->
                     header((checkpoint_fields())#{sit_ver_bitmap_bytesize => Sit,
                                                   nat_ver_bitmap_bytesize => Nat})
             end,
    Payload = [<<0:(?BLOCK * 8)>>],
    [?_assertMatch({ok, _}, pack(Header(Room - 64, 64), [])),
     ?_assertEqual({error, {checkpoint, bitmap_room}},
                   pack(Header(Room - 63, 64), [])),
     ?_assertMatch({ok, _}, pack(Header(?BLOCK, Room), Payload)),
     ?_assertEqual({error, {checkpoint, bitmap_room}},
                   pack(Header(?BLOCK + 1, 64), Payload)),
     ?_assertEqual({error, {checkpoint, bitmap_room}},
                   pack(Header(64, Room + 1), Payload))].

a_large_nat_bitmap_pack_is_refused_test() ->
    Fields = (checkpoint_fields())#{ckpt_flags => ?ERX_F2FS_CP_LARGE_NAT_BITMAP},
    ?assertEqual({error, {checkpoint, large_nat_bitmap}},
                 pack(header(Fields), [])).

%% The payload is as many blocks as the superblock's cp_payload says, so
%% where the bitmaps lie never depends on how many blocks a caller passed.
a_payload_of_another_count_fails_test_() ->
    Block = header(checkpoint_fields()),
    Super = superblock_fields(),
    [?_assertEqual({error, {checkpoint, payload_count}},
                   erx_f2fs_codec:checkpoint(Super#{cp_payload => 1}, Block, [])),
     ?_assertEqual({error, {checkpoint, payload_count}},
                   erx_f2fs_codec:checkpoint(Super, Block, [<<0:(?BLOCK * 8)>>]))].

%% The header's copy at the pack's end needs only its checksum ([F 22]): a
%% block count out of range fails the header and not the copy.
the_copy_is_checked_for_its_checksum_alone_test() ->
    Block = header((checkpoint_fields())#{cp_pack_total_block_count => 600}),
    ?assertEqual({error, {checkpoint, pack_blocks}}, erx_f2fs_codec:checkpoint(Block)),
    ?assertMatch({ok, #{cp_pack_total_block_count := 600}},
                 erx_f2fs_codec:checkpoint_copy(Block)),
    <<Before:100/binary, Byte, After/binary>> = Block,
    ?assertEqual({error, {checkpoint, crc}},
                 erx_f2fs_codec:checkpoint_copy(<<Before/binary, (Byte bxor 1), After/binary>>)).

a_bitstring_is_no_block_test() ->
    ?assertEqual({error, {superblock, block_size}},
                 erx_f2fs_codec:superblock(<<0:32767>>)).

a_payload_block_of_another_size_fails_test() ->
    ?assertEqual({error, {checkpoint, block_size}},
                 pack(header(checkpoint_fields()), [<<0:8>>])).

%%% Orphan blocks

an_orphan_block_answers_its_used_slots_test() ->
    ?assertEqual({ok, [7, 9, 11]}, erx_f2fs_codec:orphan_block(orphan_block([7, 9, 11, 13], 3))),
    Full = lists:seq(100, 100 + ?ERX_F2FS_ORPHANS_PER_BLOCK - 1),
    ?assertEqual({ok, Full},
                 erx_f2fs_codec:orphan_block(orphan_block(Full, ?ERX_F2FS_ORPHANS_PER_BLOCK))).

an_orphan_count_past_the_block_fails_test() ->
    ?assertEqual({error, {orphan_block, entry_count}},
                 erx_f2fs_codec:orphan_block(orphan_block([], ?ERX_F2FS_ORPHANS_PER_BLOCK + 1))).
