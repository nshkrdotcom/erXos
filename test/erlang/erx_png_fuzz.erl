%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% The fuzz target of erx_png and erx_inflate (docs/design-display.md,
%% "Verification and testing"). Each round decodes arbitrary bytes, a
%% mutated PNG with its CRCs mended or not, and a mutated zlib stream under
%% a random limit, and asserts that every call ends with pixels or a
%% refusal, that decoded pixels fill exactly their rectangle's rows, that
%% inflated bytes never pass the limit and agree with stock OTP's zlib
%% whenever the limit does not decide, and that an interlaced image or one
%% past the quota is refused before its garbage data is inflated.
-module(erx_png_fuzz).
-export([run/1, rounds/2]).

-define(ROUNDS, 20000).
-define(QUOTA, #{pixels => 1 bsl 20, side => 16384}).
-define(PNG_REASONS, [signature, chunk, crc, order, header, interlaced, too_large, quota, palette, filter, size]).
-define(INFLATE_REASONS, [header, block, codes, symbol, distance, limit, truncated, check]).

run([Seed]) ->
    try
        rounds(list_to_integer(Seed), ?ROUNDS),
        io:format("fuzz: ~b rounds ok~n", [?ROUNDS])
    catch
        Class:Reason:Stack ->
            io:format("fuzz failed: ~p:~P~n~P~n", [Class, Reason, 40, Stack, 20]),
            halt(1)
    end.

rounds(Seed, Rounds) ->
    rand:seed(exsss, {Seed, 41, 43}),
    lists:foreach(fun(_) -> round() end, lists:seq(1, Rounds)).

round() ->
    Names = [<<"x8r8g8b8">>, <<"a8b8g8r8">>, <<"k1">>, <<"r5g6b5">>],
    {ok, Chan, _} = erx_chan:parse(lists:nth(rand:uniform(length(Names)), Names)),
    png(rand:bytes(rand:uniform(64) - 1), Chan),
    png(<<137, $P, $N, $G, $\r, $\n, 26, $\n, (rand:bytes(rand:uniform(64) - 1))/binary>>, Chan),
    Png = erx_png_encode:image(erx_png_encode:random_filters(erx_png_encode:random_image())),
    png(Png, Chan),
    png(mutate(Png), Chan),
    png(mend(mutate(Png)), Chan),
    Random = zlib:compress(rand:bytes(rand:uniform(300))),
    stream(Random, rand:uniform(600) - 1),
    stream(mutate(Random), rand:uniform(600) - 1),
    stream(mutate(zlib:compress(binary:copy(rand:bytes(rand:uniform(4)), rand:uniform(500)))), 1 bsl 20),
    refused_unread(Chan).

%% Any PNG decodes to exactly its rectangle's rows or a known refusal.
png(Bytes, Chan) ->
    {ok, Depth} = erx_chan:depth(Chan),
    case erx_png:decode(Bytes, #{chan => Chan, quota => ?QUOTA}) of
        {ok, {0, 0, W, H} = R, Pixels} when W > 0, H > 0 ->
            Rows = erx_draw_image:bytes_per_line(R, Depth) * H,
            byte_size(Pixels) =:= Rows orelse error({wrong_size, R, byte_size(Pixels), Bytes});
        {error, {inflate, Reason}} ->
            known(Reason, ?INFLATE_REASONS, Bytes);
        {error, Reason} ->
            known(Reason, ?PNG_REASONS, Bytes)
    end.

%% A stream inflates to at most Limit bytes, and to what zlib makes of it
%% when the limit does not decide.
stream(Bytes, Limit) ->
    case erx_inflate:zlib(Bytes, Limit) of
        {ok, Data, _Rest} when byte_size(Data) > Limit -> error({past_limit, Limit, byte_size(Data), Bytes});
        {ok, Data, _Rest} -> agree({ok, Data}, Bytes, Limit);
        {error, limit} -> ok;
        {error, Reason} -> known(Reason, ?INFLATE_REASONS, Bytes), agree(error, Bytes, Limit)
    end.

agree(Ours, Bytes, Limit) ->
    Stock = try zlib:uncompress(Bytes) of
                Data when byte_size(Data) =< Limit -> {ok, Data};
                _Longer -> error
            catch
                error:_ -> error
            end,
    Stock =:= Ours orelse error({disagrees_with_zlib, Ours, Stock, Bytes}).

%% An interlaced image and one past the quota, with garbage image data.
refused_unread(Chan) ->
    Header = #{width => rand:uniform(64), height => rand:uniform(64), depth => 8, colour => 6},
    Garbage = {<<"IDAT">>, rand:bytes(rand:uniform(32))},
    Interlaced = erx_png_encode:png([{<<"IHDR">>, erx_png_encode:header(Header#{interlace => 1})}, Garbage]),
    {error, interlaced} = erx_png:decode(Interlaced, #{chan => Chan, quota => ?QUOTA}),
    Plain = erx_png_encode:png([{<<"IHDR">>, erx_png_encode:header(Header)}, Garbage]),
    {error, quota} = erx_png:decode(Plain, #{chan => Chan, quota => #{pixels => 0, side => 16384}}),
    ok.

known(Reason, Reasons, Bytes) ->
    lists:member(Reason, Reasons) orelse error({unknown_reason, Reason, Bytes}).

%% One to four flipped bytes, a cut end or inserted bytes.
mutate(Bytes) when byte_size(Bytes) < 2 ->
    Bytes;
mutate(Bytes) ->
    At = rand:uniform(byte_size(Bytes) - 1),
    <<Head:At/binary, Byte, Tail/binary>> = Bytes,
    case rand:uniform(4) of
        1 -> <<Head/binary, (Byte bxor rand:uniform(255)), Tail/binary>>;
        2 -> Head;
        3 -> <<Head/binary, (rand:bytes(rand:uniform(8)))/binary, Byte, Tail/binary>>;
        4 -> mutate(<<Head/binary, (Byte bxor rand:uniform(255)), Tail/binary>>)
    end.

%% The chunks of a mutated PNG with their CRCs computed afresh, so that a
%% mutation reaches past the CRC check; bytes that are no chunk stay.
mend(<<Signature:8/binary, Chunks/binary>>) ->
    <<Signature/binary, (mend_chunks(Chunks))/binary>>;
mend(Bytes) ->
    Bytes.

mend_chunks(<<Length:32, Type:4/binary, Rest/binary>>) when byte_size(Rest) >= Length + 4 ->
    <<Data:Length/binary, _Crc:32, After/binary>> = Rest,
    <<Length:32, Type/binary, Data/binary, (erlang:crc32([Type, Data])):32, (mend_chunks(After))/binary>>;
mend_chunks(Bytes) ->
    Bytes.
