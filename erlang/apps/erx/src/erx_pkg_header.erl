%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_header).
-moduledoc """
The one parser of an app package file's structure
(docs/design-packaging.md, "The package"), whatever the file's origin and
whoever authenticated it. A package is a header, the app's EROFS image and
the image's hash tree, each from an EROFS block boundary, as
`abi/formats/package.txt` lays them.

`decode/2` takes the file's length and its first bytes, as many as the
file has up to `ERX_PKG_HEADER_MAX`. It reads the header through the
generated reader, `erx_pkg_reader`, and then checks that the padding after
the header is zero and that the image and the tree lie end to end to the
file's end, the tree as long as `erx_verity_tree` gives for the image. The
file's bytes are untrusted: every length is checked before it is used, and
the first failure is the answer. `layout/2` is the decoder's layout alone.
""".

-export([decode/2, layout/2]).
-export_type([decoded/0, layout/0, reason/0]).

-include("generated/erx_abi.hrl").

-define(BLOCK, ?ERX_EROFS_BLOCK_SIZE).

%% A file at least as long as the block boundary after its header has that
%% boundary within the bytes the decoder reads.
-if(?ERX_PKG_HEADER_MAX rem ?BLOCK =/= 0).
-error("pkg_header_max is not a multiple of the EROFS block size").
-endif.

-doc "Where a package's image and hash tree lie in its file, in bytes.".
-type layout() :: #{image_offset := non_neg_integer(),
                    image_length := pos_integer(),
                    tree_offset := non_neg_integer(),
                    tree_length := non_neg_integer(),
                    salt := binary(),
                    root_hash := binary()}.

-doc """
A decoded header: the packed declaration, the build's ABI version and
architecture, the seal and the header's length, and the image's layout.
""".
-type decoded() :: #{name := binary(),
                     abi_version := non_neg_integer(),
                     arch := binary(),
                     version := pos_integer(),
                     memory := non_neg_integer(),
                     needs := [binary()],
                     start := {applications, [binary(), ...]}
                            | {program, binary(), [binary()]},
                     license := binary(),
                     key := binary(),
                     signature := binary(),
                     header_length := pos_integer(),
                     layout := layout()}.

-doc """
Why a file is not a package: longer than `ERX_PKG_BYTES_MAX`; a header the
reader refuses; fewer bytes read than the decoder reads, or a file cut short
of the header's block boundary (`short`); padding not zero; a tree length
that is not the image's; or a file that does not end where the tree does.
""".
-type reason() :: {too_large, non_neg_integer()}
                | {header, erx_pkg_reader:error() | short | padding
                         | {tree, non_neg_integer(), non_neg_integer()}}
                | {length, non_neg_integer(), pos_integer()}.

-doc """
Decode the package file of `Length` bytes whose first bytes are `Bytes`.
The decoder reads a copy of `min(Length, ERX_PKG_HEADER_MAX)` of them, and
refuses fewer, as a read cut short gives, with `{header, short}`.
""".
-spec decode(non_neg_integer(), binary()) ->
    {ok, decoded()} | {error, reason()}.
decode(Length, Bytes)
  when is_integer(Length), Length >= 0, is_binary(Bytes) ->
    try
        {ok, decode_file(Length, Bytes)}
    catch
        throw:{?MODULE, Reason} -> {error, Reason}
    end.

-doc "The layout `decode/2` finds, after all of its checks.".
-spec layout(non_neg_integer(), binary()) ->
    {ok, layout()} | {error, reason()}.
layout(Length, Bytes) ->
    case decode(Length, Bytes) of
        {ok, #{layout := Layout}} -> {ok, Layout};
        {error, _} = Error -> Error
    end.

decode_file(Length, Read) ->
    check(Length =< ?ERX_PKG_BYTES_MAX, {too_large, Length}),
    Want = min(Length, ?ERX_PKG_HEADER_MAX),
    check(byte_size(Read) >= Want, {header, short}),
    %% A copy, so a decoded string never keeps a longer read alive.
    Bytes = binary:copy(binary:part(Read, 0, Want)),
    View = header_view(Bytes),
    #{header_length := HeaderLength, image_blocks := ImageBlocks,
      tree_blocks := TreeBlocks, salt := Salt, root_hash := RootHash} =
        Header = reader_answer(erx_pkg_reader:header(View)),
    ImageOffset = block_boundary(HeaderLength),
    check(ImageOffset =< byte_size(Bytes), {header, short}),
    Padding = binary:part(Bytes, HeaderLength, ImageOffset - HeaderLength),
    check(Padding =:= <<0:(byte_size(Padding) * 8)>>, {header, padding}),
    WantTree = erx_verity_tree:blocks(ImageBlocks),
    check(TreeBlocks =:= WantTree, {header, {tree, TreeBlocks, WantTree}}),
    TreeOffset = ImageOffset + ImageBlocks * ?BLOCK,
    End = TreeOffset + TreeBlocks * ?BLOCK,
    check(Length =:= End, {length, Length, End}),
    Layout = #{image_offset => ImageOffset,
               image_length => ImageBlocks * ?BLOCK,
               tree_offset => TreeOffset,
               tree_length => TreeBlocks * ?BLOCK,
               salt => Salt,
               root_hash => RootHash},
    declaration(View, Header, Layout).

%% The header is the first header_length bytes, which the generated reader
%% finds from the header's own length field and checks whole.
header_view(Bytes) ->
    reader_answer(erx_pkg_reader:open_prefix(Bytes)).

declaration(View, Header, Layout) ->
    #{key := Key, signature := Signature} =
        reader_answer(erx_pkg_reader:fetch(View, seal, 0)),
    #{name := Name, arch := Arch, license := License} = Header,
    #{name => string(View, Name),
      abi_version => maps:get(abi_version, Header),
      arch => string(View, Arch),
      version => maps:get(app_version, Header),
      memory => maps:get(memory, Header),
      needs => strings(View, needs),
      start => start(View, Header),
      license => string(View, License),
      key => Key,
      signature => Signature,
      header_length => maps:get(header_length, Header),
      layout => Layout}.

start(View, #{kind := ?ERX_PKG_ERLANG}) ->
    {applications, strings(View, applications)};
start(View, #{kind := ?ERX_PKG_NATIVE, program := Program, args := Args}) ->
    {program, string(View, Program), arguments(string(View, Args))}.

%% The arguments are NUL-terminated strings, which the reader checked.
arguments(Bytes) ->
    lists:droplast(binary:split(Bytes, <<0>>, [global])).

strings(View, Table) ->
    Reversed = reader_answer(erx_pkg_reader:fold(View, Table,
        fun(Reference, Acc) -> [string(View, Reference) | Acc] end, [])),
    lists:reverse(Reversed).

string(View, Reference) ->
    reader_answer(erx_pkg_reader:string(View, Reference)).

block_boundary(Offset) ->
    (Offset + ?BLOCK - 1) div ?BLOCK * ?BLOCK.

%% The generated reader's answer, or its refusal as the decoder's.
reader_answer({ok, Value}) -> Value;
reader_answer({error, Reason}) -> throw({?MODULE, {header, Reason}}).

check(true, _Reason) -> ok;
check(false, Reason) -> throw({?MODULE, Reason}).
