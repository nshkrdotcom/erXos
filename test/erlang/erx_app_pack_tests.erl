%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app_pack_tests).
-moduledoc """
EUnit cases of the packages the packer, `erx-app pack`, writes. The
packages come from test/host/erx_pkg_header_test.rb, which packs its sample
apps into the directory `ERX_PKG_CASES` names, each as NAME.app, and lists
them in packed.term as `{File, Fields}`, Fields the header fields the
decoder must give, the signer's key among them; other_key.bin is a key
that signed none of them.

Each package is judged whole, as a machine judges one: the file check,
`erx_pkg_header:check_file/2`, with the packer's key a trusted signer,
which runs the decoder and verifies the Ed25519 seal over every byte of
the header before the signature; and the hash tree, recomputed from the
image level by level with the level lengths `erx_verity_tree:levels/1`
gives, which must be the file's tree, top level first, and hash to the
header's root hash. One byte flipped in the header, the image or the tree
must fail that judgement. The file check also gives each of its
refusals: a key no trusted signer holds, a flipped signature byte, a name
not the app's, a file a byte long or short, and under `{hash, H}` a
header whose SHA-256 is not H; and it accepts the package under its own
hash without reading the seal.
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(BLOCK, ?ERX_EROFS_BLOCK_SIZE).

packed_test_() ->
    Directory = os:getenv("ERX_PKG_CASES"),
    {ok, Cases} = file:consult(filename:join(Directory, "packed.term")),
    {ok, Other} = file:read_file(filename:join(Directory, "other_key.bin")),
    [{Name, fun() -> check_package(Directory, Name, Fields, Other) end}
     || {Name, Fields} <- Cases].

check_package(Directory, Name, #{key := Key} = Fields, Other) ->
    {ok, File} = file:read_file(filename:join(Directory, Name)),
    Trusted = {signers, [{<<"other">>, Other}, {<<"test">>, Key}]},
    {ok, #{header := Header, signer := Signer, sha256 := Sha256}} = check(Name, File, Trusted),
    ?assertEqual(Fields, maps:with(maps:keys(Fields), Header)),
    ?assertEqual(<<"test">>, Signer),
    ?assertEqual(ok, judge(Name, File, Trusted)),
    check_refusals(Name, File, Header, Sha256, Other),
    #{header_length := HeaderLength,
      layout := #{image_offset := Image, image_length := ImageLength,
                  tree_offset := Tree, tree_length := TreeLength}} = Header,
    Header0 = [20, HeaderLength - ?ERX_PKG_SIGNATURE_SIZE - 1, HeaderLength - 1],
    Image0 = [Image, Image + ImageLength - 1],
    Tree0 = [Offset || TreeLength > 0, Offset <- [Tree, Tree + TreeLength - 1]],
    ?assertNotEqual([], Tree0),
    [?assertNotEqual({Offset, ok}, {Offset, judge(Name, flip(File, Offset), Trusted)})
     || Offset <- Header0 ++ Image0 ++ Tree0].

check_refusals(Name, File, #{name := App, key := Key, header_length := HeaderLength} = Header,
               Sha256, Other) ->
    Trusted = {signers, [{<<"test">>, Key}]},
    Length = byte_size(File),
    ?assertEqual({error, {untrusted, signer}}, check(Name, File, {signers, [{<<"other">>, Other}]})),
    ?assertEqual({error, {untrusted, signer}}, check(Name, File, {signers, []})),
    ?assertEqual({error, {untrusted, signature}}, check(Name, flip(File, HeaderLength - 1), Trusted)),
    ?assertEqual({error, {name, <<"other.app">>, App}}, check("other.app", File, Trusted)),
    ?assertEqual({error, {length, Length + 1, Length}}, check(Name, <<File/binary, 0>>, Trusted)),
    ?assertEqual({error, {length, Length - 1, Length}},
                 check(Name, binary:part(File, 0, Length - 1), Trusted)),
    ?assertEqual(crypto:hash(sha256, binary:part(File, 0, HeaderLength)), Sha256),
    ?assertMatch({ok, #{header := Header, sha256 := Sha256, signer := image}},
                 check(Name, File, {hash, Sha256})),
    ?assertEqual({error, {untrusted, hash}}, check(Name, File, {hash, flip(Sha256, 31)})).

%% ok, or the first part of the file that fails.
judge(Name, File, Trusted) ->
    maybe
        {ok, #{header := #{layout := Layout}}} ?= check(Name, File, Trusted),
        verified(File, Layout)
    end.

%% The file check of File under Name, given the bytes a read of its first
%% ERX_PKG_HEADER_MAX bytes gets.
check(Name, File, Authority) ->
    erx_pkg_header:check_file({list_to_binary(Name), byte_size(File), header_bytes(File)}, Authority).

header_bytes(File) ->
    binary:part(File, 0, min(byte_size(File), ?ERX_PKG_HEADER_MAX)).

verified(File, #{image_offset := Offset, image_length := Length, tree_offset := TreeOffset,
                 tree_length := TreeLength, salt := Salt, root_hash := Root}) ->
    Image = binary:part(File, Offset, Length),
    Levels = levels(Image, Salt, erx_verity_tree:levels(Length div ?BLOCK)),
    Top = case Levels of
              [] -> Image;
              _ -> lists:last(Levels)
          end,
    Tree = iolist_to_binary(lists:reverse(Levels)),
    case {Tree =:= binary:part(File, TreeOffset, TreeLength), crypto:hash(sha256, [Salt, Top])} of
        {true, Root} -> ok;
        _ -> {error, tree}
    end.

%% The levels over Data, lowest first, each the salted hash of each block of the one below
%% zero-filled to the blocks the layout gives it.
levels(_Data, _Salt, []) ->
    [];
levels(Data, Salt, [Blocks | Rest]) ->
    Hashes = << <<(crypto:hash(sha256, [Salt, Block]))/binary>> || <<Block:?BLOCK/binary>> <= Data >>,
    Level = <<Hashes/binary, 0:((Blocks * ?BLOCK - byte_size(Hashes)) * 8)>>,
    [Level | levels(Level, Salt, Rest)].

flip(File, Offset) ->
    <<Before:Offset/binary, Byte, After/binary>> = File,
    <<Before/binary, (Byte bxor 16#01), After/binary>>.
