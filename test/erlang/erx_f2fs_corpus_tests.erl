%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_corpus_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

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

%% Each image deps.lock pins (ERX_DEPS_LOCK) decodes from the file the fetch
%% step put under ERX_F2FS_CORPUS to its pinned bytes; its superblock reads
%% with the features and segments per section its mkfs options state; and at
%% least one of its checkpoint packs reads whole: header, copy and payload.
%% A failing image is named with what failed.
every_corpus_image_reads_as_its_mkfs_options_state_test_() ->
    {timeout, 600,
     fun() ->
             Pins = erx_f2fs_corpus:pins(os:getenv("ERX_DEPS_LOCK")),
             ?assertEqual(18, length(Pins)),
             Results = [{Id, try read_image(Pin) catch Class:Reason -> {Class, Reason} end}
                        || #{id := Id} = Pin <- Pins],
             ?assertEqual([], [Result || {_Id, Got} = Result <- Results, Got =/= ok])
     end}.

read_image(#{id := Id} = Pin) ->
    {ok, Image} = erx_f2fs_corpus:image(Pin, erx_f2fs_corpus:fetched(os:getenv("ERX_F2FS_CORPUS"), Pin)),
    {ok, #{feature := Features, segs_per_sec := SegsPerSec}, [_ | _]} = erx_f2fs_corpus:metadata(Image),
    {Features, SegsPerSec} = expected(Id),
    ok.

%%% Damaged and hostile files, against pins of small images made here

pin(Form, Image) ->
    #{id => "f2fs-hostile", form => Form, filename => "hostile", bytes => byte_size(Image),
      sha256 => binary:encode_hex(crypto:hash(sha256, Image), lowercase)}.

scratch(Name, Bytes) ->
    Path = filename:absname(Name ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:write_file(Path, Bytes),
    Path.

image(Form, Image, Name, File) ->
    erx_f2fs_corpus:image(pin(Form, Image), scratch(Name, File)).

program(Compressed) ->
    <<"syz_mount_image$f2fs(&AUTO='f2fs\\x00', &AUTO=\"$", (base64:encode(Compressed))/binary, "\")\n">>.

zstd(Image) ->
    base64:encode(iolist_to_binary(zstd:compress(Image))).

the_pinned_image_decodes_from_either_form_test() ->
    Image = crypto:strong_rand_bytes(8192),
    ?assertEqual({ok, Image}, image(syzkaller, Image, "zlib", program(zlib:compress(Image)))),
    ?assertEqual({ok, Image}, image(fuchsia, Image, "zstd", zstd(Image))).

%% A stream that decompresses past the image's pinned size stops there:
%% 2 MiB of zeros against a 1 MiB pin, in each form.
a_stream_past_its_image_stops_at_the_pin_test() ->
    Pinned = binary:copy(<<0>>, 1 bsl 20),
    Bomb = binary:copy(<<0>>, 2 bsl 20),
    ?assertEqual({error, too_large}, image(syzkaller, Pinned, "zlib-bomb", program(zlib:compress(Bomb)))),
    ?assertEqual({error, too_large}, image(fuchsia, Pinned, "zstd-bomb", zstd(Bomb))).

%% An image of the pinned size but other bytes is refused by its SHA-256.
other_bytes_of_the_pinned_size_are_refused_test() ->
    Pinned = binary:copy(<<0>>, 4096),
    Other = binary:copy(<<1>>, 4096),
    ?assertEqual({error, sha256}, image(syzkaller, Pinned, "other", program(zlib:compress(Other)))),
    ?assertEqual({error, sha256}, image(fuchsia, Pinned, "other", zstd(Other))).

%% A stream cut short decodes to fewer bytes than the pin, in each form.
a_truncated_stream_is_refused_test() ->
    Image = crypto:strong_rand_bytes(8192),
    Cut = fun(Bytes) -> binary:part(Bytes, 0, byte_size(Bytes) div 2) end,
    Zstd = iolist_to_binary(zstd:compress(Image)),
    ?assertEqual({error, size}, image(syzkaller, Image, "cut", program(Cut(zlib:compress(Image))))),
    ?assertEqual({error, size}, image(fuchsia, Image, "cut", base64:encode(Cut(Zstd)))).

a_damaged_stream_is_refused_test() ->
    Image = <<"image">>,
    ?assertMatch({error, {zlib, _}}, image(syzkaller, Image, "damaged", program(<<"not zlib at all">>))),
    ?assertMatch({error, {zstd, _}}, image(fuchsia, Image, "damaged", base64:encode(<<"not zstd at all">>))).

%% A zlib stream that asks for a preset dictionary names that.
a_stream_wanting_a_dictionary_is_refused_test() ->
    Image = <<"image">>,
    Z = zlib:open(),
    ok = zlib:deflateInit(Z),
    _ = zlib:deflateSetDictionary(Z, <<"dictionary">>),
    Compressed = iolist_to_binary(zlib:deflate(Z, Image, finish)),
    zlib:close(Z),
    ?assertEqual({error, need_dictionary}, image(syzkaller, Image, "dictionary", program(Compressed))).

a_file_past_its_bound_is_refused_test() ->
    Big = binary:copy(<<"A">>, (1 bsl 20) + 1),
    ?assertEqual({error, file_too_large}, image(syzkaller, <<"image">>, "big", Big)).

an_empty_file_is_refused_test() ->
    ?assertEqual({error, empty_file}, image(syzkaller, <<"image">>, "empty", <<>>)),
    ?assertEqual({error, empty_file}, image(fuchsia, <<"image">>, "empty", <<>>)).

base64_garbage_is_refused_test() ->
    ?assertEqual({error, base64}, image(syzkaller, <<"image">>, "garbage", <<"\"$%%%%\"">>)),
    ?assertEqual({error, base64}, image(fuchsia, <<"image">>, "garbage", <<"%%%%">>)).

a_program_with_two_images_is_refused_test() ->
    Two = <<"\"$AAAA\" \"$AAAA\"">>,
    ?assertEqual({error, image_string}, image(syzkaller, <<"image">>, "two", Two)).
