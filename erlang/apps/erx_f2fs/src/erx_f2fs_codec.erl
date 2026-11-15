%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_codec).
-moduledoc """
F2FS's on-disk records read from a volume's blocks (docs/design-f2fs.md,
"Reading the medium"): the only module that reads block bytes. The layouts
are abi/formats/f2fs.txt's, read by erx_abi_packed; this module checks every
value a decoder reads against its bounds before anything uses it, following
the rules Linux enforces on reads and adding the bounds Linux leaves out,
here the version bitmaps' room in the checkpoint pack. [F n] cites fact n of
the F2FS facts record, part 1.

Each decoder takes whole 4096-byte blocks and answers {ok, Record}, or
{error, {Structure, Rule}} naming the structure and the first rule its bytes
broke: a decoder fails at its first error by one module-private throw,
caught once at its entry. What a decoder checks is one record's own
consistency; the rules that relate records, or a record to the partition,
are the mount's (docs/design-f2fs.md, "Mount").

The superblock (superblock/1) is read from either copy's block. When the
mount chooses a pack ([F 22]), it reads the pack's first block, its header,
with checkpoint/1, and its last block, the header's copy, with
checkpoint_copy/1, which checks only what Linux checks of it. The chosen
pack's header is read again with its payload blocks by checkpoint/3, which
adds the SIT and NAT version bitmaps; both bitmaps are
first-bit-most-significant ([F 5]), Erlang's own bit order, so they are the
bytes as they are. An orphan block (orphan_block/1) answers its inode
numbers.
""".

-export([superblock/1, checkpoint/1, checkpoint_copy/1, checkpoint/3,
         orphan_block/1, crc/2]).
-export_type([superblock/0, checkpoint/0, failure/0]).

-include("generated/erx_abi.hrl").

-define(BLOCK_SIZE, (1 bsl ?ERX_F2FS_LOG_BLOCK_SIZE)).
-define(BLOCKS_PER_SEG, (1 bsl ?ERX_F2FS_LOG_BLOCKS_PER_SEG)).
%% A checksum is a 32-bit word in the block it covers.
-define(CHECKSUM_SIZE, 4).

-doc "A superblock copy: erx_abi_packed's map of erx_f2fs_super_block.".
-type superblock() :: #{atom() => term()}.
-doc """
A checkpoint pack's header: erx_abi_packed's map of erx_f2fs_checkpoint,
and from checkpoint/3 also sit_version_bitmap and nat_version_bitmap.
""".
-type checkpoint() :: #{atom() => term()}.
-doc "The structure a decoder read and the first rule its bytes broke.".
-type failure() :: {superblock | checkpoint | orphan_block, atom()}.

%%% Entries

-doc """
The superblock copy at byte 1024 of Block, block 0 or block 1 of the
volume ([F 7]), valid under every rule of [F 54] that concerns one copy:
the magic, the checksum when SB_CHKSUM is set ([F 13]), the block,
segment and sector sizes, the segment and section counts, the device list,
the extension counts, the payload's bound, the reserved inode numbers and
the six areas' boundaries ([F 14]).
""".
-spec superblock(binary()) -> {ok, superblock()} | {error, failure()}.
superblock(Block) ->
    decode(superblock, fun() -> read_superblock(Block) end).

-doc """
A checkpoint pack's header block, valid when its checksum verifies at a
checksum_offset within the block ([F 51]) and its pack's block count is
above the header and its copy and within a segment ([F 22]).
""".
-spec checkpoint(binary()) -> {ok, checkpoint()} | {error, failure()}.
checkpoint(Block) ->
    decode(checkpoint, fun() -> read_checkpoint(Block) end).

-doc """
A checkpoint pack's last block, the copy of its header, valid when its
checksum verifies ([F 51]); Linux checks nothing else of it but that its
checkpoint_ver is the header's, which the mount compares ([F 22]).
""".
-spec checkpoint_copy(binary()) -> {ok, checkpoint()} | {error, failure()}.
checkpoint_copy(Block) ->
    decode(checkpoint, fun() -> read_checkpoint_copy(Block) end).

