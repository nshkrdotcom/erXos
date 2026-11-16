%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_corpus).
-moduledoc """
The fixed F2FS corpora's images, decoded from the files the fetch step
provides (docs/design-f2fs.md, "Corpora"). deps.lock pins each file by its
URL and SHA-256 and the fetch step checks it; what a file encodes is pinned
here, since deps.lock has no field for it: each image's form, its size and
the SHA-256 of its decoded bytes, which image/2 checks before it answers.

syzkaller's seeds are test programs that hold one image as a string
"$" and base64 of zlib; Fuchsia's image is base64 of zstd, as its host
serves the file's text. A file is read only up to the bound of its form,
and decompression stops at the pinned size of the image, so a damaged or
hostile file costs at most the encoded file and twice the image it claims
to be (its chunks and their concatenation).
""".

-export([ids/0, filename/1, image/2]).

-define(PROGRAM_BYTES, 1 bsl 20).
-define(ENCODED_BYTES, 32 bsl 20).

-doc "The corpus images, by their deps.lock source ids.".
-spec ids() -> [string()].
ids() ->
    [Id || {Id, _Form, _Filename, _Bytes, _Sha256} <- images()].

-doc "The name of the file the fetch step provides for Id.".
-spec filename(string()) -> string().
filename(Id) ->
    {Id, _Form, Filename, _Bytes, _Sha256} = lists:keyfind(Id, 1, images()),
    Filename.

-doc """
Id's image, decoded from File, the file the fetch step provided for it:
{error, Reason} when File is too large for its form, does not decode, or
decodes to bytes other than the pinned image's.
""".
-spec image(string(), file:filename_all()) -> {ok, binary()} | {error, term()}.
image(Id, File) ->
    {Id, Form, _Filename, Bytes, Sha256} = lists:keyfind(Id, 1, images()),
    try
        Image = decode(Form, read(File, encoded_bound(Form)), Bytes),
        require(byte_size(Image) =:= Bytes, size),
        require(binary:encode_hex(crypto:hash(sha256, Image), lowercase) =:= Sha256, sha256),
        {ok, Image}
    catch
        throw:{corpus, Reason} -> {error, Reason}
    end.

%% Each image: its source id, its form, the fetched file's name, and the
%% decoded image's size and SHA-256, from the probe record
%% ~/erxos-scratch/notes/probe-f2fs-host-2026-11-14 (syz.log and README.md).
images() ->
    Syzkaller =
        [{"f2fs-syzkaller-0", 64, "3f7ecd4766ea96e477cca4504d0837cd9399c4226a049ef9bc451f296fca7e9c"},
         {"f2fs-syzkaller-1", 64, "f72171a74897f1f4e529bb6278db6c0ff7157f474762e2c9f826e09a5eaea4d9"},
         {"f2fs-syzkaller-2", 64, "87358092f9a7c5f270e8fc47590bdc6619702bcaedf1c3ef3f664bea207d30d4"},
         {"f2fs-syzkaller-3", 64, "d4c691f6aaa3a41334b4561f8ffa413ed08052b475972f587fba702d65fbd137"},
         {"f2fs-syzkaller-4", 128, "419896638cc383124d1345db90c32608eb09f70bd7645a5b6ea2c71593b3837c"},
         {"f2fs-syzkaller-5", 128, "05514bf304d5a7a1d44cdd8c4324bc9b6466fe198d226648da8ccabf63197434"},
         {"f2fs-syzkaller-6", 128, "e91fc5d1e522e1a3057f6fa16785107c8c767a0681eff5988f853484b81dd086"},
         {"f2fs-syzkaller-7", 128, "bd0b0b037bbba0eb2d07ea74b60e6eb9bdf261e28c8e487d75fec44e9aba3d48"},
         {"f2fs-syzkaller-8", 64, "6d7c9704c4b464b8f688a907b81f05ad6c6f534582e0512a1f5b8422f853c85e"},
         {"f2fs-syzkaller-9", 64, "f5a57586fe471bd93d21b8562caaba628852a8165bd2a128ca367f66d359bd96"},
         {"f2fs-syzkaller-10", 64, "af87766de1938100060da4ff8628c6c0d69831d48d92af6b738d881c31de9d6e"},
         {"f2fs-syzkaller-11", 64, "d7c503e8ecdd9b132126ec4668e95d1f4536f22562c19a6fdd7e1e8fe6136a2f"},
         {"f2fs-syzkaller-12", 128, "2ee4c85d28a01fc9d2f32a2ef460f97f7c2dcbedc110cdb4782e8792c7968b6e"},
         {"f2fs-syzkaller-13", 128, "35d65f1a80f81d2bbcd83498046b1dec07eb450cd69821d0439d0922078100da"},
         {"f2fs-syzkaller-14", 128, "5713f77b24e2f619ad8b28de9ea45d782677b309a07385c42c6fa9e4915fd904"},
         {"f2fs-syzkaller-15", 128, "fbee17f534347ffac6da9a1cd7db2a9609a5c202e38a731faf0cdfada7dfbfc2"},
         {"f2fs-syzkaller-fscrypt", 64, "7d3a1f50b756cb1cd9ae52074a08f6125b226085b0d49ef944ba535fd57cdf24"}],
    [{Id, syzkaller, program_name(Id), MiB bsl 20, list_to_binary(Sha256)}
     || {Id, MiB, Sha256} <- Syzkaller]
    ++ [{"f2fs-fuchsia", fuchsia, "f2fs.img.zst.base64", 256 bsl 20,
         <<"213eaecd0f05af7755203ccc9a45694fe19c1607ed30b9494f0679214a5fcfe6">>}].

