%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_png).
-moduledoc """
The PNG reader of the Erlang renderer (docs/design-display.md, "The widget
server"): an `image` node's PNG, untrusted, decoded in Erlang into pixels
in a Plan 9 channel, ready for a `y` into an image of that channel.

A PNG (W3C PNG, third edition) is a signature and chunks, each a length,
a type, data and the CRC-32 of type and data; every CRC is checked. IHDR
comes first and the chunks end at IEND; PLTE and tRNS come before the IDAT
chunks, which are consecutive; an unknown chunk is skipped when it is
ancillary and refused when it is critical. What libpng and the browsers
pass over, so that every renderer shows the same images (decision 15), is
passed over here too: bytes after IEND, bytes after the end of the image
data's zlib stream, and tRNS alphas past the palette's end.

Before anything is inflated, the header is checked, an interlaced image is
refused, and the image is put to erx_draw_core's admission of an image of
its size in the channel asked for, which bounds its sides and charges its
pixel bytes against what is left of the draw connection's quota. Then
erx_inflate must yield the filtered rows the header declares, a filter
byte and the packed samples of each row: it stops the moment its output
would pass them, and a stream that ends short of them is refused.

The rows are unfiltered against the row above (section 7.3) and packed one
at a time, so a decode holds the filtered rows, the pixels and one row. A
pixel is read as 8-bit red, green, blue and alpha: a sample of 1, 2, 4 or
16 bits is scaled to 8 and rounded, as ImageMagick does; a palette index
past the palette is opaque black, as the third edition requires; and tRNS
gives a palette its alphas or names the one grey or colour that is
transparent. The colours are premultiplied by alpha, as Plan 9 holds them,
and packed into the channel as libmemdraw's rgbatoimg packs a colour: each
channel takes the high bits of its colour, grey the luminance RGB2K gives,
and an ignored channel zeros. A channel with a colour map is refused.
""".
-export([decode/2]).
-export_type([reason/0]).

-doc """
Why a PNG is refused: `signature`, bytes that are not a PNG; `chunk`, a
chunk that is cut short, too long or misnamed; `crc`, a chunk whose CRC
does not match; `order`, chunks missing, repeated or out of place, or an
unknown critical chunk; `header`, an IHDR of no valid size or format;
`interlaced`, an Adam7 image; `too_large`, an image whose sides the draw
connection refuses, and `quota`, one whose pixels pass the quota left;
`palette`, a PLTE or tRNS whose size does not fit the image; `filter`, a
row of an unknown filter type; `channel`, a channel with a colour map;
`{inflate, Reason}`, image data erx_inflate refuses; and `size`, image data
that inflates to fewer bytes than the rows need.
""".
-type reason() :: signature | chunk | crc | order | header | interlaced | too_large | quota | palette
                | filter | channel | {inflate, erx_inflate:reason()} | size.

%% IHDR's fields (section 11.2.1), with the bits of one pixel.
-type header() :: #{width := pos_integer(), height := pos_integer(), depth := 1 | 2 | 4 | 8 | 16,
                    colour := 0 | 2 | 3 | 4 | 6, pixel_bits := pos_integer()}.

%% Where a pixel's colour comes from besides its own samples: a colour type
%% 3 image's palette, as a tuple of {R, G, B, A}; the samples of the one
%% grey or colour tRNS makes transparent; or nothing.
-type colours() :: {palette, tuple()} | {key, [non_neg_integer()]} | none.

