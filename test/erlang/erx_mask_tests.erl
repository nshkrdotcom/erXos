%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_mask_tests).
-moduledoc """
erx_mask's coverage masks against areas worked out from the shapes'
definitions (docs/design-desktop-programs.md, "Verification and testing",
the raster step), never from erx_mask's own route to them:

* a quarter disc sums to its area, and each row to the integral of the
  disc's width over the row; a ring sums to its annulus;
* a straight stroke of any slope covers each pixel by the area of its
  square inside the line's band, counted by sampling points; a capsule and a
  dot sum to their areas, and nothing lies beyond a cap;
* the region below a line covers each pixel by its exact area;
* a shadow's strip is the closed form of a step blurred by the cut-off
  Gaussian, its corner agrees with a direct two-dimensional blur of the
  sampled rounded shape, and the corner meets the strips without a seam.

A mask byte B stands for coverage B / 255. A pixel is exact when its byte is
within one step of the true area times 255, and a sum is exact when it is
within half a step for each pixel its rounding can move.
""".
-include_lib("eunit/include/eunit.hrl").

-define(CORNERS, [top_left, top_right, bottom_left, bottom_right]).

%%% Corners

%% Each quarter disc of radius 1 to 32 sums to a quarter of pi R^2 within one
%% part in a thousand. A one-pixel disc can come no closer than its one
%% byte's rounding (pi / 4 is 200.28 steps), so the bound is at least half a
%% step. Row by row, the top-left disc's row J holds the integral of the
%% disc's width over that row.
quarter_disc_sums_to_its_area_test() ->
    [begin
         Mask = erx_mask:quarter_disc(Corner, R),
         Area = math:pi() * R * R / 4,
         expect({disc, R, Corner},
                abs(coverage_sum(bytes(Mask)) - Area) =<
                    max(Area / 1000, 0.5 / 255))
     end || R <- lists:seq(1, 32), Corner <- ?CORNERS],
    [expect({disc_row, R, J},
            within_rounding(row(erx_mask:quarter_disc(top_left, R), J),
                            disc_row_area(R, J)))
     || R <- lists:seq(1, 32), J <- lists:seq(0, R - 1)].

%% The ring of a hairline sums to the quarter annulus between R and R - 1.
%% A thin ring's area is too small for one part in a thousand to exceed its
%% rounding, so the bound is the rounding.
quarter_ring_sums_to_its_area_test() ->
    [expect({ring, R, Corner},
            within_rounding(bytes(erx_mask:quarter_ring(Corner, R, 1)),
                            math:pi() * (R * R - (R - 1) * (R - 1)) / 4))
     || R <- lists:seq(1, 32), Corner <- ?CORNERS].

%% A corner is full at the disc's centre and empty at the rectangle's
%% corner, wherever the corner is.
corner_orientation_test() ->
    R = 8,
    Expected = [{top_left, {R - 1, R - 1}, {0, 0}},
                {top_right, {0, R - 1}, {R - 1, 0}},
                {bottom_left, {R - 1, 0}, {0, R - 1}},
                {bottom_right, {0, 0}, {R - 1, R - 1}}],
    [begin
         Mask = erx_mask:quarter_disc(Corner, R),
         ?assertEqual({Corner, 255, 0},
                      {Corner, pixel(Mask, Centre), pixel(Mask, Outer)})
     end || {Corner, Centre, Outer} <- Expected].

%%% Strokes

%% A horizontal line, its caps outside the mask, covers each column's rows by
%% their overlap with the band [Y - W/2, Y + W/2], so each column sums to the
%% line's width. The offsets put the band's edges on, between and across
%% pixel boundaries.
stroke_column_coverage_test() ->
    [check_horizontal_stroke(Y, LineWidth)
     || Y <- [5.0, 5.25, 5.5, 5.8], LineWidth <- [1, 1.5, 2, 3.2]].