program_name("f2fs-syzkaller-fscrypt") -> "fscrypt_f2fs";
program_name("f2fs-syzkaller-" ++ N) -> "syz_mount_image_f2fs_" ++ N.

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

%% zlib's and zstd's streams yield their output a bounded chunk at a time;
%% each chunk is counted against Limit before the next is asked for.
inflate(Compressed, Limit) ->
    Z = zlib:open(),
    try
        ok = zlib:inflateInit(Z),
        collect(fun(none) -> zlib:safeInflate(Z, Compressed);
                   (continue) -> zlib:safeInflate(Z, [])
                end, Limit)
    catch error:Reason -> fail({zlib, Reason})
    after
        zlib:close(Z)
    end.

unzstd(Compressed, Limit) ->
    {ok, Context} = zstd:context(decompress),
    try
        collect(fun(none) -> zstd_step(zstd:stream(Context, Compressed));
                   ({more, Remainder}) -> zstd_step(zstd:stream(Context, Remainder))
                end, Limit)
    catch error:Reason -> fail({zstd, Reason})
    after
        zstd:close(Context)
    end.

%% zstd answers a remainder while it has input left; once the input is
%% spent it may still hold output, so it is asked again with none until it
%% answers no more.
zstd_step({continue, Remainder, Output}) -> {{more, Remainder}, Output};
zstd_step({continue, <<>>}) -> {finished, <<>>};
zstd_step({continue, Output}) -> {{more, <<>>}, Output}.

%% Runs Step until it finishes, keeping its output while the total stays
%% within Limit. A step answers {continue, Output} or {finished, Output}
%% (zlib's form), or {Next, Output} where Next is passed back.
collect(Step, Limit) ->
    collect(Step, Step(none), Limit, 0, []).

collect(Step, {Next, Output}, Limit, Total, Chunks) ->
    Size = Total + iolist_size(Output),
    require(Size =< Limit, too_large),
    case Next of
        finished -> iolist_to_binary(lists:reverse([Output | Chunks]));
        _ -> collect(Step, Step(Next), Limit, Size, [Output | Chunks])
    end.

require(true, _Reason) -> ok;
require(false, Reason) -> fail(Reason).

fail(Reason) ->
    throw({corpus, Reason}).
