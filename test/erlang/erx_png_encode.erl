%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% A PNG writer for the tests and the fuzz target of erx_png: chunks with
%% their CRCs, and images of any colour type and bit depth whose rows are
%% filtered with the filter types the caller picks, compressed with stock
%% OTP's zlib.
-module(erx_png_encode).
-export([chunk/2, png/1, header/1, image/1, random_image/0, random_filters/1, formats/0]).

-define(SIGNATURE, <<137, $P, $N, $G, $\r, $\n, 26, $\n>>).

%% An image to write: its format, its packed rows, unfiltered, the filter
%% type of each, and the PLTE and tRNS to write, or none.
-type image() :: #{width := pos_integer(), height := pos_integer(), depth := pos_integer(),
                   colour := 0 | 2 | 3 | 4 | 6, interlace => 0 | 1, rows := [binary()],
                   filters := [0..4], palette => none | binary(), trns => none | binary()}.

chunk(Type, Data) ->
    <<(byte_size(Data)):32, Type/binary, Data/binary, (erlang:crc32([Type, Data])):32>>.

%% A signature and the chunks given, as {Type, Data}, then IEND.
png(Chunks) ->
    iolist_to_binary([?SIGNATURE, [chunk(Type, Data) || {Type, Data} <- Chunks], chunk(<<"IEND">>, <<>>)]).

header(#{width := W, height := H, depth := Depth, colour := Colour} = Image) ->
    <<W:32, H:32, Depth, Colour, 0, 0, (maps:get(interlace, Image, 0))>>.

-spec image(image()) -> binary().
image(#{rows := Rows, filters := Filters, depth := Depth, colour := Colour} = Image) ->
    Bpp = max(1, Depth * samples(Colour) div 8),
    Line = byte_size(hd(Rows)),
    {Filtered, _} = lists:mapfoldl(fun({Row, Filter}, Prior) -> {[Filter, filter(Filter, Row, Prior, Bpp)], Row} end,
                                   <<0:(Line * 8)>>, lists:zip(Rows, Filters)),
    Optional = [{<<"PLTE">>, P} || P <- [maps:get(palette, Image, none)], P =/= none] ++
               [{<<"tRNS">>, T} || T <- [maps:get(trns, Image, none)], T =/= none],
    png([{<<"IHDR">>, header(Image)}] ++ Optional ++ [{<<"IDAT">>, zlib:compress(Filtered)}]).

samples(0) -> 1;
samples(2) -> 3;
samples(3) -> 1;
samples(4) -> 2;
samples(6) -> 4.

%% Every colour type and bit depth table 11.1 allows.
formats() ->
    [{0, 1}, {0, 2}, {0, 4}, {0, 8}, {0, 16}, {2, 8}, {2, 16}, {3, 1}, {3, 2}, {3, 4}, {3, 8},
     {4, 8}, {4, 16}, {6, 8}, {6, 16}].

%% A small image of a random format and size with random samples, a full
%% palette for colour type 3, and filter type 0 on every row.
random_image() ->
    {Colour, Depth} = lists:nth(rand:uniform(length(formats())), formats()),
    W = rand:uniform(9),
    H = rand:uniform(5),
    Line = (W * Depth * samples(Colour) + 7) div 8,
    Rows = [rand:bytes(Line) || _ <- lists:seq(1, H)],
    Palette = case Colour of
                  3 -> rand:bytes(3 * (1 bsl Depth));
                  _ -> none
              end,
    #{width => W, height => H, depth => Depth, colour => Colour, rows => Rows,
      filters => lists:duplicate(H, 0), palette => Palette}.

random_filters(#{rows := Rows} = Image) ->
    Image#{filters := [rand:uniform(5) - 1 || _ <- Rows]}.

%% Section 9.2's filters, the inverse of the reader's reconstruction.
filter(Filter, Row, Prior, Bpp) ->
    Zeros = <<0:(Bpp * 8)>>,
    filter(Filter, Row, Prior, <<Zeros/binary, Prior/binary>>, <<Zeros/binary, Row/binary>>, <<>>).

filter(Filter, <<X, Row/binary>>, <<B, Prior/binary>>, <<C, Corner/binary>>, <<A, Left/binary>>, Out) ->
    filter(Filter, Row, Prior, Corner, Left, <<Out/binary, ((X - predict(Filter, A, B, C)) band 255)>>);
filter(_Filter, <<>>, _Prior, _Corner, _Left, Out) ->
    Out.

predict(0, _A, _B, _C) -> 0;
predict(1, A, _B, _C) -> A;
predict(2, _A, B, _C) -> B;
predict(3, A, B, _C) -> (A + B) div 2;
predict(4, A, B, C) ->
    P = A + B - C,
    case {abs(P - A), abs(P - B), abs(P - C)} of
        {PA, PB, PC} when PA =< PB, PA =< PC -> A;
        {_, PB, PC} when PB =< PC -> B;
        _ -> C
    end.
