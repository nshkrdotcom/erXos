%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_corpus).
-moduledoc """
The fixed F2FS corpora's images, decoded from the files the fetch step
provides (docs/design-f2fs.md, "Corpora"). Each is a file source in
deps.lock, which pins the file by its URL and SHA-256 for the fetch step
and the image it encodes by decoded_sha256 and decoded_bytes, which
image/2 checks before it answers; the schema in
tools/lib/erx/dependencies.rb validates every row.

syzkaller's seeds are test programs that hold one image as a string
"$" and base64 of zlib; Fuchsia's image is base64 of zstd, as its host
serves the file's text. A file is read only up to the bound of its form,
and decompression stops at the pinned size of the image, so a damaged or
hostile file costs at most the encoded file and its base64-decoded copy,
twice the image it claims to be (its chunks and their concatenation), and
for the zstd form the window its frame declares, which zstd caps at
128 MiB.
""".

-export([pins/1, fetched/2, image/2, metadata/1]).
-export_type([pin/0]).

-define(PROGRAM_BYTES, 1 bsl 20).
-define(ENCODED_BYTES, 32 bsl 20).
-define(BLOCK, 4096).
-define(BLOCKS_PER_SEG, 512).

-doc """
A corpus image's pin: its deps.lock source id, the form of the file that
encodes it, the file's name, and the decoded image's size and SHA-256 (hex).
""".
-type pin() :: #{id := string(), form := syzkaller | fuchsia, filename := string(),
                 bytes := pos_integer(), sha256 := binary()}.

-doc """
The F2FS corpus images that deps.lock, at Lock, pins, in its order: every
source whose id starts with "f2fs-", each of which must pin its decoded
image. The caller has validated deps.lock with the schema
(Erx::DependencySchema), the one check of its rows, which bounds
decoded_bytes.
""".
-spec pins(file:filename_all()) -> [pin()].
pins(Lock) ->
    {ok, Text} = file:read_file(Lock),
    #{<<"sources">> := Sources} = json:decode(Text),
    [pin(Source) || #{<<"id">> := <<"f2fs-", _/binary>>} = Source <- Sources].

pin(#{<<"id">> := Id, <<"filename">> := Filename,
      <<"decoded_bytes">> := Bytes, <<"decoded_sha256">> := Sha256}) ->
    #{id => binary_to_list(Id), form => form(Id), filename => binary_to_list(Filename),
      bytes => Bytes, sha256 => Sha256}.

form(<<"f2fs-fuchsia">>) -> fuchsia;
form(<<"f2fs-syzkaller-", _/binary>>) -> syzkaller.

