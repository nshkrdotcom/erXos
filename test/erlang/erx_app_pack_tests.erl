%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app_pack_tests).
-moduledoc """
EUnit cases of the packages the packer, `erx-app pack`, writes. The
packages come from test/host/erx_pkg_header_test.rb, which packs its sample
apps into the directory `ERX_PKG_CASES` names, each as NAME.app, and lists
them in packed.term as `{File, Fields}`, Fields the header fields the
decoder must give.

Each package is judged whole, as a machine judges one: the decoder,
`erx_pkg_header:decode/2`; the Ed25519 signature over every byte of the
header before it, by the key the header carries; and the hash tree,
recomputed from the image level by level with the level lengths
`erx_verity_tree:levels/1` gives, which must be the file's tree, top level
first, and hash to the header's root hash. One byte flipped in the
header, the image or the tree must fail that judgement.
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(BLOCK, ?ERX_EROFS_BLOCK_SIZE).

packed_test_() ->
    Directory = os:getenv("ERX_PKG_CASES"),
    {ok, Cases} = file:consult(filename:join(Directory, "packed.term")),
    [{Name, fun() -> check_package(filename:join(Directory, Name), Fields) end}
     || {Name, Fields} <- Cases].

check_package(Path, Fields) ->
    {ok, File} = file:read_file(Path),
    {ok, Header} = decode(File),
    ?assertEqual(Fields, maps:with(maps:keys(Fields), Header)),
    ?assertEqual(ok, judge(File)),
    #{header_length := HeaderLength,
      layout := #{image_offset := Image, image_length := ImageLength,
                  tree_offset := Tree, tree_length := TreeLength}} = Header,
    Header0 = [20, HeaderLength - ?ERX_PKG_SIGNATURE_SIZE - 1, HeaderLength - 1],
    Image0 = [Image, Image + ImageLength - 1],
    Tree0 = [Offset || TreeLength > 0, Offset <- [Tree, Tree + TreeLength - 1]],
    ?assertNotEqual([], Tree0),
    [?assertNotEqual({Offset, ok}, {Offset, judge(flip(File, Offset))})
     || Offset <- Header0 ++ Image0 ++ Tree0].

%% ok, or the first part of the file that fails.
judge(File) ->
    maybe
        {ok, Header} ?= decode(File),
        ok ?= signed(File, Header),
        verified(File, maps:get(layout, Header))
    end.

decode(File) ->
    erx_pkg_header:decode(byte_size(File),
                          binary:part(File, 0, min(byte_size(File), ?ERX_PKG_HEADER_MAX))).

signed(File, #{header_length := Length, key := Key, signature := Signature}) ->
    Signed = binary:part(File, 0, Length - byte_size(Signature)),
    case crypto:verify(eddsa, none, Signed, Signature, [Key, ed25519]) of
        true -> ok;
        false -> {error, signature}
    end.

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
