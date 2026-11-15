%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% The cases of erx_png (docs/design-display.md, "The widget server",
%% "Verification and testing"): the PngSuite images of
%% test/fixtures/pngsuite agree with ImageMagick's decoding recorded in
%% its goldens.txt, every filter type reconstructs what it filtered, the
%% pixels pack into Plan 9 channels as libmemdraw packs a colour, and a
%% malformed PNG is refused with its reason, an interlaced one or one past
%% the quota before its data is inflated. ERX_PNGSUITE names the
%% directory of the images.
-module(erx_png_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(QUOTA, 1 bsl 26).

chan(Text) ->
    {ok, Code, _Depth} = erx_chan:parse(list_to_binary(Text)),
    Code.

decode(Png, Chan) -> erx_png:decode(Png, #{chan => chan(Chan), quota => #{pixels => ?QUOTA, side => 16384}}).

suite_path(Name) -> filename:join(os:getenv("ERX_PNGSUITE"), Name).

%% Each image decoded into a8b8g8r8, whose bytes are R G B A, matches the
%% size and the pixels' SHA-256 of its golden.
pngsuite_test_() ->
    {ok, Text} = file:read_file(suite_path("goldens.txt")),
    Goldens = [binary:split(Line, <<" ">>, [global]) || Line <- binary:split(Text, <<"\n">>, [global, trim_all]),
                                                        binary:first(Line) =/= $#],
    ?assert(length(Goldens) >= 30),
    [{binary_to_list(Name),
      fun() ->
              {ok, Png} = file:read_file(suite_path(binary_to_list(Name))),
              {ok, R, Pixels} = decode(Png, "a8b8g8r8"),
              ?assertEqual({0, 0, binary_to_integer(W), binary_to_integer(H)}, R),
              ?assertEqual(Sha, binary:encode_hex(crypto:hash(sha256, Pixels), lowercase))
      end} || [Name, W, H, Sha] <- Goldens].

interlaced_pngsuite_test() ->
    {ok, Png} = file:read_file(suite_path("ibasn6a08.png")),
    ?assertEqual({error, interlaced}, decode(Png, "a8b8g8r8")).

%% Rows filtered with random filter types decode as the same rows written
%% with none, in every format.
filters_test() ->
    rand:seed(exsss, {7, 11, 13}),
    lists:foreach(fun(_) ->
                          Image = erx_png_encode:random_image(),
                          Plain = decode(erx_png_encode:image(Image), "a8r8g8b8"),
                          ?assertMatch({ok, _, _}, Plain),
                          ?assertEqual(Plain, decode(erx_png_encode:image(erx_png_encode:random_filters(Image)),
                                                     "a8r8g8b8"))
                  end, lists:seq(1, 400)).

rgba_pixels(Pixels) ->
    W = length(Pixels),
    erx_png_encode:image(#{width => W, height => 1, depth => 8, colour => 6, filters => [0],
                           rows => [<< <<R, G, B, A>> || {R, G, B, A} <- Pixels >>]}).

%% A colour packs as rgbatoimg packs it, premultiplied by its alpha.
channels_test() ->
    Png = rgba_pixels([{16#ff, 16#80, 16#01, 255}, {200, 100, 50, 128}]),
    %% 200*128/255 = 100.39, 100*128/255 = 50.2, 50*128/255 = 25.1.
    ?assertEqual({ok, {0, 0, 2, 1}, <<16#01, 16#80, 16#ff, 255, 25, 50, 100, 128>>}, decode(Png, "a8r8g8b8")),
    ?assertEqual({ok, {0, 0, 2, 1}, <<16#01, 16#80, 16#ff, 0, 25, 50, 100, 0>>}, decode(Png, "x8r8g8b8")),
    ?assertEqual({ok, {0, 0, 2, 1}, <<16#01, 16#80, 16#ff, 25, 50, 100>>}, decode(Png, "r8g8b8")),
    %% r5g6b5: 11111 100000 00000, then 01100 001100 00011.
    ?assertEqual({ok, {0, 0, 2, 1}, <<2#00000000, 2#11111100, 2#10000011, 2#01100001>>}, decode(Png, "r5g6b5")),
    %% RGB2K: (156763*255 + 307758*128 + 59769*1) >> 19 = 151, and of the
    %% premultiplied (100, 50, 25), 62.
    ?assertEqual({ok, {0, 0, 2, 1}, <<151, 62>>}, decode(Png, "k8")),
    %% k1, the leftmost pixel in the high bit: 151 and 62 keep their top bit.
    ?assertEqual({ok, {0, 0, 2, 1}, <<2#10000000>>}, decode(Png, "k1")),
    ?assertEqual({error, channel}, decode(Png, "m8")).

palette_png(Indices, Palette, Trns) ->
    erx_png_encode:image(#{width => length(Indices), height => 1, depth => 8, colour => 3, filters => [0],
                           rows => [list_to_binary(Indices)], palette => Palette, trns => Trns}).

%% tRNS gives a palette its alphas, the rest opaque, and alphas past the
%% palette are passed over; an index past the palette is opaque black.
palette_test() ->
    Png = palette_png([0, 1, 2], <<10, 20, 30, 40, 50, 60>>, <<0>>),
    ?assertEqual({ok, {0, 0, 3, 1}, <<0, 0, 0, 0, 40, 50, 60, 255, 0, 0, 0, 255>>}, decode(Png, "a8b8g8r8")),
    ?assertEqual(decode(Png, "a8b8g8r8"),
                 decode(palette_png([0, 1, 2], <<10, 20, 30, 40, 50, 60>>, <<0, 255, 7>>), "a8b8g8r8")).

%% Rows of samples below 8 bits and of odd width: the padding bits after the
%% last sample are dropped.
small_samples_test() ->
    Grey = erx_png_encode:image(#{width => 3, height => 2, depth => 1, colour => 0, filters => [0, 0],
                                  rows => [<<2#10111111>>, <<2#01000000>>]}),
    ?assertEqual({ok, {0, 0, 3, 2}, <<255, 0, 255, 0, 255, 0>>}, decode(Grey, "k8")),
    Indexed = erx_png_encode:image(#{width => 3, height => 1, depth => 2, colour => 3, filters => [0],
                                     rows => [<<2#11001011>>], palette => <<0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3>>}),
    ?assertEqual({ok, {0, 0, 3, 1}, <<3, 0, 2>>}, decode(Indexed, "k8")).

%% tRNS names the one grey or colour that is transparent, at full depth,
%% its bits above the image's bit depth masked off.
key_test() ->
    Grey = erx_png_encode:image(#{width => 2, height => 1, depth => 16, colour => 0, filters => [0],
                                  rows => [<<16#1234:16, 16#1235:16>>], trns => <<16#1234:16>>}),
    ?assertEqual({ok, {0, 0, 2, 1}, <<0, 0, 0, 0, 16#12, 16#12, 16#12, 255>>}, decode(Grey, "a8b8g8r8")),
    Rgb = erx_png_encode:image(#{width => 2, height => 1, depth => 8, colour => 2, filters => [0],
                                 rows => [<<1, 2, 3, 1, 2, 4>>], trns => <<1:16, 2:16, 3:16>>}),
    ?assertEqual({ok, {0, 0, 2, 1}, <<0, 0, 0, 0, 1, 2, 4, 255>>}, decode(Rgb, "a8b8g8r8")),
    Masked = erx_png_encode:image(#{width => 2, height => 1, depth => 8, colour => 0, filters => [0],
                                    rows => [<<0, 1>>], trns => <<16#ff00:16>>}),
    ?assertEqual({ok, {0, 0, 2, 1}, <<0, 0, 0, 0, 1, 1, 1, 255>>}, decode(Masked, "a8b8g8r8")).

%% A 4x4 RGBA image needs 64 pixel bytes in a8r8g8b8, charged as one 4 KiB
%% page, so it fits a quota of 4096 and not of 4095, and sides of 4 and not
%% of 3; the image data is garbage, so a refusal shows the image was
%% admitted or not before anything was inflated.
quota_test() ->
    Header = #{width => 4, height => 4, depth => 8, colour => 6},
    Good = erx_png_encode:image(Header#{filters => [0, 0, 0, 0], rows => lists:duplicate(4, <<0:128>>)}),
    Garbage = erx_png_encode:png([{<<"IHDR">>, erx_png_encode:header(Header)}, {<<"IDAT">>, <<"garbage">>}]),
    Under = fun(Png, Pixels, Side) ->
                    erx_png:decode(Png, #{chan => chan("a8r8g8b8"), quota => #{pixels => Pixels, side => Side}})
            end,
    ?assertMatch({ok, _, _}, Under(Good, 4096, 4)),
    ?assertEqual({error, quota}, Under(Good, 4095, 4)),
    ?assertEqual({error, quota}, Under(Garbage, 4095, 4)),
    ?assertEqual({error, too_large}, Under(Good, 4096, 3)),
    ?assertEqual({error, too_large}, Under(Garbage, 4096, 3)),
    Huge = erx_png_encode:header(#{width => 16#7fffffff, height => 1, depth => 1, colour => 0}),
    ?assertEqual({error, too_large},
                 decode(erx_png_encode:png([{<<"IHDR">>, Huge}, {<<"IDAT">>, <<>>}]), "a8r8g8b8")).

%% A 16-bit RGBA PNG read into k1 has 64 filtered bytes for each pixel
%% byte, so its pixels fit a quota its filtered rows do not: it is refused
%% before anything is inflated, the small one here and one whose rows
%% would inflate to 32 MiB from a PNG within the picture cap.
bomb_test() ->
    Small = bomb(256, 128),
    ?assertEqual(ok, erx_draw_core:admit({0, 0, 256, 128}, 1, #{pixels => 4096, side => 16384})),
    ?assertEqual({error, quota}, erx_png:decode(Small, #{chan => chan("k1"), quota => #{pixels => 4096, side => 16384}})),
    Large = bomb(4096, 1024),
    ?assert(byte_size(Large) =< ?ERX_UI_PICTURE_BYTES),
    ?assertEqual({error, quota},
                 erx_png:decode(Large, #{chan => chan("k1"), quota => #{pixels => 1 bsl 19, side => 16384}})).

%% A PNG at the picture cap is read, one byte past it is refused, and so is
%% a bomb of 64 MiB of rows too long for the cap, under a quota its pixels fit.
picture_cap_test() ->
    Good = erx_png_encode:png([{<<"IHDR">>, grey_header()}, idat(good_rows())]),
    Pad = fun(Length) ->
                  <<Head:(byte_size(Good) - 12)/binary, Iend/binary>> = Good,
                  Text = erx_png_encode:chunk(<<"tEXt">>, <<0:((Length - byte_size(Good) - 12) * 8)>>),
                  <<Head/binary, Text/binary, Iend/binary>>
          end,
    ?assertMatch({ok, _, _}, decode(Pad(?ERX_UI_PICTURE_BYTES), "k8")),
    ?assertEqual({error, too_large}, decode(Pad(?ERX_UI_PICTURE_BYTES + 1), "k8")),
    ?assertEqual({error, too_large},
                 erx_png:decode(bomb(4096, 2048), #{chan => chan("k1"), quota => #{pixels => 1 bsl 20, side => 16384}})).

%% A W x H 16-bit RGBA PNG of zeros.
bomb(W, H) ->
    Header = erx_png_encode:header(#{width => W, height => H, depth => 16, colour => 6}),
    erx_png_encode:png([{<<"IHDR">>, Header}, {<<"IDAT">>, zlib:compress(<<0:(H * (1 + W * 8) * 8)>>)}]).

%% A second tRNS, one after the image data and one for a colour type with
%% alpha are passed over, as any ancillary chunk the reader does not use.
misplaced_trns_test() ->
    IHDR = {<<"IHDR">>, grey_header()},
    Key = {<<"tRNS">>, <<1:16>>},
    {ok, R, Pixels} = decode(erx_png_encode:png([IHDR, idat(good_rows())]), "a8r8g8b8"),
    {ok, R, Keyed} = decode(erx_png_encode:png([IHDR, Key, idat(good_rows())]), "a8r8g8b8"),
    ?assertNotEqual(Pixels, Keyed),
    ?assertEqual({ok, R, Keyed}, decode(erx_png_encode:png([IHDR, Key, {<<"tRNS">>, <<2:16>>}, idat(good_rows())]),
                                        "a8r8g8b8")),
    ?assertEqual({ok, R, Pixels}, decode(erx_png_encode:png([IHDR, idat(good_rows()), Key]), "a8r8g8b8")),
    Alpha = erx_png_encode:header(#{width => 1, height => 1, depth => 8, colour => 4}),
    ?assertMatch({ok, _, _}, decode(erx_png_encode:png([{<<"IHDR">>, Alpha}, Key, idat(<<0, 1, 255>>)]), "a8r8g8b8")).

interlaced_test() ->
    Header = erx_png_encode:header(#{width => 4, height => 4, depth => 8, colour => 6, interlace => 1}),
    ?assertEqual({error, interlaced},
                 decode(erx_png_encode:png([{<<"IHDR">>, Header}, {<<"IDAT">>, <<"garbage">>}]), "a8r8g8b8")).

grey_header() -> erx_png_encode:header(#{width => 2, height => 2, depth => 8, colour => 0}).

idat(Filtered) -> {<<"IDAT">>, zlib:compress(Filtered)}.

good_rows() -> <<0, 1, 2, 0, 3, 4>>.

refuse(Reason, Png) -> ?assertEqual({error, Reason}, decode(Png, "a8r8g8b8")).

%% Each malformation is refused with its reason.
refusal_test_() ->
    IHDR = {<<"IHDR">>, grey_header()},
    Good = erx_png_encode:png([IHDR, idat(good_rows())]),
    <<Signature:8/binary, IhdrLength:4/binary, IhdrType:4/binary, IhdrData:13/binary, IhdrCrc:32,
      After/binary>> = Good,
    Palette = {<<"PLTE">>, <<1, 2, 3>>},
    PaletteHeader = {<<"IHDR">>, erx_png_encode:header(#{width => 2, height => 2, depth => 1, colour => 3})},
    Indices = idat(<<0, 0, 0, 0>>),
    [?_assertMatch({ok, _, _}, decode(Good, "a8r8g8b8")),
     ?_test(refuse(signature, <<"GIF89a", Good/binary>>)),
     ?_test(refuse(crc, <<Signature/binary, IhdrLength/binary, IhdrType/binary, IhdrData/binary,
                          (IhdrCrc bxor 1):32, After/binary>>)),
     ?_test(refuse(chunk, binary:part(Good, 0, byte_size(Good) - 3))),
     ?_test(refuse(chunk, <<Signature/binary, 16#80000000:32, "IHDR", IhdrData/binary>>)),
     ?_test(refuse(chunk, erx_png_encode:png([IHDR, {<<"bad!">>, <<>>}, idat(good_rows())]))),
     ?_test(refuse(chunk, <<(binary:part(Good, 0, byte_size(Good) - 12))/binary,
                             (erx_png_encode:chunk(<<"IEND">>, <<0>>))/binary>>)),
     ?_test(refuse(order, erx_png_encode:png([idat(good_rows())]))),
     ?_test(refuse(order, erx_png_encode:png([IHDR]))),
     ?_test(refuse(order, erx_png_encode:png([IHDR, IHDR, idat(good_rows())]))),
     ?_test(refuse(order, erx_png_encode:png([IHDR, {<<"CRIT">>, <<>>}, idat(good_rows())]))),
     ?_test(refuse(order, erx_png_encode:png([IHDR, Palette, idat(good_rows())]))),
     ?_test(refuse(order, erx_png_encode:png([IHDR, idat(<<0, 1, 2>>), {<<"tEXt">>, <<>>}, idat(<<0, 3, 4>>)]))),
     ?_test(refuse(order, erx_png_encode:png([PaletteHeader, Indices]))),
     ?_test(refuse(order, erx_png_encode:png([PaletteHeader, {<<"tRNS">>, <<0>>}, Palette, Indices]))),
     ?_test(refuse(order, erx_png_encode:png([PaletteHeader, Indices, Palette]))),
     ?_test(refuse(palette, erx_png_encode:png([PaletteHeader, {<<"PLTE">>, <<0:(3 * 3 * 8)>>}, Indices]))),
     ?_test(refuse(palette, erx_png_encode:png([IHDR, {<<"tRNS">>, <<0>>}, idat(good_rows())]))),
     ?_test(refuse(header, erx_png_encode:png([{<<"IHDR">>, <<0:32, 2:32, 8, 0, 0, 0, 0>>}, idat(good_rows())]))),
     ?_test(refuse(header, erx_png_encode:png([{<<"IHDR">>, <<2:32, 2:32, 16, 3, 0, 0, 0>>}, idat(good_rows())]))),
     ?_test(refuse(header, erx_png_encode:png([{<<"IHDR">>, <<2:32, 2:32, 8, 0, 1, 0, 0>>}, idat(good_rows())]))),
     ?_test(refuse(header, erx_png_encode:png([{<<"IHDR">>, <<2:32, 2:32, 8, 0, 0, 0, 2>>}, idat(good_rows())]))),
     ?_test(refuse(filter, erx_png_encode:png([IHDR, idat(<<5, 1, 2, 0, 3, 4>>)]))),
     ?_test(refuse(size, erx_png_encode:png([IHDR, idat(<<0, 1, 2>>)]))),
     ?_test(refuse({inflate, limit}, erx_png_encode:png([IHDR, idat(<<(good_rows())/binary, 0>>)]))),
     ?_test(refuse({inflate, check},
                   erx_png_encode:png([IHDR, {<<"IDAT">>, flip_last(zlib:compress(good_rows()))}]))),
     %% IDAT split anywhere, an ancillary chunk of no meaning, bytes after
     %% the zlib stream and bytes after IEND are passed over.
     ?_assertEqual(decode(Good, "a8r8g8b8"),
                   decode(erx_png_encode:png([IHDR, {<<"zzZz">>, <<1>>} | split(zlib:compress(good_rows()))]),
                          "a8r8g8b8")),
     ?_assertEqual(decode(Good, "a8r8g8b8"),
                   decode(erx_png_encode:png([IHDR, {<<"IDAT">>, <<(zlib:compress(good_rows()))/binary, 0>>}]),
                          "a8r8g8b8")),
     ?_assertEqual(decode(Good, "a8r8g8b8"), decode(<<Good/binary, "trailing">>, "a8r8g8b8"))].

flip_last(Bytes) ->
    Size = byte_size(Bytes) - 1,
    <<Head:Size/binary, Last>> = Bytes,
    <<Head/binary, (Last bxor 1)>>.

split(Bytes) -> [{<<"IDAT">>, <<Byte>>} || <<Byte>> <= Bytes].
