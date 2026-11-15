%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of F2FS's codec, erx_f2fs_codec (docs/design-f2fs.md, "Reading the
%% medium"), for its superblock and checkpoint pack readers. It runs from
%% tools/fuzz/erx_f2fs.rb, which also runs it against seeded faults.
%%
%% The seeds are erx_f2fs_codec_tests' fixtures: a superblock, a checkpoint header
%% with its bitmaps, one with its SIT bitmap in a payload block, and an orphan block,
%% which must each read as valid first (failure `seed`). Then each case mutates one,
%% by byte writes biased to the fixed fields or by setting one decoded field to a
%% boundary or random value, with the checksum mostly fixed up by the tests' own
%% bitwise CRC so that the mutation reaches the rules behind it, and reads it with
%% blocks of other sizes and payloads of other lengths among the inputs. Every read
%% must answer {ok, Record} or {error, {Structure, Rule}} (`shape`), never raise
%% (`crash`), and give bitmaps and orphan lists of the sizes their counts claim
%% (`size`). A superblock whose area addresses were moved apart under a fixed-up
%% checksum must fail with `areas` (failure `areas`), and a run reaches every rule
%% of ?REACHED (failure `unreached`).
-module(erx_f2fs_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(BLOCK, 4096).
%% Every outcome a run of the default length reaches; one it misses means the
%% mutations no longer reach that rule (failure `unreached`).
-define(REACHED,
        [{superblock, Rule} || Rule <- [ok, block_size, magic, crc, checksum_offset,
                                        log_blocksize, log_blocks_per_seg,
                                        log_sectorsize, segment_count,
                                        section_count, segs_per_sec,
                                        segment_count_main, block_count,
                                        secs_per_zone, cp_payload, devices,
                                        extensions, reserved_inodes, areas]]
        ++ [{checkpoint, Rule} || Rule <- [ok, block_size, crc, checksum_offset,
                                           pack_blocks, large_nat_bitmap,
                                           payload_count, bitmap_room]]
        ++ [{orphan_block, Rule} || Rule <- [ok, block_size, entry_count]]).
-define(AREA_FIELDS, [segment0_blkaddr, cp_blkaddr, sit_blkaddr, nat_blkaddr,
                      ssa_blkaddr, main_blkaddr]).

run([Seed, Cases]) ->
    rand:seed(exsss, list_to_integer(Seed)),
    Count = list_to_integer(Cases),
    check_seeds(),
    Kinds = [fun superblock_case/0, fun area_case/0, fun checkpoint_case/0,
             fun orphan_case/0],
    Outcomes = [(pick(Kinds))() || _ <- lists:seq(1, Count)],
    io:format("fuzz: ~b cases ok~n", [Count]),
    %% How often each rule answered, so a run shows which checks the cases reach.
    Tally = tally(Outcomes),
    [io:format("  ~p ~p~n", [Outcome, Times])
     || {Outcome, Times} <- lists:sort(maps:to_list(Tally))],
    case [Outcome || Outcome <- ?REACHED, not maps:is_key(Outcome, Tally)] of
        [] -> ok;
        Missed -> fail(unreached, Missed)
    end,
    halt(0).

fail(Property, Detail) ->
    io:format("fuzz failure: ~s: ~0tp~n", [Property, Detail]),
    halt(1).

%%% Seeds

super_fields() -> erx_f2fs_codec_tests:superblock_fields().

header_fields() -> erx_f2fs_codec_tests:checkpoint_fields().

%% The superblock a pack of this payload belongs to.
super_with(Payload) -> (super_fields())#{cp_payload => length(Payload)}.

%% A header and its payload: the bitmaps in the header, or the SIT bitmap in one
%% payload block.
packs() ->
    Fields = header_fields(),
    InHeader = erx_f2fs_codec_tests:checkpoint_block(Fields, random_bytes(128)),
    WithPayload = erx_f2fs_codec_tests:checkpoint_block(
                    Fields#{sit_ver_bitmap_bytesize => 3000}, random_bytes(64)),
    [{InHeader, []}, {WithPayload, [random_bytes(?BLOCK)]}].

check_seeds() ->
    Super = erx_f2fs_codec_tests:superblock_block(super_fields()),
    {ok, _} = expect(seed, erx_f2fs_codec:superblock(Super)),
    [{ok, _} = expect(seed, erx_f2fs_codec:checkpoint(super_with(Payload), Header,
                                                      Payload))
     || {Header, Payload} <- packs()],
    Orphans = erx_f2fs_codec_tests:orphan_block([7, 8, 9], 3),
    {ok, [7, 8, 9]} = expect(seed, erx_f2fs_codec:orphan_block(Orphans)),
    ok.

expect(_Property, {ok, _} = Result) -> Result;
expect(Property, Result) -> fail(Property, Result).

%%% Cases

superblock_case() ->
    Fields = super_fields(),
    Record = case rand:uniform(3) of
                 1 -> mutate_field(erx_f2fs_super_block, Fields);
                 2 -> mutate_bytes(erx_abi_packed:encode(erx_f2fs_super_block,
                                                         Fields), 200);
                 3 -> erx_abi_packed:encode(erx_f2fs_super_block,
                                            name_devices(Fields))
             end,
    Block = super_block(maybe_fix(Record, ?ERX_F2FS_SUPER_BLOCK_OFF_CRC)),
    outcome(superblock, read(superblock, fun erx_f2fs_codec:superblock/1, [resize(Block)])).

%% One area address moved by a non-zero amount: only [F 14] relates it to the
%% others, so the read must fail with areas.
area_case() ->
    Field = lists:nth(rand:uniform(length(?AREA_FIELDS)), ?AREA_FIELDS),
    Fields = super_fields(),
    Moved = maps:get(Field, Fields) + delta(),
    Record = erx_abi_packed:encode(erx_f2fs_super_block, Fields#{Field => Moved}),
    Block = super_block(fix(Record, ?ERX_F2FS_SUPER_BLOCK_OFF_CRC)),
    case erx_f2fs_codec:superblock(Block) of
        {error, {superblock, areas}} -> {superblock, areas};
        Other -> fail(areas, {Field, Moved, Other})
    end.

checkpoint_case() ->
    {Header, Payload} = lists:nth(rand:uniform(2), packs()),
    <<Fixed:?ERX_F2FS_CHECKPOINT_SIZE/binary, Rest/binary>> = Header,
    Mutated = case rand:uniform(2) of
                  1 ->
                      Decoded = erx_abi_packed:decode(erx_f2fs_checkpoint, Fixed),
                      Changed = mutate_field(erx_f2fs_checkpoint, Decoded),
                      <<Changed/binary, Rest/binary>>;
                  2 ->
                      mutate_bytes(Header, 256)
              end,
    <<_:?ERX_F2FS_CHECKPOINT_OFF_CHECKSUM_OFFSET/binary, At:32/little,
      _/binary>> = Mutated,
    Block = maybe_fix(Mutated, At),
    Pages = case rand:uniform(4) of
                1 -> [];
                2 -> Payload ++ [random_bytes(?BLOCK)];
                _ -> Payload
            end,
    read(checkpoint, fun erx_f2fs_codec:checkpoint/1, [resize(Block)]),
    read(checkpoint, fun erx_f2fs_codec:checkpoint_copy/1, [resize(Block)]),
    Result = read(checkpoint, fun erx_f2fs_codec:checkpoint/3,
                  [super_with(Payload), resize(Block), Pages]),
    case Result of
        {ok, #{sit_version_bitmap := Sit, nat_version_bitmap := Nat,
               sit_ver_bitmap_bytesize := SitBytes,
               nat_ver_bitmap_bytesize := NatBytes}} ->
            byte_size(Sit) =:= SitBytes andalso byte_size(Nat) =:= NatBytes
                orelse fail(size, {SitBytes, NatBytes});
        {error, _} ->
            ok
    end,
    outcome(checkpoint, Result).

orphan_case() ->
    Used = pick([0, 1, 1019, 1020, 1021, 16#ffffffff, rand:uniform(2048)]),
    Block = mutate_bytes(erx_f2fs_codec_tests:orphan_block(lists:seq(1, 10), Used),
                         ?BLOCK),
    <<_:?ERX_F2FS_ORPHAN_BLOCK_OFF_ENTRY_COUNT/binary, Claimed:32/little,
      _/binary>> = Block,
    Result = read(orphan_block, fun erx_f2fs_codec:orphan_block/1, [resize(Block)]),
    case Result of
        {ok, Inodes} when length(Inodes) =:= Claimed -> ok;
        {ok, Inodes} -> fail(size, {Claimed, length(Inodes)});
        {error, _} -> ok
    end,
    outcome(orphan_block, Result).

%% Runs one read; anything but {ok, _} or {error, {Structure, Rule}} fails.
read(Structure, Read, Arguments) ->
    try apply(Read, Arguments) of
        {ok, _} = Result -> Result;
        {error, {Structure, Rule}} = Result when is_atom(Rule) -> Result;
        Other -> fail(shape, Other)
    catch
        Class:Reason:Stack -> fail(crash, {Structure, Class, Reason, hd(Stack)})
    end.

outcome(Structure, {ok, _}) -> {Structure, ok};
outcome(_Structure, {error, Failure}) -> Failure.

tally(Outcomes) ->
    lists:foldl(fun(Outcome, Counts) ->
                        maps:update_with(Outcome, fun(Times) -> Times + 1 end, 1, Counts)
                end, #{}, Outcomes).

%%% Mutations

%% A layout's bytes with one integer field set to a boundary or random value,
%% narrowed until encode/2 takes it, so the field's width is the layout's own;
%% arrays and byte fields are left to the byte writes.
mutate_field(Layout, Fields) ->
    Integers = [Field || {Field, Value} <- maps:to_list(Fields), is_integer(Value)],
    Field = pick(lists:sort(Integers)),
    Old = maps:get(Field, Fields),
    Value = pick([0, 1, Old + 1, max(Old - 1, 0), 16#ff, 16#ffff, 16#ffffffff,
                  rand:uniform(16#ffffffff), rand:uniform(8192)]),
    Narrowed = [Value band Mask || Mask <- [16#ffffffffffffffff, 16#ffffffff,
                                            16#ffff, 16#ff]],
    hd(lists:filtermap(fun(Candidate) -> encoded(Layout, Fields#{Field => Candidate}) end,
                       Narrowed)).

encoded(Layout, Fields) ->
    try
        {true, erx_abi_packed:encode(Layout, Fields)}
    catch
        error:_ -> false
    end.

%% The device list's first one or two devices named, with segments that may
%% or may not add up to the volume's.
name_devices(#{devs := [First, Second | Rest], segment_count := Segments} = Fields) ->
    Named = fun(Device, Total) -> Device#{path := <<"/dev/f2fs", 0:440>>,
                                          total_segments := Total} end,
    Split = rand:uniform(Segments + 1) - 1,
    Devices = case rand:uniform(3) of
                  1 -> [Named(First, Segments), Second | Rest];
                  2 -> [Named(First, Split), Named(Second, Segments - Split) | Rest];
                  3 -> [Named(First, rand:uniform(64)), Second | Rest]
              end,
    Fields#{devs := Devices}.

%% Between one and eight byte writes, mostly within the first Bias bytes.
mutate_bytes(Bytes, Bias) ->
    lists:foldl(fun(_, Acc) ->
                        Limit = case rand:uniform(4) of
                                    1 -> byte_size(Acc);
                                    _ -> min(Bias, byte_size(Acc))
                                end,
                        At = rand:uniform(Limit) - 1,
                        <<Before:At/binary, _, After/binary>> = Acc,
                        <<Before/binary, (rand:uniform(256) - 1), After/binary>>
                end, Bytes, lists:seq(1, rand:uniform(8))).

%% The checksum fixed up in nine cases of ten, and only where it fits.
maybe_fix(Bytes, At) ->
    case rand:uniform(10) of
        1 -> Bytes;
        _ -> fix(Bytes, At)
    end.

fix(Bytes, At) when At + 4 =< byte_size(Bytes) ->
    <<Before:At/binary, _:32, After/binary>> = Bytes,
    Crc = erx_f2fs_codec_tests:crc_reference(?ERX_F2FS_MAGIC,
                                             <<Before/binary, After/binary>>),
    <<Before/binary, Crc:32/little, After/binary>>;
fix(Bytes, _At) -> Bytes.

super_block(Record) ->
    Tail = ?BLOCK - ?ERX_F2FS_SUPER_OFFSET - byte_size(Record),
    <<0:(?ERX_F2FS_SUPER_OFFSET * 8), Record/binary, 0:(Tail * 8)>>.

%% The block itself in most cases, else one cut short or one byte too long.
resize(Block) ->
    case rand:uniform(20) of
        1 -> binary:part(Block, 0, rand:uniform(byte_size(Block)) - 1);
        2 -> <<Block/binary, 0>>;
        _ -> Block
    end.

delta() ->
    Magnitude = pick([1, 2, 511, 512, 1024, rand:uniform(100000)]),
    pick([Magnitude, -min(Magnitude, 512)]).

pick(List) -> lists:nth(rand:uniform(length(List)), List).

random_bytes(Count) -> rand:bytes(Count).
