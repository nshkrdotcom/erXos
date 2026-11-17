%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dashboard_clock).
-moduledoc """
The dashboard's analog clock as a picture: png/2 draws the dial for a
wall-clock reading as a PNG in one of the theme's palettes, which the
view shows in an `image` node (docs/design-display.md, "Widget trees"),
since no widget kind draws a dial. It is a pure function of the palette,
the hour and the minute, so the same minute always gives the same bytes.

The picture is SIZE pixels square and transparent but for the dial, so
it lies on whatever the renderer paints behind it, the dashboard's
ground. The dial has no face: a faint ring in the text colour, the
twelve hour ticks, an arc in the accent colour along the ring from
twelve to the minute hand, the hour's progress, with a soft glow of the
same colour around it, the hour and minute hands in the text colour
over a soft shadow, and an amber cap with a dot of the window colour.
The cap's amber is the dashboard's own constant, as the theme has no
amber of that meaning. Each shape is drawn by its distance from the
pixel's centre, a pixel covered in part blending its colour in that
part, so every edge is smooth; the layers are composed over one another
with premultiplied alpha. Rows are written unfiltered and deflated by
zlib, which keeps the picture well within the widget format's 48 KiB.
""".

-export([png/2, size/0]).

-define(SIZE, 440).
-define(CENTRE, 220.0).
-define(RADIUS, 200.0).
-define(RING_OPACITY, 0.16).
-define(ARC_HALF, 2.0).
-define(GLOW_REACH, 10.0).
-define(GLOW_OPACITY, 0.30).
-define(SHADOW_DROP, 3.0).
-define(SHADOW_BLUR, 6.0).
-define(SHADOW_OPACITY, 0.30).
-define(CAP, {16#FF, 16#B5, 16#47}).

-define(SHADOW, {0, 0, 0}).
%% Nothing: a premultiplied colour of no opacity.
-define(CLEAR, {0.0, 0.0, 0.0, 0.0}).

-doc "The picture's width and height, in pixels.".
-spec size() -> pos_integer().
size() -> ?SIZE.

-doc "The dial showing the hour and minute of `Time` in `Palette`, as a PNG.".
-spec png(erx_theme:palette(), calendar:datetime()) -> binary().
png(Palette, {_Date, {Hour, Minute, _Second}}) ->
    Paint = paint(Palette),
    Hands = hands(Hour, Minute),
    Arc = 2 * math:pi() * Minute / 60,
    Rows = [<<0, (row(Y, Hands, Arc, Paint))/binary>> || Y <- lists:seq(0, ?SIZE - 1)],
    erx_dashboard_pictures:rgba(?SIZE, ?SIZE, zlib:compress(Rows)).

%% A hand: the unit vector it points along, how far it reaches past the
%% centre, how far its tail reaches behind it, and its half width.
-record(hand, {ux, uy, reach, tail, half}).

%% The dial's colours, from the theme's (abi/theme.txt): the ring, ticks
%% and hands the text, the arc the accent, the cap's dot the window; each
%% {R, G, B}.
paint(Palette) ->
    maps:from_list([{Part, rgb(erx_theme:color(Palette, Name))}
                    || {Part, Name} <- [{ink, text}, {accent, accent}, {dot, window}]]).

rgb(Rgba) ->
    <<R, G, B, _A>> = <<Rgba:32>>,
    {R, G, B}.

hands(Hour, Minute) ->
    [hand(((Hour rem 12) + Minute / 60) / 12, 0.50 * ?RADIUS, 5.0),
     hand(Minute / 60, 0.80 * ?RADIUS, 3.0)].

hand(Turn, Reach, Half) ->
    Angle = 2 * math:pi() * Turn,
    #hand{ux = math:sin(Angle), uy = -math:cos(Angle), reach = Reach,
          tail = 0.10 * ?RADIUS, half = Half}.

row(Y, Hands, Arc, Paint) ->
    << <<(pixel(X + 0.5 - ?CENTRE, Y + 0.5 - ?CENTRE, Hands, Arc, Paint))/binary>>
       || X <- lists:seq(0, ?SIZE - 1) >>.

%% One pixel at offset (Dx, Dy) from the centre, y downwards: the layers
%% composed bottom to top. Beyond the arc's glow it is transparent.
pixel(Dx, Dy, Hands, Arc, Paint) ->
    R = math:sqrt(Dx * Dx + Dy * Dy),
    Colour = case R > ?RADIUS + ?ARC_HALF + ?GLOW_REACH of
                 true -> ?CLEAR;
                 false -> dial(Dx, Dy, R, Hands, Arc, Paint)
             end,
    bytes(Colour).

dial(Dx, Dy, R, Hands, Arc, #{ink := Ink, accent := Accent, dot := Dot}) ->
    ArcDistance = arc_distance(Dx, Dy, R, Arc),
    Layers = [fun(C) -> blend(C, Ink, ?RING_OPACITY * cover(0.75 - abs(R - ?RADIUS))) end,
              fun(C) -> glow(C, Accent, ArcDistance) end,
              fun(C) -> blend(C, Accent, cover(?ARC_HALF - ArcDistance)) end,
              fun(C) -> tick(C, Dx, Dy, R, Ink) end]
        ++ [fun(C) -> shadow(C, Dx, Dy, Hand) end || Hand <- Hands]
        ++ [fun(C) -> blend(C, Ink, cover(Hand#hand.half - hand_distance(Dx, Dy, Hand))) end
            || Hand <- Hands]
        ++ [fun(C) -> blend(C, ?CAP, cover(8.0 - R)) end,
            fun(C) -> blend(C, Dot, cover(3.0 - R)) end],
    lists:foldl(fun(Layer, C) -> Layer(C) end, ?CLEAR, Layers).

%% The distance from the pixel to the arc along the ring from twelve,
%% clockwise, through Arc radians; its ends are round. At minute 0 there
%% is no arc, and every pixel lies beyond its glow.
arc_distance(_Dx, _Dy, _R, Arc) when Arc == 0 ->
    ?RADIUS;
arc_distance(Dx, Dy, R, Arc) ->
    Angle = case math:atan2(Dx, -Dy) of
                A when A < 0 -> A + 2 * math:pi();
                A -> A
            end,
    case Angle =< Arc of
        true ->
            abs(R - ?RADIUS);
        false ->
            min(point_distance(Dx, Dy, 0.0), point_distance(Dx, Dy, Arc))
    end.

point_distance(Dx, Dy, Angle) ->
    Ex = Dx - ?RADIUS * math:sin(Angle),
    Ey = Dy + ?RADIUS * math:cos(Angle),
    math:sqrt(Ex * Ex + Ey * Ey).

%% The arc's glow: its colour falling off with the square of the distance
%% past its stroke.
glow(Colour, Accent, Distance) ->
    Fall = max(0.0, 1 - max(Distance - ?ARC_HALF, 0.0) / ?GLOW_REACH),
    blend(Colour, Accent, ?GLOW_OPACITY * Fall * Fall).

%% The hour tick nearest the pixel's angle, of the twelve.
tick(Colour, _Dx, _Dy, R, _Ink) when R < ?RADIUS - 44; R > ?RADIUS - 10 ->
    Colour;
tick(Colour, Dx, Dy, _R, Ink) ->
    Angle = round(math:atan2(Dx, -Dy) * 6 / math:pi()) * math:pi() / 6,
    Distance = segment(Dx, Dy, math:sin(Angle), -math:cos(Angle), ?RADIUS - 40, ?RADIUS - 16),
    blend(Colour, Ink, cover(2.0 - Distance)).

%% A hand's shadow: black falling off over the blur past the edge of the
%% hand dropped a few pixels down.
shadow(Colour, Dx, Dy, #hand{half = Half} = Hand) ->
    Past = hand_distance(Dx, Dy - ?SHADOW_DROP, Hand) - Half,
    Fall = max(0.0, 1 - max(Past, 0.0) / ?SHADOW_BLUR),
    blend(Colour, ?SHADOW, ?SHADOW_OPACITY * Fall * Fall).

hand_distance(Dx, Dy, #hand{ux = Ux, uy = Uy, reach = Reach, tail = Tail}) ->
    segment(Dx, Dy, Ux, Uy, -Tail, Reach).

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