-doc "Where the fetch step put Pin's file, under ThirdParty (build/third_party).".
-spec fetched(file:filename_all(), pin()) -> file:filename_all().
fetched(ThirdParty, #{id := Id, filename := Filename}) ->
    filename:join([ThirdParty, Id, Filename]).

-doc """
Pin's image, decoded from File: {error, Reason} when File is too large for
its form, does not decode, or decodes to bytes other than the pinned image's.
""".
-spec image(pin(), file:filename_all()) -> {ok, binary()} | {error, term()}.
image(#{form := Form, bytes := Bytes, sha256 := Sha256}, File) ->
    try
        Image = decode(Form, read(File, encoded_bound(Form)), Bytes),
        require(byte_size(Image) =:= Bytes, size),
        require(binary:encode_hex(crypto:hash(sha256, Image), lowercase) =:= Sha256, sha256),
        {ok, Image}
    catch
        throw:{corpus, Reason} -> {error, Reason}
    end.

-doc """
Image's superblock, read by erx_f2fs_codec, and the checkpoint packs of
its two that are valid, each a header block and its payload blocks: a pack
is valid when its header and copy read with the same version and the
header reads whole with its payload. {error, Reason} when the superblock
does not read, the image is shorter than the volume it describes, or
neither pack is valid.
""".
-spec metadata(binary()) ->
          {ok, erx_f2fs_codec:superblock(), [{binary(), [binary()]}]} | {error, term()}.
metadata(Image) ->
    maybe
        {ok, #{cp_blkaddr := Start, block_count := Blocks} = Super} ?=
            erx_f2fs_codec:superblock(block(Image, 0)),
        true ?= Blocks * ?BLOCK =< byte_size(Image) orelse {error, short_image},
        Packs = [Pack || Address <- [Start, Start + ?BLOCKS_PER_SEG],
                         {ok, Pack} <- [pack(Super, Image, Address)]],
        true ?= Packs =/= [] orelse {error, no_valid_pack},
        {ok, Super, Packs}
    end.

pack(#{cp_payload := PayloadBlocks} = Super, Image, Start) ->
    maybe
        {ok, #{cp_pack_total_block_count := Total, checkpoint_ver := Version}} ?=
            erx_f2fs_codec:checkpoint(block(Image, Start)),
        {ok, #{checkpoint_ver := Version}} ?=
            erx_f2fs_codec:checkpoint_copy(block(Image, Start + Total - 1)),
        Header = block(Image, Start),
        Payload = [block(Image, Start + 1 + N) || N <- lists:seq(0, PayloadBlocks - 1)],
        {ok, _} ?= erx_f2fs_codec:checkpoint(Super, Header, Payload),
        {ok, {Header, Payload}}
    end.

%% A copy, so that what metadata/1 answers does not keep the image alive.
block(Image, Address) ->
    binary:copy(binary:part(Image, Address * ?BLOCK, ?BLOCK)).

encoded_bound(syzkaller) -> ?PROGRAM_BYTES;
encoded_bound(fuchsia) -> ?ENCODED_BYTES.

%% File's bytes, refused past Bound: at most Bound + 1 bytes are read.
read(File, Bound) ->
    case file:open(File, [read, raw, binary]) of
        {ok, Device} ->
            try file:read(Device, Bound + 1) of
                {ok, Bytes} when byte_size(Bytes) =< Bound -> Bytes;
                {ok, _} -> fail(file_too_large);
                eof -> fail(empty_file);
                {error, Reason} -> fail({file, Reason})
            after
                file:close(Device)
            end;
        {error, Reason} ->
            fail({file, Reason})
    end.

%% The image a file encodes, at most Limit bytes of it.
decode(syzkaller, Program, Limit) ->
    inflate(base64(image_string(Program)), Limit);
decode(fuchsia, Text, Limit) ->
    unzstd(base64(Text), Limit).

%% The one "$..." string of a syzkaller program: its base64 text.
image_string(Program) ->
    case binary:split(Program, <<"\"$">>, [global]) of
        [_Before, After] ->
            case binary:split(After, <<"\"">>) of
                [Base64, _Rest] -> Base64;
                [_Unterminated] -> fail(image_string)
            end;
        _ -> fail(image_string)
    end.

base64(Text) ->
    try base64:decode(string:trim(Text))
    catch error:_ -> fail(base64)
    end.

%% zlib's and zstd's streams yield their output a bounded chunk at a time,
%% each step answering {more, Input, Output}, with the input to pass to the
%% next step, or {done, Output}; collect/3 counts each chunk against Limit
%% before it asks for the next.
inflate(Compressed, Limit) ->
    Z = zlib:open(),
    try
        ok = zlib:inflateInit(Z),
        collect(fun(Input) -> zlib_step(zlib:safeInflate(Z, Input)) end, Compressed, Limit)
    catch error:Reason -> fail({zlib, Reason})
    after
        zlib:close(Z)
    end.

zlib_step({continue, Output}) -> {more, [], Output};
zlib_step({finished, Output}) -> {done, Output};
zlib_step({need_dictionary, _Adler, _Output}) -> fail(need_dictionary).

unzstd(Compressed, Limit) ->
    {ok, Context} = zstd:context(decompress),
    try
        collect(fun(Input) -> zstd_step(zstd:stream(Context, Input)) end, Compressed, Limit)
    catch error:Reason -> fail({zstd, Reason})
    after
        zstd:close(Context)
    end.

%% zstd answers a remainder while it has input left; once the input is
%% spent it may still hold output, so it is asked again with none until it
%% answers no more. A truncated stream so ends short of its image.
zstd_step({continue, Remainder, Output}) -> {more, Remainder, Output};
zstd_step({continue, <<>>}) -> {done, <<>>};
zstd_step({continue, Output}) -> {more, <<>>, Output}.

collect(Step, Input, Limit) ->
    collect(Step, Input, Limit, 0, []).

collect(Step, Input, Limit, Total, Chunks) ->
    case Step(Input) of
        {more, Next, Output} ->
            collect(Step, Next, Limit, counted(Total, Output, Limit), [Output | Chunks]);
        {done, Output} ->
            counted(Total, Output, Limit),
            iolist_to_binary(lists:reverse([Output | Chunks]))
    end.

counted(Total, Output, Limit) ->
    Size = Total + iolist_size(Output),
    require(Size =< Limit, too_large),
    Size.

require(true, _Reason) -> ok;
require(false, Reason) -> fail(Reason).

fail(Reason) ->
    throw({corpus, Reason}).
