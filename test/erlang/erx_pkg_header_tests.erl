%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_header_tests).
-moduledoc """
EUnit cases of the package decoder, `erx_pkg_header`, and of the hash
tree's layout, `erx_verity_tree`. The package files come from
test/host/erx_pkg_header_test.rb, which writes them through the ABI codec
into the directory `ERX_PKG_CASES` names: each case's first bytes in
NAME.bin, and cases.term, `{Name, Length, Expected}` for each, where
`{refused, Reason}` in place of a reader error matches the reader's reason.
Each case is decoded through both entries, `decode/2` and `layout/2`.
""".

-include_lib("eunit/include/eunit.hrl").

decoder_test_() ->
    Directory = os:getenv("ERX_PKG_CASES"),
    {ok, Cases} = file:consult(filename:join(Directory, "cases.term")),
    [{Name, fun() -> check_case(Directory, Name, Length, Expected) end}
     || {Name, Length, Expected} <- Cases].

check_case(Directory, Name, Length, Expected) ->
    {ok, Bytes} = file:read_file(filename:join(Directory, Name ++ ".bin")),
    Decoded = erx_pkg_header:decode(Length, Bytes),
    Layout = erx_pkg_header:layout(Length, Bytes),
    case Expected of
        {ok, Header} ->
            ?assertEqual({ok, Header}, Decoded),
            ?assertEqual({ok, maps:get(layout, Header)}, Layout);
        {error, {header, {refused, Reason}}} ->
            ?assertMatch({error, {header, #{reason := Reason}}}, Decoded),
            ?assertEqual(Decoded, Layout);
        {error, _} ->
            ?assertEqual(Expected, Decoded),
            ?assertEqual(Expected, Layout)
    end.

%% A block holds 128 SHA-256 hashes, so the levels over N blocks take
%% ceil(N / 128) blocks, then ceil of that over 128, up to one block.
tree_blocks_test_() ->
    [?_assertEqual(Want, erx_verity_tree:blocks(Image))
     || {Image, Want} <- [{1, 1}, {128, 1}, {129, 3}, {16384, 129},
                          {16385, 132}, {16#ffffffff, 33818641}]].

tree_levels_test_() ->
    [?_assertEqual(Want, erx_verity_tree:levels(Image))
     || {Image, Want} <- [{1, [1]}, {129, [2, 1]}, {16385, [129, 2, 1]},
                          {16#ffffffff, [33554432, 262144, 2048, 16, 1]}]].