-doc """
A checkpoint pack's header block, as checkpoint/1 reads it, with its
version bitmaps ([F 23]). Where they lie follows from Super's cp_payload,
and Payload must be exactly that many blocks, the ones after the header:
with none, the header holds both bitmaps; with some, the header holds the
NAT bitmap and the payload the SIT bitmap. Each bitmap must fit the room
it claims, which Linux does not check: before the checksum, or within the
payload. A LARGE_NAT_BITMAP pack, whose bitmaps lie elsewhere ([F 24]),
is refused here because its bitmaps cannot be placed; the mount's set of
checkpoint flags, which refuses the flag too, is the authority on it
(docs/design-f2fs.md, "Scope: features and forms").
""".
-spec checkpoint(superblock(), binary(), [binary()]) ->
          {ok, checkpoint()} | {error, failure()}.
checkpoint(#{cp_payload := PayloadBlocks}, Block, Payload) ->
    decode(checkpoint,
           fun() -> read_checkpoint(PayloadBlocks, Block, Payload) end).

-doc """
The inode numbers an orphan block holds: the first entry_count of its
slots, at most f2fs_orphans_per_block ([F 26]). Its check_sum, blk_addr
and blk_count are read by no one.
""".
-spec orphan_block(binary()) ->
          {ok, [non_neg_integer()]} | {error, failure()}.
orphan_block(Block) ->
    decode(orphan_block, fun() -> read_orphans(Block) end).

-doc """
F2FS's CRC-32 of Data continued from Seed ([F 49]): the reflected
polynomial 0xEDB88320 without zlib's initial and final inversions, so
erlang:crc32/2, which has both, runs between two of its own.
""".
-spec crc(0..16#ffffffff, iodata()) -> 0..16#ffffffff.
crc(Seed, Data) ->
    Inverted = erlang:crc32((bnot Seed) band 16#ffffffff, Data),
    (bnot Inverted) band 16#ffffffff.

%%% The superblock

read_superblock(Block) ->
    Record = superblock_record(Block),
    Super = erx_abi_packed:decode(erx_f2fs_super_block, Record),
    require(maps:get(magic, Super) =:= ?ERX_F2FS_MAGIC, magic),
    check_superblock_checksum(Super, Record),
    check_sizes(Super),
    check_counts(Super),
    check_devices(Super),
    check_extensions(Super),
    check_reserved_inodes(Super),
    check_areas(Super),
    Super.

superblock_record(Block) ->
    require_block(Block),
    <<_:?ERX_F2FS_SUPER_OFFSET/binary,
      Record:?ERX_F2FS_SUPER_BLOCK_SIZE/binary, _/binary>> = Block,
    Record.

%% With SB_CHKSUM the checksum is crc, the record's last word, over every
%% byte before it, and checksum_offset names it ([F 13]).
check_superblock_checksum(#{feature := Feature} = Super, Record) ->
    case Feature band ?ERX_F2FS_FEATURE_SB_CHKSUM of
        0 ->
            ok;
        _ ->
            #{checksum_offset := At, crc := Stored} = Super,
            require(At =:= ?ERX_F2FS_SUPER_BLOCK_OFF_CRC, checksum_offset),
            <<Covered:At/binary, _/binary>> = Record,
            require(crc(?ERX_F2FS_MAGIC, Covered) =:= Stored, crc)
    end.

%% A block is 4096 bytes, a segment 512 blocks, and a sector at least 512
%% bytes and at most a block, a whole number of them to a block ([F 54]).
check_sizes(#{log_blocksize := LogBlock, log_blocks_per_seg := LogSegment,
              log_sectorsize := LogSector,
              log_sectors_per_block := LogSectorsPerBlock}) ->
    require(LogBlock =:= ?ERX_F2FS_LOG_BLOCK_SIZE, log_blocksize),
    require(LogSegment =:= ?ERX_F2FS_LOG_BLOCKS_PER_SEG, log_blocks_per_seg),
    require(LogSector >= ?ERX_F2FS_LOG_SECTOR_SIZE_MIN andalso
                LogSector =< ?ERX_F2FS_LOG_BLOCK_SIZE andalso
                LogSector + LogSectorsPerBlock =:= ?ERX_F2FS_LOG_BLOCK_SIZE,
            log_sectorsize).

%% The volume's segments, the main area's sections and segments, and the
%% zones they group into agree with each other and with block_count, and
%% the checkpoint pack's payload leaves room in its segment for the header,
%% its copy and the summaries ([F 54]). segs_per_sec is checked before it
%% divides.
check_counts(#{block_count := Blocks, segment_count := Segments,
               section_count := Sections, segs_per_sec := SegsPerSec,
               segment_count_main := MainSegments,
               secs_per_zone := SecsPerZone, cp_payload := Payload}) ->
    require(Segments >= ?ERX_F2FS_SEGMENT_COUNT_MIN andalso
                Segments =< ?ERX_F2FS_SEGMENT_COUNT_MAX,
            segment_count),
    require(Sections >= 1 andalso Sections =< MainSegments, section_count),
    require(SegsPerSec >= 1 andalso SegsPerSec =< Segments, segs_per_sec),
    require(MainSegments =:= Sections * SegsPerSec andalso
                Segments div SegsPerSec >= Sections,
            segment_count_main),
    require(Segments =< Blocks div ?BLOCKS_PER_SEG, block_count),
    require(SecsPerZone >= 1 andalso SecsPerZone =< Sections, secs_per_zone),
    require(Payload < ?BLOCKS_PER_SEG - ?ERX_F2FS_CP_FIXED_BLOCKS
                          - ?ERX_F2FS_CP_SUMMARY_BLOCKS_MAX,
            cp_payload).

%% A device list starts with a named device or is empty. When it is not
%% empty, the leading named devices' segments add up to the volume's
%% ([F 54]); a device is named when its path is not the empty string.
check_devices(#{devs := Devices, segment_count := Segments}) ->
    Named = lists:takewhile(fun(#{path := <<First, _/binary>>}) ->
                                    First =/= 0
                            end, Devices),
    case Named of
        [] ->
            ok;
        _ ->
            Total = lists:sum([Count || #{total_segments := Count} <- Named]),
            require(Total =:= Segments, devices)
    end.

check_extensions(#{extension_count := Cold, hot_ext_count := Hot}) ->
    require(Cold =< ?ERX_F2FS_EXTENSIONS_MAX andalso
                Hot =< ?ERX_F2FS_EXTENSIONS_MAX andalso
                Cold + Hot =< ?ERX_F2FS_EXTENSIONS_MAX,
            extensions).

check_reserved_inodes(#{node_ino := Node, meta_ino := Meta, root_ino := Root}) ->
    require(Node =:= ?ERX_F2FS_NODE_INO andalso Meta =:= ?ERX_F2FS_META_INO
                andalso Root =:= ?ERX_F2FS_ROOT_INO,
            reserved_inodes).

%% The checkpoint, SIT, NAT, SSA and main areas follow each other from
%% segment 0, each a whole number of segments, and the main area ends within
%% the volume's segments ([F 14]).
check_areas(#{segment0_blkaddr := Segment0, cp_blkaddr := Checkpoint,
              sit_blkaddr := Sit, nat_blkaddr := Nat, ssa_blkaddr := Ssa,
              main_blkaddr := Main, segment_count := Segments,
              segment_count_ckpt := CheckpointSegments,
              segment_count_sit := SitSegments,
              segment_count_nat := NatSegments,
              segment_count_ssa := SsaSegments,
              segment_count_main := MainSegments}) ->
    require(Checkpoint =:= Segment0 andalso
                Sit =:= area_end(Checkpoint, CheckpointSegments) andalso
                Nat =:= area_end(Sit, SitSegments) andalso
                Ssa =:= area_end(Nat, NatSegments) andalso
                Main =:= area_end(Ssa, SsaSegments) andalso
                area_end(Main, MainSegments) =< area_end(Segment0, Segments),
            areas).

area_end(Start, Segments) -> Start + Segments * ?BLOCKS_PER_SEG.

%%% The checkpoint pack

read_checkpoint(Block) ->
    Checkpoint = read_checkpoint_copy(Block),
    #{cp_pack_total_block_count := PackBlocks} = Checkpoint,
    require(PackBlocks > ?ERX_F2FS_CP_FIXED_BLOCKS andalso
                PackBlocks =< ?BLOCKS_PER_SEG,
            pack_blocks),
    Checkpoint.

read_checkpoint_copy(Block) ->
    require_block(Block),
    <<Fixed:?ERX_F2FS_CHECKPOINT_SIZE/binary, _/binary>> = Block,
    Checkpoint = erx_abi_packed:decode(erx_f2fs_checkpoint, Fixed),
    check_checkpoint_checksum(Checkpoint, Block),
    Checkpoint.

%% The checksum lies after the header's fixed part and within the block,
%% and covers every byte of the block but its own ([F 51]).
check_checkpoint_checksum(#{checksum_offset := At}, Block) ->
    require(At >= ?ERX_F2FS_CHECKPOINT_SIZE andalso
                At =< ?BLOCK_SIZE - ?CHECKSUM_SIZE,
            checksum_offset),
    <<Before:At/binary, Stored:32/little, After/binary>> = Block,
    require(crc(?ERX_F2FS_MAGIC, [Before, After]) =:= Stored, crc).

read_checkpoint(PayloadBlocks, Block, Payload) ->
    Checkpoint = read_checkpoint(Block),
    require(length(Payload) =:= PayloadBlocks, payload_count),
    lists:foreach(fun require_block/1, Payload),
    {Sit, Nat} = version_bitmaps(Checkpoint, Block, Payload),
    Checkpoint#{sit_version_bitmap => Sit, nat_version_bitmap => Nat}.

%% Where the bitmaps lie ([F 23]): without payload blocks, the SIT bitmap
%% and then the NAT bitmap follow the header's fixed part; with them, the
%% NAT bitmap follows the fixed part and the SIT bitmap fills the payload
%% from its first byte. Either way the header's bitmaps end before its
%% checksum. Payload has the superblock's cp_payload blocks, as
%% read_checkpoint/3 has checked.
version_bitmaps(#{ckpt_flags := Flags}, _Block, _Payload)
  when Flags band ?ERX_F2FS_CP_LARGE_NAT_BITMAP =/= 0 ->
    fail(large_nat_bitmap);
version_bitmaps(#{sit_ver_bitmap_bytesize := SitBytes,
                  nat_ver_bitmap_bytesize := NatBytes,
                  checksum_offset := At}, Block, Payload) ->
    HeaderRoom = At - ?ERX_F2FS_CHECKPOINT_SIZE,
    <<_:?ERX_F2FS_CHECKPOINT_SIZE/binary, Bitmaps:HeaderRoom/binary,
      _/binary>> = Block,
    case Payload of
        [] ->
            require(SitBytes + NatBytes =< HeaderRoom, bitmap_room),
            <<Sit:SitBytes/binary, Nat:NatBytes/binary, _/binary>> = Bitmaps,
            {Sit, Nat};
        _ ->
            require(NatBytes =< HeaderRoom andalso
                        SitBytes =< length(Payload) * ?BLOCK_SIZE,
                    bitmap_room),
            <<Nat:NatBytes/binary, _/binary>> = Bitmaps,
            <<Sit:SitBytes/binary, _/binary>> = iolist_to_binary(Payload),
            {Sit, Nat}
    end.

read_orphans(Block) ->
    require_block(Block),
    #{ino := Slots, entry_count := Used} =
        erx_abi_packed:decode(erx_f2fs_orphan_block, Block),
    require(Used =< ?ERX_F2FS_ORPHANS_PER_BLOCK, entry_count),
    lists:sublist(Slots, Used).

%%% The one failure path

decode(Structure, Read) ->
    try
        {ok, Read()}
    catch
        throw:{?MODULE, Rule} -> {error, {Structure, Rule}}
    end.

%% Every decoder reads whole blocks: anything else, a bitstring that is not
%% whole bytes included, is no block.
require_block(Block) ->
    require(is_binary(Block) andalso byte_size(Block) =:= ?BLOCK_SIZE, block_size).

require(true, _Rule) -> ok;
require(false, Rule) -> fail(Rule).

-spec fail(atom()) -> no_return().
fail(Rule) -> throw({?MODULE, Rule}).
