%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dashboard_clock).
-moduledoc """
The dashboard's analog clock as a picture: png/1 draws the dial for a
wall-clock reading as a PNG, which the view shows in an `image` node
(docs/design-display.md, "Widget trees"), since no widget kind draws a
dial. It is a pure function of the hour and minute, so the same minute
always gives the same bytes.

The picture is SIZE pixels square and transparent around the dial, so
it lies on whatever the renderer paints behind it: a white face with a soft shadow under it, sixty minute ticks, the twelve hour
ticks longer and darker, the hour and minute hands in the text colour
and a cap in the accent colour. Each shape is drawn by its distance from
the pixel's centre, a pixel covered in part blending its colour in that
part, so every edge is smooth; the layers are composed over one
another with premultiplied alpha. Rows are written unfiltered and deflated
by zlib, which keeps the picture well within the widget format's 48 KiB.
""".

-export([png/1, size/0]).

-define(SIZE, 440).
-define(CENTRE, 220.0).
-define(RADIUS, 200.0).
-define(SHADOW_DROP, 4.0).
-define(SHADOW_BLUR, 16.0).
-define(SHADOW_OPACITY, 0.10).

%% The theme's palette (abi/theme.txt): surface, line, text,
%% tertiary and accent.
-define(FACE, {16#FF, 16#FF, 16#FF}).
-define(RIM, {16#DD, 16#DC, 16#D7}).
-define(INK, {16#1B, 16#1C, 16#1E}).
-define(MINUTE_TICK, {16#8A, 16#8E, 16#94}).
-define(ACCENT, {16#0E, 16#7A, 16#6B}).
-define(SHADOW, {0, 0, 0}).
%% Nothing: a premultiplied colour of no opacity.
-define(CLEAR, {0.0, 0.0, 0.0, 0.0}).

-doc "The picture's width and height, in pixels.".
-spec size() -> pos_integer().
size() -> ?SIZE.

-doc "The dial showing the hour and minute of `Time`, as a PNG.".
-spec png(calendar:datetime()) -> binary().
png({_Date, {Hour, Minute, _Second}}) ->
    Hands = hands(Hour, Minute),
    Rows = [<<0, (row(Y, Hands))/binary>> || Y <- lists:seq(0, ?SIZE - 1)],
    encode(?SIZE, ?SIZE, zlib:compress(Rows)).

%% A hand: the unit vector it points along, how far it reaches past the
%% centre, how far its tail reaches behind it, its half width and colour.
-record(hand, {ux, uy, reach, tail, half, colour}).

hands(Hour, Minute) ->
    HourTurn = ((Hour rem 12) + Minute / 60) / 12,
    MinuteTurn = Minute / 60,
    [hand(HourTurn, 0.50 * ?RADIUS, 4.5),
     hand(MinuteTurn, 0.80 * ?RADIUS, 3.0)].

hand(Turn, Reach, Half) ->
    Angle = 2 * math:pi() * Turn,
    #hand{ux = math:sin(Angle), uy = -math:cos(Angle), reach = Reach,
          tail = 0.10 * ?RADIUS, half = Half, colour = ?INK}.

row(Y, Hands) ->
    << <<(pixel(X + 0.5 - ?CENTRE, Y + 0.5 - ?CENTRE, Hands))/binary>>
       || X <- lists:seq(0, ?SIZE - 1) >>.

%% One pixel at offset (Dx, Dy) from the centre, y downwards: the layers
%% composed bottom to top. Beyond the shadow's reach it is transparent.
pixel(Dx, Dy, Hands) ->
    R = math:sqrt(Dx * Dx + Dy * Dy),
    Colour = case R > ?RADIUS + ?SHADOW_DROP + ?SHADOW_BLUR of
                 true -> ?CLEAR;
                 false -> dial(Dx, Dy, R, Hands)
             end,
    bytes(Colour).

dial(Dx, Dy, R, Hands) ->
    Layers = [fun(C) -> shadow(C, Dx, Dy) end,
              fun(C) -> blend(C, ?FACE, cover(?RADIUS - R)) end,
              fun(C) -> blend(C, ?RIM, cover(0.5 - abs(R - ?RADIUS + 0.5))) end,
              fun(C) -> tick(C, Dx, Dy, R) end
              | [fun(C) -> draw_hand(C, Dx, Dy, Hand) end || Hand <- Hands]]
        ++ [fun(C) -> blend(C, ?ACCENT, cover(7.0 - R)) end,
            fun(C) -> blend(C, ?FACE, cover(2.5 - R)) end],
    lists:foldl(fun(Layer, C) -> Layer(C) end, ?CLEAR, Layers).

%% The face's shadow: black falling off with the square of the distance
%% past the edge of a face dropped a few pixels down.
shadow(Colour, Dx, Dy) ->
    Past = math:sqrt(Dx * Dx + (Dy - ?SHADOW_DROP) * (Dy - ?SHADOW_DROP)) - ?RADIUS,
    Fall = max(0.0, 1 - max(Past, 0.0) / ?SHADOW_BLUR),
    blend(Colour, ?SHADOW, ?SHADOW_OPACITY * Fall * Fall).

%% The tick nearest the pixel's angle, of the sixty: every fifth an hour
%% tick, longer, wider and darker.
tick(Colour, _Dx, _Dy, R) when R < ?RADIUS - 40; R > ?RADIUS - 8 ->
    Colour;
tick(Colour, Dx, Dy, _R) ->
    Index = round(math:atan2(Dx, -Dy) * 30 / math:pi()),
    Angle = Index * math:pi() / 30,
    {Inner, Half, Ink} = case Index rem 5 of
                             0 -> {?RADIUS - 36, 2.0, ?INK};
                             _ -> {?RADIUS - 22, 0.8, ?MINUTE_TICK}
                         end,
    Ux = math:sin(Angle),
    Uy = -math:cos(Angle),
    Distance = segment(Dx, Dy, Ux, Uy, Inner, ?RADIUS - 14),
    blend(Colour, Ink, cover(Half - Distance)).

draw_hand(Colour, Dx, Dy, #hand{ux = Ux, uy = Uy, reach = Reach, tail = Tail,
                                half = Half, colour = Ink}) ->
    blend(Colour, Ink, cover(Half - segment(Dx, Dy, Ux, Uy, -Tail, Reach))).

%% The distance from (Dx, Dy) to the segment along the unit vector
%% (Ux, Uy) from From to To past the centre.
segment(Dx, Dy, Ux, Uy, From, To) ->
    Along = min(max(Dx * Ux + Dy * Uy, From), To),
    Ex = Dx - Along * Ux,
    Ey = Dy - Along * Uy,
    math:sqrt(Ex * Ex + Ey * Ey).

%% How much of a pixel a shape covers whose edge lies Inside pixels from
%% the pixel's centre, inward positive: half at the edge, all of it a
%% half pixel in.
cover(Inside) ->
    min(1.0, max(0.0, Inside + 0.5)).

%% Ink of opacity Alpha over a premultiplied colour {R, G, B, A}.
blend(Colour, _Ink, Alpha) when Alpha =< 0.0 -> Colour;
blend({R, G, B, A}, {Ri, Gi, Bi}, Alpha) ->
    Keep = 1 - Alpha,
    {Ri * Alpha + R * Keep, Gi * Alpha + G * Keep, Bi * Alpha + B * Keep, Alpha + A * Keep}.

%% A premultiplied colour as PNG's straight RGBA bytes.
bytes({_R, _G, _B, A}) when A =< 0.0 ->
    <<0, 0, 0, 0>>;
bytes({R, G, B, A}) ->
    <<(round(R / A)), (round(G / A)), (round(B / A)), (round(A * 255))>>.

%% A PNG of 8-bit RGBA, its pixels the deflated rows, each led by filter
%% type 0, none.
encode(Width, Height, Deflated) ->
    Header = <<Width:32, Height:32, 8, 6, 0, 0, 0>>,
    iolist_to_binary([<<137, "PNG", 13, 10, 26, 10>>,
                      chunk(<<"IHDR">>, Header), chunk(<<"IDAT">>, Deflated),
                      chunk(<<"IEND">>, <<>>)]).

chunk(Type, Data) ->
    [<<(byte_size(Data)):32>>, Type, Data,
     <<(erlang:crc32([Type, Data])):32>>].