check_horizontal_stroke(Y, LineWidth) ->
    {Width, Height} = {12, 10},
    Mask = erx_mask:stroke(Width, Height, [{-3, Y}, {Width + 3, Y}],
                           LineWidth),
    Band = {Y - LineWidth / 2, Y + LineWidth / 2},
    [begin
         Case = {line_at, Y, width, LineWidth, column, I},
         Column = column(Mask, I),
         ?assertEqual({Case, ok},
                      {Case, near_steps(Column,
                                        [overlap({J, J + 1}, Band)
                                         || J <- lists:seq(0, Height - 1)])}),
         expect(Case, abs(coverage_sum(Column) - LineWidth) =<
                          Height * 0.5 / 255)
     end || I <- lists:seq(0, Width - 1)].

%% A vertical line covers each row by its width the same way.
stroke_row_coverage_test() ->
    {X, LineWidth} = {4.3, 1.5},
    Mask = erx_mask:stroke(10, 6, [{X, -3}, {X, 9}], LineWidth),
    Band = {X - LineWidth / 2, X + LineWidth / 2},
    [?assertEqual({row, J, ok},
                  {row, J, near_steps(row(Mask, J),
                                      [overlap({I, I + 1}, Band)
                                       || I <- lists:seq(0, 9)])})
     || J <- lists:seq(0, 5)].

%% A sloped line, its caps outside the mask, covers each pixel by the area
%% of its square inside the line's band, counted over a 64 by 64 grid of
%% points in the square.
stroke_slope_coverage_test() ->
    [check_sloped_stroke(Slope, LineWidth)
     || Slope <- [0.4, 1.0, 2.3], LineWidth <- [1, 1.5, 2.5]].

check_sloped_stroke(Slope, LineWidth) ->
    {Width, Height} = {10, 8},
    Line = fun(X) -> 4.1 + Slope * (X - 5) end,
    Mask = erx_mask:stroke(Width, Height,
                           [{-20, Line(-20)}, {30, Line(30)}], LineWidth),
    %% A point's distance from the line y = Line(x), across the line.
    Across = fun({X, Y}) ->
                     abs(Y - Line(X)) / math:sqrt(1 + Slope * Slope)
             end,
    Expected = [[sampled_coverage(I, J, fun(P) ->
                                               Across(P) =< LineWidth / 2
                                       end)
                 || I <- lists:seq(0, Width - 1)]
                || J <- lists:seq(0, Height - 1)],
    [?assertEqual({slope, Slope, width, LineWidth, row, J, ok},
                  {slope, Slope, width, LineWidth, row, J,
                   near_bytes(row(Mask, J), [C * 255 || C <- Want], 2)})
     || {J, Want} <- lists:zip(lists:seq(0, Height - 1), Expected)].

%% A segment inside the mask is a capsule, its length by its width and a
%% disc of its width, and nothing more than a pixel beyond its outline is
%% covered.
stroke_capsule_test() ->
    {A, B, LineWidth} = {{4.2, 5.1}, {19.7, 12.6}, 2.4},
    {Width, Height} = {24, 18},
    Mask = erx_mask:stroke(Width, Height, [A, B], LineWidth),
    Half = LineWidth / 2,
    Area = distance(A, B) * LineWidth + math:pi() * Half * Half,
    expect({capsule_area, coverage_sum(bytes(Mask)), Area},
           abs(coverage_sum(bytes(Mask)) - Area) =< Area / 100),
    Outside = [{I, J} || I <- lists:seq(0, Width - 1),
                         J <- lists:seq(0, Height - 1),
                         segment_distance({I + 0.5, J + 0.5}, A, B) >
                             Half + 1,
                         pixel(Mask, {I, J}) =/= 0],
    ?assertEqual([], Outside).

%% A dot, one point, and a zigzag's sharp joins cover each pixel by the area
%% of its square inside the union of the segments' capsules, counted over a
%% 64 by 64 grid of points in the square. A thin dot is mostly edge pixels,
%% and a graph's peaks are joins.
stroke_dot_test() ->
    [check_stroke_union({dot, Point, LineWidth}, [Point], LineWidth)
     || Point <- [{4.3, 4.6}, {3.5, 3.5}], LineWidth <- [1, 1.5, 4]].

