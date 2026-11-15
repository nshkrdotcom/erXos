%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_header_fuzz).
-moduledoc """
The fuzz target of the package decoder, `erx_pkg_header` (driven by
tools/fuzz/erx_pkg_header.rb). It decodes well-formed package files, then
mutations of them: bytes of the header and the padding replaced, words of
the header's fixed part set to edge values, the file's length moved by a
byte, a block, at random or past the largest package, and the bytes read
cut short. Every input must answer `{ok, _}` or
`{error, _}` without a crash, `layout/2` must agree with `decode/2`, and an
accepted file must have the shape the decoder promises: zero padding to the
image's block boundary, a tree as long as `erx_verity_tree` gives for the
image, and a file that ends where the tree does. A broken property halts
with `fuzz failure: NAME`.
""".

-export([run/1]).

-include("generated/erx_abi.hrl").

-define(INPUTS, 20000).
-define(BLOCK, ?ERX_EROFS_BLOCK_SIZE).

-doc "Run the target with the seed given as a decimal string.".
-spec run([string()]) -> no_return().
run([Seed]) ->
    rand:seed(exsss, {list_to_integer(Seed), 17, 29}),
    Directory = os:getenv("ERX_PKG_SEEDS"),
    {ok, Names} = file:consult(filename:join(Directory, "seeds.term")),
    Seeds = [{Length, read(Directory, Name)} || {Name, Length} <- Names],
    lists:foreach(fun({Length, Bytes}) ->
        case check(Length, Bytes) of
            accepted -> ok;
            refused -> fail(seed)
        end
    end, Seeds),
    Accepted = lists:foldl(fun(_, Count) ->
        {Length, Bytes} = mutate(lists:nth(rand:uniform(length(Seeds)), Seeds)),
        case check(Length, Bytes) of
            accepted -> Count + 1;
            refused -> Count
        end
    end, 0, lists:seq(1, ?INPUTS)),
    io:format("fuzz: ~b inputs ok, ~b accepted~n", [?INPUTS, Accepted]),
    halt(0).

read(Directory, Name) ->
    {ok, Bytes} = file:read_file(filename:join(Directory, Name)),
    Bytes.

check(Length, Bytes) ->
    Decoded = try
        erx_pkg_header:decode(Length, Bytes)
    catch
        Class:Reason:Stack ->
            io:format("~p:~p~n~p~n", [Class, Reason, Stack]),
            fail(crash)
    end,
    Layout = erx_pkg_header:layout(Length, Bytes),
    case Decoded of
        {ok, #{header_length := HeaderLength, layout := Found}} ->
            Layout =:= {ok, Found} orelse fail(layout),
            accepted(Length, Bytes, HeaderLength, Found),
            accepted;
        {error, _} ->
            Layout =:= Decoded orelse fail(layout),
            refused
    end.

accepted(Length, Bytes, HeaderLength,
         #{image_offset := ImageOffset, image_length := ImageLength,
           tree_offset := TreeOffset, tree_length := TreeLength}) ->
    (ImageOffset rem ?BLOCK =:= 0 andalso ImageOffset >= HeaderLength andalso
     ImageOffset - HeaderLength < ?BLOCK) orelse fail(boundary),
    Padding = binary:part(Bytes, HeaderLength, ImageOffset - HeaderLength),
    Padding =:= <<0:(byte_size(Padding) * 8)>> orelse fail(padding),
    TreeLength =:= erx_verity_tree:blocks(ImageLength div ?BLOCK) * ?BLOCK
        orelse fail(tree),
    (TreeOffset =:= ImageOffset + ImageLength andalso
     TreeOffset + TreeLength =:= Length) orelse fail(length).

%% One to three mutations of a seed, its first bytes kept min(Length,
%% ERX_PKG_HEADER_MAX) long.
mutate({Length, Bytes}) ->
    lists:foldl(fun(_, Input) -> mutation(rand:uniform(4), Input) end,
                {Length, Bytes}, lists:seq(1, rand:uniform(3))).

mutation(1, {Length, Bytes}) when byte_size(Bytes) > 0 ->
    Offset = rand:uniform(min(byte_size(Bytes), 2 * ?BLOCK)) - 1,
    {Length, replace(Bytes, Offset, <<(rand:uniform(256) - 1)>>)};
mutation(2, {Length, Bytes}) when byte_size(Bytes) >= ?ERX_PKG_HEADER_SIZE ->
    Offset = 4 * (rand:uniform(?ERX_PKG_HEADER_SIZE div 4) - 1),
    <<Old:32/little>> = binary:part(Bytes, Offset, 4),
    Values = [0, 1, 16#ffffffff, (Old + 1) band 16#ffffffff,
              (Old - 1) band 16#ffffffff],
    Value = lists:nth(rand:uniform(length(Values)), Values),
    {Length, replace(Bytes, Offset, <<Value:32/little>>)};
mutation(Kind, Input) when Kind =< 2 ->
    Input;
mutation(3, {Length, Bytes}) ->
    Moves = [Length + 1, Length - 1, Length + ?BLOCK, Length - ?BLOCK,
             rand:uniform(2 * Length + 1) - 1, ?ERX_PKG_BYTES_MAX + 1],
    resize(max(0, lists:nth(rand:uniform(length(Moves)), Moves)), Bytes);
mutation(4, {Length, Bytes}) ->
    {Length, binary:part(Bytes, 0, rand:uniform(byte_size(Bytes) + 1) - 1)}.

replace(Bytes, Offset, New) ->
    <<Before:Offset/binary, _:(byte_size(New))/binary, After/binary>> = Bytes,
    <<Before/binary, New/binary, After/binary>>.

resize(Length, Bytes) ->
    Size = min(Length, ?ERX_PKG_HEADER_MAX),
    Kept = binary:part(Bytes, 0, min(Size, byte_size(Bytes))),
    {Length, <<Kept/binary, 0:((Size - byte_size(Kept)) * 8)>>}.

fail(Name) ->
    io:format("fuzz failure: ~s~n", [Name]),
    halt(1).