-define(SIGNATURE, <<137, $P, $N, $G, $\r, $\n, 26, $\n>>).
-define(MAX_LENGTH, 16#7fffffff).

-doc """
The image of PNG Png as pixels in channel Chan, `bytes_per_line` of its
rectangle a row, if the draw connection would admit an image of its size
under Quota, whose pixels are those left to the connection; or the reason
it is refused. The caller is trusted: Chan must be a channel
`erx_chan:depth/1` accepts.
""".
-spec decode(binary(), #{chan := erx_chan:code(), quota := erx_draw_core:quota()}) ->
          {ok, erx_draw_codec:rect(), Pixels :: binary()} | {error, reason()}.
decode(Png, #{chan := Chan, quota := Quota}) when is_binary(Png) ->
    try image(Png, Chan, Quota) of
        {R, Pixels} -> {ok, R, Pixels}
    catch
        throw:{?MODULE, Reason} -> {error, Reason}
    end.

fail(Reason) -> throw({?MODULE, Reason}).

check(true, _Reason) -> ok;
check(false, Reason) -> fail(Reason).

image(<<Signature:8/binary, Chunks/binary>>, Chan, Quota) when Signature =:= ?SIGNATURE ->
    {ok, Depth} = erx_chan:depth(Chan),
    Channels = erx_chan:channels(Chan),
    check(not lists:keymember(map, 1, Channels), channel),
    case chunks(Chunks, []) of
        [{<<"IHDR">>, Fields} | Rest] ->
            #{width := W, height := H} = Header = header(Fields),
            R = {0, 0, W, H},
            case erx_draw_core:admit(R, Depth, Quota) of
                ok -> ok;
                {error, einval} -> fail(too_large);
                {error, enomem} -> fail(quota)
            end,
            {Colours, Idat} = image_chunks(Rest, Header),
            Line = row_bytes(Header),
            Filtered = H * (1 + Line),
            Data = case erx_inflate:zlib(Idat, Filtered) of
                       {ok, Inflated, _After} when byte_size(Inflated) =:= Filtered -> Inflated;
                       {ok, _Short, _After} -> fail(size);
                       {error, Reason} -> fail({inflate, Reason})
                   end,
            Pack = fun(Row) -> pack(Row, Header, Colours, Channels, Depth) end,
            {R, rows(Data, Line, max(1, maps:get(pixel_bits, Header) div 8), <<0:(Line * 8)>>, Pack, <<>>)};
        _ ->
            fail(order)
    end;
image(_Png, _Chan, _Quota) ->
    fail(signature).

%% The chunks up to IEND, each CRC checked.
chunks(<<Length:32, Type:4/binary, Rest/binary>>, Acc) when Length =< ?MAX_LENGTH ->
    check(lists:all(fun letter/1, binary_to_list(Type)), chunk),
    case Rest of
        <<Data:Length/binary, Crc:32, After/binary>> ->
            check(erlang:crc32([Type, Data]) =:= Crc, crc),
            case Type of
                <<"IEND">> -> lists:reverse(Acc);
                _ -> chunks(After, [{Type, Data} | Acc])
            end;
        _ ->
            fail(chunk)
    end;
chunks(_Bytes, _Acc) ->
    fail(chunk).

letter(Byte) -> (Byte >= $A andalso Byte =< $Z) orelse (Byte >= $a andalso Byte =< $z).

%% Section 11.2.1: the sizes and the formats table 11.1 allows, with
%% compression and filter method 0, and no interlace.
-spec header(binary()) -> header().
header(<<W:32, H:32, Depth, Colour, 0, 0, Interlace>>)
  when W >= 1, W =< ?MAX_LENGTH, H >= 1, H =< ?MAX_LENGTH ->
    Samples = case {Colour, Depth} of
                  {0, D} when D =:= 1; D =:= 2; D =:= 4; D =:= 8; D =:= 16 -> 1;
                  {2, D} when D =:= 8; D =:= 16 -> 3;
                  {3, D} when D =:= 1; D =:= 2; D =:= 4; D =:= 8 -> 1;
                  {4, D} when D =:= 8; D =:= 16 -> 2;
                  {6, D} when D =:= 8; D =:= 16 -> 4;
                  _ -> fail(header)
              end,
    check(Interlace =/= 1, interlaced),
    check(Interlace =:= 0, header),
    #{width => W, height => H, depth => Depth, colour => Colour, pixel_bits => Samples * Depth};
header(_Fields) ->
    fail(header).

row_bytes(#{width := W, pixel_bits := Bits}) -> (W * Bits + 7) div 8.

%% The chunks after IHDR, in the order section 5.6 sets: PLTE, then tRNS,
%% then the run of IDAT chunks; other ancillary chunks anywhere, and nothing
%% critical after the run. The result is the pixels' colours and the image
%% data, the run's chunks joined.
-spec image_chunks([{binary(), binary()}], header()) -> {colours(), binary()}.
image_chunks(Chunks, #{colour := Colour} = Header) ->
    #{plte := Plte, trns := Trns, idat := Idat} =
        lists:foldl(fun(Chunk, Seen) -> chunk(Chunk, Seen, Header) end,
                    #{phase => before, plte => none, trns => none, idat => []}, Chunks),
    check(Idat =/= [], order),
    check(Colour =/= 3 orelse Plte =/= none, order),
    {colours(Plte, Trns, Header), iolist_to_binary(lists:reverse(Idat))}.

%% Phase is where the fold stands: before, in or after the IDAT run.
chunk({<<"IDAT">>, Data}, #{phase := Phase, idat := Idat} = Seen, _Header) when Phase =/= 'after' ->
    Seen#{phase := in, idat := [Data | Idat]};
chunk({Type, Data}, #{phase := in} = Seen, Header) ->
    chunk({Type, Data}, Seen#{phase := 'after'}, Header);
chunk({<<"PLTE">>, Data}, #{phase := before, plte := none, trns := none} = Seen, #{colour := Colour})
  when Colour =/= 0, Colour =/= 4 ->
    check(byte_size(Data) rem 3 =:= 0 andalso byte_size(Data) > 0 andalso byte_size(Data) =< 768, palette),
    Seen#{plte := [{R, G, B} || <<R, G, B>> <= Data]};
chunk({<<"tRNS">>, Data}, #{phase := before, trns := none} = Seen, #{colour := Colour})
  when Colour =:= 0; Colour =:= 2; Colour =:= 3 ->
    Seen#{trns := Data};
chunk({<<First, _/binary>>, _Data}, Seen, _Header) when First >= $a ->
    Seen;
chunk(_Chunk, _Seen, _Header) ->
    fail(order).

%% A colour type 3 image's palette, no more entries than its bit depth
%% reaches, with tRNS's alphas for its first entries; the samples tRNS
%% names for grey and truecolour, masked to the bit depth as section
%% 11.3.2.1 asks; or none.
-spec colours(none | [{byte(), byte(), byte()}], none | binary(), header()) -> colours().
colours(Plte, Trns, #{colour := 3, depth := Depth}) ->
    Entries = length(Plte),
    check(Entries =< 1 bsl Depth, palette),
    Given = case Trns of
                none -> [];
                _ -> lists:sublist(binary_to_list(Trns), Entries)
            end,
    Alphas = Given ++ lists:duplicate(Entries - length(Given), 255),
    {palette, list_to_tuple([{R, G, B, A} || {{R, G, B}, A} <- lists:zip(Plte, Alphas)])};
colours(_Plte, none, _Header) ->
    none;
colours(_Plte, <<Grey:16>>, #{colour := 0, depth := Depth}) ->
    {key, [Grey band ((1 bsl Depth) - 1)]};
colours(_Plte, <<R:16, G:16, B:16>>, #{colour := 2, depth := Depth}) ->
    Mask = (1 bsl Depth) - 1,
    {key, [R band Mask, G band Mask, B band Mask]};
colours(_Plte, _Trns, _Header) ->
    fail(palette).

%% Section 7.3 and 9: each row of Data, a filter type byte and Line bytes,
%% unfiltered against the row above, Prior, zeros above the first, and its
%% pixels packed onto Out.
rows(<<>>, _Line, _Bpp, _Prior, _Pack, Out) ->
    Out;
rows(<<Filter, Data/binary>>, Line, Bpp, Prior, Pack, Out) when Filter =< 4 ->
    <<Filtered:Line/binary, Rest/binary>> = Data,
    Zeros = <<0:(Bpp * 8)>>,
    Row = reconstruct(Filter, Filtered, Prior, <<Zeros/binary, Prior/binary>>, Zeros, <<>>),
    rows(Rest, Line, Bpp, Row, Pack, <<Out/binary, (Pack(Row))/binary>>);
rows(_Data, _Line, _Bpp, _Prior, _Pack, _Out) ->
    fail(filter).

%% X is the filtered byte; B the byte above it, C the byte above A and A
%% the byte Bpp to the left, as reconstructed so far, the head of Left,
%% which holds the last Bpp bytes of the row.
reconstruct(Filter, <<X, Line/binary>>, <<B, Prior/binary>>, <<C, Corner/binary>>, <<A, Left/binary>>, Row) ->
    Byte = (X + predict(Filter, A, B, C)) band 255,
    reconstruct(Filter, Line, Prior, Corner, <<Left/binary, Byte>>, <<Row/binary, Byte>>);
reconstruct(_Filter, <<>>, _Prior, _Corner, _Left, Row) ->
    Row.

predict(0, _A, _B, _C) -> 0;
predict(1, A, _B, _C) -> A;
predict(2, _A, B, _C) -> B;
predict(3, A, B, _C) -> (A + B) bsr 1;
predict(4, A, B, C) ->
    P = A + B - C,
    PA = abs(P - A),
    PB = abs(P - B),
    PC = abs(P - C),
    if
        PA =< PB andalso PA =< PC -> A;
        PB =< PC -> B;
        true -> C
    end.

%% One row's pixels in the channel, laid out as Plan 9 lays a row: the
%% padding bits after the last sample of a row of small samples dropped,
%% each pixel's value little-endian when it is 8 bits or more, and below 8
%% bits packed from a byte's high bits down, the row padded to a byte.
pack(Row, #{width := W} = Header, Colours, Channels, Depth) ->
    Values = [value(premultiply(Pixel), Channels) || Pixel <- lists:sublist(pixels(Row, Header, Colours), W)],
    Packed = case Depth >= 8 of
                 true -> << <<V:Depth/little>> || V <- Values >>;
                 false -> << <<V:Depth>> || V <- Values >>
             end,
    <<Packed/bitstring, 0:((8 - bit_size(Packed) rem 8) rem 8)>>.

%% Each pixel of a row as {R, G, B, A}, 8 bits each.
pixels(Row, #{colour := 0, depth := D}, Colours) ->
    [grey(eight(G, D), alpha([G], Colours)) || <<G:D>> <= Row];
pixels(Row, #{colour := 2, depth := D}, Colours) ->
    [{eight(R, D), eight(G, D), eight(B, D), alpha([R, G, B], Colours)} || <<R:D, G:D, B:D>> <= Row];
pixels(Row, #{colour := 3, depth := D}, {palette, Palette}) ->
    [entry(Index, Palette) || <<Index:D>> <= Row];
pixels(Row, #{colour := 4, depth := D}, none) ->
    [grey(eight(G, D), eight(A, D)) || <<G:D, A:D>> <= Row];
pixels(Row, #{colour := 6, depth := D}, none) ->
    [{eight(R, D), eight(G, D), eight(B, D), eight(A, D)} || <<R:D, G:D, B:D, A:D>> <= Row].

grey(G, A) -> {G, G, G, A}.

alpha(Samples, {key, Samples}) -> 0;
alpha(_Samples, _Colours) -> 255.

entry(Index, Palette) when Index < tuple_size(Palette) -> element(Index + 1, Palette);
entry(_Index, _Palette) -> {0, 0, 0, 255}.

%% A sample of D bits scaled to 8, rounded: exact below 8 bits, the same
%% sample at 8, and V / 257 rounded at 16.
eight(V, D) ->
    Max = (1 bsl D) - 1,
    (V * 255 + Max div 2) div Max.

premultiply({_, _, _, 255} = Pixel) -> Pixel;
premultiply({R, G, B, A}) -> {times(R, A), times(G, A), times(B, A), A}.

%% C * A / 255, rounded.
times(C, A) -> (C * A + 127) div 255.

%% libmemdraw's rgbatoimg: from the channel in the low bits up, each takes
%% the high bits of its colour.
value(Pixel, Channels) ->
    {Value, _Bits} =
        lists:foldl(fun({Type, Bits}, {Low, Shift}) ->
                            {Low bor ((colour(Type, Pixel) bsr (8 - Bits)) bsl Shift), Shift + Bits}
                    end, {0, 0}, Channels),
    Value.

colour(red, {R, _G, _B, _A}) -> R;
colour(green, {_R, G, _B, _A}) -> G;
colour(blue, {_R, _G, B, _A}) -> B;
colour(alpha, {_R, _G, _B, A}) -> A;
colour(grey, {R, G, B, _A}) -> (156763 * R + 307758 * G + 59769 * B) bsr 19;
colour(ignore, _Pixel) -> 0.