stroke_join_test() ->
    Zigzag = [{0.5, 6.5}, {3.5, 1.5}, {6.5, 6.2}, {8.0, 0.8}, {9.5, 6.5}],
    [check_stroke_union({zigzag, LineWidth}, Zigzag, LineWidth)
     || LineWidth <- [1, 1.5, 2]].

check_stroke_union(Case, Points, LineWidth) ->
    {Width, Height} = {10, 8},
    Mask = erx_mask:stroke(Width, Height, Points, LineWidth),
    Segments = case Points of
                   [Point] -> [{Point, Point}];
                   _ -> lists:zip(lists:droplast(Points), tl(Points))
               end,
    Inside = fun(P) ->
                     lists:any(fun({A, B}) ->
                                       segment_distance(P, A, B) =<
                                           LineWidth / 2
                               end, Segments)
             end,
    [?assertEqual({Case, row, J, ok},
                  {Case, row, J,
                   near_bytes(row(Mask, J),
                              [sampled_coverage(I, J, Inside) * 255
                               || I <- lists:seq(0, Width - 1)], 4)})
     || J <- lists:seq(0, Height - 1)].

%% A polyline that leaves the mask is clipped: its part inside is the part
%% inside of the segment that crosses the mask's edge.
stroke_leaving_the_mask_test() ->
    Inside = erx_mask:stroke(10, 10, [{5, 5}, {20, 5}], 1),
    ?assertEqual(Inside,
                 erx_mask:stroke(10, 10, [{5, 5}, {20, 5}, {30, 5}], 1)),
    ?assertEqual({10, 10, binary:copy(<<0>>, 100)},
                                  erx_mask:stroke(10, 10, [{0, -10}, {10, -10}], 1)).

%% A stroke is a graph's line: its points' x never decreases.
stroke_refuses_falling_x_test() ->
    ?assertError(badarg, erx_mask:stroke(10, 10, [{5, 5}, {4, 6}], 1)).

%%% Areas

%% Below a horizontal line, each pixel's coverage is its row's overlap with
%% [Y, Height].
area_below_horizontal_line_test() ->
    {Width, Height, Y} = {6, 5, 2.3},
    Mask = erx_mask:area(Width, Height, [{0, Y}, {Width, Y}]),
    [?assertEqual({column, I, ok},
                  {column, I, near_steps(column(Mask, I),
                                         [overlap({J, J + 1}, {Y, Height})
                                          || J <- lists:seq(0, Height - 1)])})
     || I <- lists:seq(0, Width - 1)].

%% Below a sloped line, each column holds the trapezoid between the line and
%% the bottom edge.
area_below_sloped_line_test() ->
    {Width, Height} = {8, 6},
    Line = fun(X) -> 0.7 + 0.55 * X end,
    Mask = erx_mask:area(Width, Height, [{0, Line(0)}, {Width, Line(Width)}]),
    [begin
         Trapezoid = Height - (Line(I) + Line(I + 1)) / 2,
         expect({column, I}, abs(coverage_sum(column(Mask, I)) - Trapezoid) =<
                                 Height * 0.5 / 255)
     end || I <- lists:seq(0, Width - 1)].

area_refuses_falling_x_test() ->
    ?assertError(badarg, erx_mask:area(4, 4, [{0, 1}, {3, 2}, {2, 3}])).

%%% Shadows

