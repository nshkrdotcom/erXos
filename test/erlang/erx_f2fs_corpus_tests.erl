%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_corpus_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(BLOCK, 4096).
-define(BLOCKS_PER_SEG, 512).

%% Where the fetch step put Id's file: ERX_F2FS_CORPUS is the build tree's
%% third_party directory.
fetched(Id) ->
    filename:join([os:getenv("ERX_F2FS_CORPUS"), Id, erx_f2fs_corpus:filename(Id)]).

%% The feature bits and segments per section that each image's mkfs options
%% state: syzkaller's in each program's header, as the probe record copies
%% them; fscrypt_f2fs states none and is encrypted (docs/design-f2fs.md,
%% "Corpora"); Fuchsia's script passes -O encrypt,verity.
expected("f2fs-fuchsia") ->
    {?ERX_F2FS_FEATURE_ENCRYPT bor ?ERX_F2FS_FEATURE_VERITY, 1};
expected("f2fs-syzkaller-fscrypt") ->
    {?ERX_F2FS_FEATURE_ENCRYPT, 1};
expected("f2fs-syzkaller-" ++ N) ->
    Seed = list_to_integer(N),
    Features = case Seed rem 4 of
                   0 -> 0;
                   1 -> ?ERX_F2FS_FEATURE_ENCRYPT;
                   2 -> ?ERX_F2FS_FEATURE_EXTRA_ATTR;
                   3 -> ?ERX_F2FS_FEATURE_EXTRA_ATTR bor ?ERX_F2FS_FEATURE_FLEXIBLE_INLINE_XATTR bor
                            ?ERX_F2FS_FEATURE_INODE_CHKSUM bor ?ERX_F2FS_FEATURE_INODE_CRTIME bor
                            ?ERX_F2FS_FEATURE_PRJQUOTA
               end,
    {Features, (Seed div 4) rem 2 + 1}.

block(Image, Address) ->
    binary:part(Image, Address * ?BLOCK, ?BLOCK).

%% Each image decodes to its pinned bytes; its superblock reads with the
%% features and segments per section its mkfs options state; and its newer
%% checkpoint packs that are valid, at least one, read whole: header, copy
%% and payload. A failing image is named with what failed.
every_corpus_image_reads_as_its_mkfs_options_state_test_() ->
    {timeout, 600,
     fun() ->
             Results = [{Id, try read_image(Id) catch Class:Reason -> {Class, Reason} end}
                        || Id <- erx_f2fs_corpus:ids()],
             ?assertEqual([], [Result || {_Id, Got} = Result <- Results, Got =/= ok])
     end}.

read_image(Id) ->
    {ok, Image} = erx_f2fs_corpus:image(Id, fetched(Id)),
    {ok, Super} = erx_f2fs_codec:superblock(block(Image, 0)),
    #{feature := Features, segs_per_sec := SegsPerSec, cp_blkaddr := CpStart} = Super,
    {Features, SegsPerSec} = expected(Id),
    Packs = [Pack || Start <- [CpStart, CpStart + ?BLOCKS_PER_SEG],
                     {ok, Pack} <- [read_pack(Super, Image, Start)]],
    true = Packs =/= [],
    ok.

read_pack(#{cp_payload := PayloadBlocks} = Super, Image, Start) ->
    maybe
        {ok, #{cp_pack_total_block_count := Total, checkpoint_ver := Version}} ?=
            erx_f2fs_codec:checkpoint(block(Image, Start)),
        {ok, #{checkpoint_ver := Version}} ?=
            erx_f2fs_codec:checkpoint_copy(block(Image, Start + Total - 1)),
        Payload = [block(Image, Start + 1 + N) || N <- lists:seq(0, PayloadBlocks - 1)],
        erx_f2fs_codec:checkpoint(Super, block(Image, Start), Payload)
    end.

%%% Damaged and hostile files

scratch(Name, Bytes) ->
    Path = filename:absname(Name ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:write_file(Path, Bytes),
    Path.

program(Image) ->
    <<"syz_mount_image$f2fs(&AUTO='f2fs\\x00', &AUTO=\"$",
      (base64:encode(zlib:compress(Image)))/binary, "\")\n">>.

%% A stream that inflates past the image's pinned size stops there: 65 MiB
%% of zeros in a program well under its bound.
a_stream_past_its_image_stops_at_the_pin_test() ->
    Bomb = program(binary:copy(<<0>>, 65 bsl 20)),
    ?assert(byte_size(Bomb) < 1 bsl 20),
    ?assertEqual({error, too_large}, erx_f2fs_corpus:image("f2fs-syzkaller-0", scratch("bomb", Bomb))).

%% An image of the pinned size but other bytes is refused by its SHA-256.
other_bytes_of_the_pinned_size_are_refused_test() ->
    Program = program(binary:copy(<<1>>, 64 bsl 20)),
    ?assertEqual({error, sha256}, erx_f2fs_corpus:image("f2fs-syzkaller-0", scratch("other", Program))).

a_file_past_its_bound_is_refused_test() ->
    Big = scratch("big", binary:copy(<<"A">>, (1 bsl 20) + 1)),
    ?assertEqual({error, file_too_large}, erx_f2fs_corpus:image("f2fs-syzkaller-0", Big)).

a_program_with_two_images_is_refused_test() ->
    Two = <<"\"$AAAA\" \"$AAAA\"">>,
    ?assertEqual({error, image_string}, erx_f2fs_corpus:image("f2fs-syzkaller-0", scratch("two", Two))).

a_damaged_stream_is_refused_test() ->
    Damaged = <<"\"$", (base64:encode(<<"not zlib at all">>))/binary, "\"">>,
    ?assertMatch({error, {zlib, _}}, erx_f2fs_corpus:image("f2fs-syzkaller-0", scratch("damaged", Damaged))).
