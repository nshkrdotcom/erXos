%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dashboard_pictures).
-moduledoc """
The dashboard's pictures other than the dial, and the one PNG encoder
the dashboard's pictures share. Each is a pure function, so the same
arguments always give the same bytes, and each stays within the widget
format's 48 KiB (abi/formats/ui.txt, ui_picture_bytes).

ground/1 is the screen's ground, the Dusk look: a diagonal gradient from
indigo at the top left through plum to petrol at the bottom right, with
a soft plum glow behind the clock. erx-lvgl does not scale a picture and
the dashboard does not learn its window's size, so the ground is drawn
at GROUND_WIDTH by GROUND_HEIGHT, a 1920x1080 screen, which the Raspberry
Pi 4's card drives whole (its config.txt turns overscan off), and the
renderer centres it in the window and clips it: a smaller screen, QEMU's
1280x800, shows its middle. The glow is placed by its offset from the
centre, which the view's layout keeps the same at every width
(erx_dashboard_view:clock_offset/0).

Every colour of the ground lies on one path, indigo to plum to petrol,
and the glow pulls a pixel's place on that path towards plum rather than
adding a second colour; so the picture has one palette of at most 256
colours, the path's colours in order, and is an indexed PNG of a byte a
pixel that stays within the 48 KiB cap, with little room to spare; a
truecolour PNG of the same ground is over it.

rule/1 is a hairline: one row of white at 12 percent, which separates the
quotes panel's blocks in place of a card's edge.
""".

-export([ground/1, rule/1, rgba/3]).

-define(GROUND_WIDTH, 1920).
-define(GROUND_HEIGHT, 1080).
%% The glow's radius, in pixels, and how far it pulls towards plum at its
%% centre, as a fraction of the way.
-define(GLOW_RADIUS, 560).
-define(GLOW_PULL, 0.9).
%% The path's colours, where it is at 0, at 0.5 (the plum the glow pulls
%% to) and at 1.
-define(STOPS, [{0.0, {16#0D, 16#0F, 16#2A}},
                {0.5, {16#2C, 16#20, 16#60}},
                {1.0, {16#0B, 16#3B, 16#57}}]).
%% Places on the path the palette is sampled at: finer than any
%% channel's step, so every colour of the path is one of them.
-define(STEPS, 1024).
-define(RULE_ALPHA, 31).

-doc """
The ground, as a PNG, with the glow centred `{Dx, Dy}` pixels from the
picture's centre.
""".
-spec ground({integer(), integer()}) -> binary().
ground({Dx, Dy}) ->
    {Palette, Index} = palette(),
    Cx = ?GROUND_WIDTH / 2 + Dx,
    Cy = ?GROUND_HEIGHT / 2 + Dy,
    Rows = [<<0, (ground_row(Y + 0.5, Cx, Cy, Index))/binary>>
            || Y <- lists:seq(0, ?GROUND_HEIGHT - 1)],
    indexed(?GROUND_WIDTH, ?GROUND_HEIGHT, Palette, zlib:compress(Rows)).

ground_row(Y, Cx, Cy, Index) ->
    << <<(element(round(place(X + 0.5, Y, Cx, Cy) * (?STEPS - 1)) + 1, Index))>>
       || X <- lists:seq(0, ?GROUND_WIDTH - 1) >>.

%% A pixel's place on the path: along the diagonal, pulled towards plum
%% by the glow, which falls off smoothly to nothing at its radius.
place(X, Y, Cx, Cy) ->
    Diagonal = (X / ?GROUND_WIDTH + Y / ?GROUND_HEIGHT) / 2,
    D2 = ((X - Cx) * (X - Cx) + (Y - Cy) * (Y - Cy)) / (?GLOW_RADIUS * ?GLOW_RADIUS),
    Pull = ?GLOW_PULL * math:pow(max(0.0, 1 - D2), 2),
    Diagonal + Pull * (0.5 - Diagonal).

%% The path's distinct colours, sorted, and for each of its ?STEPS places
%% the index of its colour among them, as a tuple.
palette() ->
    Colours = [path_colour(Step / (?STEPS - 1)) || Step <- lists:seq(0, ?STEPS - 1)],
    Palette = lists:usort(Colours),
    Numbered = maps:from_list(lists:zip(Palette, lists:seq(0, length(Palette) - 1))),
    {Palette, list_to_tuple([maps:get(Colour, Numbered) || Colour <- Colours])}.

path_colour(T) ->
    {{T0, {R0, G0, B0}}, {T1, {R1, G1, B1}}} = segment(T, ?STOPS),
    F = (T - T0) / (T1 - T0),
    {round(R0 + (R1 - R0) * F), round(G0 + (G1 - G0) * F), round(B0 + (B1 - B0) * F)}.

segment(T, [Low, {T1, _} = High | _]) when T =< T1 -> {Low, High};
segment(T, [_ | Rest]) -> segment(T, Rest).

-doc "A hairline `Width` pixels long and one high, as a PNG.".
-spec rule(pos_integer()) -> binary().
rule(Width) ->
    Row = binary:copy(<<255, 255, 255, ?RULE_ALPHA>>, Width),
    rgba(Width, 1, zlib:compress([<<0>>, Row])).

-doc """
A PNG of 8-bit RGBA, its pixels `Deflated`, the zlib stream of its rows,
each led by its filter type.
""".
-spec rgba(pos_integer(), pos_integer(), binary()) -> binary().
rgba(Width, Height, Deflated) ->
    png(<<Width:32, Height:32, 8, 6, 0, 0, 0>>, [], Deflated).

%% A PNG of a byte a pixel, each an index into Palette, a list of at most
%% 256 {R, G, B}.
indexed(Width, Height, Palette, Deflated) when length(Palette) =< 256 ->
    png(<<Width:32, Height:32, 8, 3, 0, 0, 0>>,
        [chunk(<<"PLTE">>, << <<R, G, B>> || {R, G, B} <- Palette >>)], Deflated).

png(Header, Chunks, Deflated) ->
    iolist_to_binary([<<137, "PNG", 13, 10, 26, 10>>, chunk(<<"IHDR">>, Header),
                      Chunks, chunk(<<"IDAT">>, Deflated), chunk(<<"IEND">>, <<>>)]).

chunk(Type, Data) ->
    [<<(byte_size(Data)):32>>, Type, Data, <<(erlang:crc32([Type, Data])):32>>].