%% A strip is a straight edge blurred by the Gaussian of standard deviation
%% Blur / 2 cut off at Blur: at the pixel whose top is Y below the edge it is
%% the cut-off Gaussian's mass on that pixel's side of the edge, which the
%% error function gives in closed form.
shadow_edge_is_a_blurred_step_test() ->
    Blur = 12,
    Scale = Blur / 2 * math:sqrt(2),
    Cut = math:erf((Blur + 0.5) / Scale),
    Profile = [(Cut + math:erf((Y + 0.5) / Scale)) / (2 * Cut) * 255
               || Y <- lists:seq(-Blur, Blur - 1)],
    Reversed = lists:reverse(Profile),
    [?assertEqual({Side, ok}, {Side, near_bytes(strip(Side, Blur), Want, 1)})
     || {Side, Want} <- [{top, Profile}, {bottom, Reversed},
                         {left, Profile}, {right, Reversed}]],
    ?assertMatch({1, 24, _}, erx_mask:shadow_edge(top, Blur)),
    ?assertMatch({24, 1, _}, erx_mask:shadow_edge(left, Blur)).

%% A corner of the shadow is the rounded corner, its coverage sampled over
%% an 8 by 8 grid of points a pixel, blurred directly in two dimensions by
%% the cut-off Gaussian's pixel masses. Checked along the diagonal, where
%% the arc matters most, and across it.
shadow_corner_matches_a_direct_blur_test() ->
    {R, Blur} = {10, 12},
    Mask = erx_mask:shadow_corner(top_left, R, Blur),
    Shape = sampled_rounded_corner(R, Blur),
    Weights = gaussian_masses(Blur),
    Pixels = [{K, K} || K <- lists:seq(0, R + 2 * Blur - 1, 3)] ++
                 [{6, 20}, {20, 6}, {14, 30}, {30, 14}],
    [begin
         Want = direct_blur(Shape, Weights, Blur, {X - Blur, Y - Blur}) * 255,
         Got = pixel(Mask, {X, Y}),
         expect({shadow_corner, {X, Y}, Got, Want}, abs(Got - Want) =< 2)
     end || {X, Y} <- Pixels].

%% A corner's column and row next to the sides' strips are those strips, so
%% the corners and the strips meet without a seam.
shadow_corner_meets_edges_test() ->
    {R, Blur} = {10, 12},
    Side = R + 2 * Blur,
    TopLeft = erx_mask:shadow_corner(top_left, R, Blur),
    BottomRight = erx_mask:shadow_corner(bottom_right, R, Blur),
    ?assertMatch({Side, Side, _}, TopLeft),
    Inside = lists:duplicate(R, 255),
    [?assertEqual({Part, ok}, {Part, near_bytes(Got, Want, 1)})
     || {Part, Got, Want} <-
            [{top_left_column, column(TopLeft, Side - 1),
              strip(top, Blur) ++ Inside},
             {top_left_row, row(TopLeft, Side - 1),
              strip(left, Blur) ++ Inside},
             {bottom_right_column, column(BottomRight, 0),
              Inside ++ strip(bottom, Blur)},
             {bottom_right_row, row(BottomRight, 0),
              Inside ++ strip(right, Blur)}]].

%%% Oracles

%% The area of row J of the top-left quarter disc of radius R: the integral
%% of the disc's half-width sqrt(R^2 - v^2) over the row's distance v from
%% the centre, R - J - 1 to R - J.
disc_row_area(R, J) ->
    Width = fun(V) ->
                    (V * math:sqrt(R * R - V * V) + R * R * math:asin(V / R))
                        / 2
            end,
    Width(R - J) - Width(R - J - 1).

%% The fraction of the 64 by 64 points of pixel (I, J) for which Inside holds.
sampled_coverage(I, J, Inside) ->
    Steps = [(K + 0.5) / 64 || K <- lists:seq(0, 63)],
    length([1 || Dx <- Steps, Dy <- Steps, Inside({I + Dx, J + Dy})]) / 4096.

%% The coverage of each pixel of a rounded top-left corner of radius R, over
%% an 8 by 8 grid of points: the points right of x = 0 and below y = 0 that
%% are not in the R-square outside the disc about (R, R). Keyed by pixel,
%% from 2 Blur outside the corner to R + 2 Blur inside it.
sampled_rounded_corner(R, Blur) ->
    Steps = [(K + 0.5) / 8 || K <- lists:seq(0, 7)],
    Inside = fun(X, Y) ->
                     X >= 0 andalso Y >= 0 andalso
                         not (X < R andalso Y < R andalso
                              square(X - R) + square(Y - R) > R * R)
             end,
    Range = lists:seq(-2 * Blur, R + 2 * Blur - 1),
    maps:from_list(
      [{{I, J}, length([1 || Dx <- Steps, Dy <- Steps,
                             Inside(I + Dx, J + Dy)]) / 64}
       || I <- Range, J <- Range]).

%% The mass of the Gaussian of standard deviation Blur / 2 on each pixel
%% from -Blur to Blur, scaled so the cut-off masses sum to one.
gaussian_masses(Blur) ->
    Scale = Blur / 2 * math:sqrt(2),
    Cut = math:erf((Blur + 0.5) / Scale),
    [(math:erf((K + 0.5) / Scale) - math:erf((K - 0.5) / Scale)) / (2 * Cut)
     || K <- lists:seq(-Blur, Blur)].

%% The two-dimensional blur at pixel (X, Y) of the corner: every pair of
%% offsets weighted by the product of their masses.
direct_blur(Shape, Weights, Blur, {X, Y}) ->
    Offsets = lists:zip(lists:seq(-Blur, Blur), Weights),
    lists:sum([Wx * Wy * maps:get({X + Dx, Y + Dy}, Shape)
               || {Dx, Wx} <- Offsets, {Dy, Wy} <- Offsets]).

segment_distance(P, A, B) ->
    {Ax, Ay} = A,
    {Dx, Dy} = {element(1, B) - Ax, element(2, B) - Ay},
    {Px, Py} = P,
    T = case Dx * Dx + Dy * Dy of
            +0.0 -> 0.0;
            Length2 -> max(0.0, min(1.0, ((Px - Ax) * Dx + (Py - Ay) * Dy) /
                                             Length2))
        end,
    distance(P, {Ax + T * Dx, Ay + T * Dy}).

distance({X0, Y0}, {X1, Y1}) ->
    math:sqrt(square(X1 - X0) + square(Y1 - Y0)).

square(V) ->
    V * V.

%% The length of the overlap of two spans.
overlap({Low1, High1}, {Low2, High2}) ->
    max(0.0, min(High1, High2) - max(Low1, Low2)).

%%% Helpers

expect(Case, Holds) ->
    ?assertEqual({Case, true}, {Case, Holds}).

bytes({_Width, _Height, Bytes}) ->
    binary_to_list(Bytes).

coverage_sum(Bytes) ->
    lists:sum(Bytes) / 255.

%% Whether the bytes sum to Area within half a step for each covered
%% pixel: a pixel whose area is not whole may still round to 255, and one
%% that rounds to 0 is off by under half a step.
within_rounding(Bytes, Area) ->
    Covered = length([B || B <- Bytes, B > 0]),
    abs(coverage_sum(Bytes) - Area) =< max(Covered, 1) * 0.5 / 255.

pixel({Width, _Height, Bytes}, {I, J}) ->
    binary:at(Bytes, J * Width + I).

column({_Width, Height, _} = Mask, I) ->
    [pixel(Mask, {I, J}) || J <- lists:seq(0, Height - 1)].

row({Width, _Height, _} = Mask, J) ->
    [pixel(Mask, {I, J}) || I <- lists:seq(0, Width - 1)].

strip(Side, Blur) ->
    bytes(erx_mask:shadow_edge(Side, Blur)).

%% ok when each byte is within one step of its coverage, or the first pair
%% that is not.
near_steps(Bytes, Coverages) ->
    near_bytes(Bytes, [Coverage * 255 || Coverage <- Coverages], 1).

near_bytes(Bytes, Expected, _Steps) when length(Bytes) =/= length(Expected) ->
    {lengths, length(Bytes), length(Expected)};
near_bytes(Bytes, Expected, Steps) ->
    case [{Byte, Want} || {Byte, Want} <- lists:zip(Bytes, Expected),
                          abs(Byte - Want) > Steps] of
        [] -> ok;
        [First | _] -> {differs, First}
    end.
