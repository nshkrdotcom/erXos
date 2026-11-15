%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_mask).
-moduledoc """
The coverage masks of the desktop's non-rectangular pixels
(docs/design-desktop-programs.md, "Anti-aliasing, corners and depth:
coverage masks"): the corners of rounded rectangles and of their hairline
borders, the parts of a section's soft shadow, and a graph's line and the
area below it. Each function is pure and returns the bytes of a `k8` image:
one byte a pixel, rows top to bottom, 0 for no coverage and 255 for full,
which `libmemdraw`'s draw reads as the mask of a colour.

**Pixels are squares.** Pixel (I, J) of a mask is the unit square whose
centre is (I + 0.5, J + 0.5), in coordinates whose origin is the mask's
top-left corner and whose y grows downwards. A pixel's coverage is the area
of that square inside the shape, so a mask carries sub-pixel position: a
line at y = 10.25 and one at y = 10.75 give different bytes.

**Corners.** `quarter_disc/2` and `quarter_ring/3` are R by R masks drawn
with their outer corner on the rectangle's: the top-left mask at the
rectangle's top-left pixel, the top-right one R pixels left of its right
edge, and so on. Each pixel holds its exact area inside the disc of radius R
centred on the mask's inner corner (for the ring, inside that disc and
outside the one of radius R - Width), so a rounded rectangle is its
rectangle fills and four corner draws, with no seam between them.

**Shadows.** A shadow is the rounded rectangle's shape blurred as CSS's
`box-shadow` approximately blurs it: convolved with a Gaussian whose
standard deviation is half the blur, cut off at the blur and scaled back to
unit mass, so the shadow reaches Blur pixels beyond the shape and is fully
covered Blur pixels inside it. Along a straight side the blurred shape
varies only across the side, so the shadow is four corners and four
one-pixel strips: `shadow_corner/3` is the (R + 2 Blur)-square around a
corner, from Blur pixels outside the shape to R + Blur inside it, and
`shadow_edge/2` is the strip across a side, Blur pixels outside and Blur
inside, drawn with the replicate bit along the side between the corners.
Inside both, the shadow is full coverage and the section covers it. The
shadow's offset and opacity are the caller's: the masks are drawn at the
offset, through a colour whose alpha is the opacity. The parts tile without
a seam when the rectangle is at least 2 (R + Blur) wide and high, and the
section covers the full interior when the offset is at most Blur on each
axis.

**Graphs.** `stroke/4` is a polyline stroked with round joins and caps:
the union of one capsule a segment, the points within half the line's
width of it. A pixel that one segment alone reaches, and wholly within
that segment's run, lies along a straight edge, and its coverage is the
exact area of its square inside the band the segment's capsule is there;
one wholly beyond an end of the segment is its exact area inside the disc
about that end. A pixel that one capsule holds whole is covered. Every
other pixel, across an end's line or partly covered by several segments,
integrates over its height the length of each row's part inside the union:
a capsule meets a row in one interval, so each row's length is exact, and
three-point Gauss-Legendre quadrature between the heights where an outline
turns or crosses the pixel's sides is exact along sides and within about
one coverage step where a row's length grows as a square root, at an arc's
top or bottom, and within about two where two outlines cross inside a
piece, as at a join's inner corner. A pixel's time grows with the square
of the number of segments that reach it, which a graph's rising x and at
most 240 samples bound.

`area/3` is the region below a polyline whose x never decreases, to the
mask's bottom edge, each pixel's coverage its exact area in that region.
""".

-export([quarter_disc/2, quarter_ring/3, shadow_corner/3, shadow_edge/2,
         stroke/4, area/3]).

-type corner() :: top_left | top_right | bottom_left | bottom_right.
-type side() :: top | bottom | left | right.
-type point() :: {number(), number()}.
-type mask() :: {Width :: pos_integer(), Height :: pos_integer(),
                 Coverage :: binary()}.
-export_type([corner/0, side/0, point/0, mask/0]).

%% A closed interval of one axis, {Low, High}: a pixel's extent, or the part
%% of one inside a shape.
-type span() :: {number(), number()}.
%% Coverage before it is quantised to a byte: rows of fractions in [0, 1].
-type field() :: [[float()]].

%%% Masks

-doc """
The corner Corner of a rounded rectangle of radius R: an R by R mask, each
pixel its area inside the disc of radius R about the mask's inner corner.
""".
-spec quarter_disc(corner(), pos_integer()) -> mask().
quarter_disc(Corner, R) when is_integer(R), R >= 1 ->
    pack(orient(Corner, corner_field(R, fun(XSpan, YSpan) ->
                                              disc_area(R, XSpan, YSpan)
                                      end))).

-doc """
The corner Corner of a border Width pixels wide just inside a rounded
rectangle of radius R: an R by R mask, each pixel its area between the
discs of radius R and R - Width about the mask's inner corner. The width is
whole pixels, so the corner meets the border's straight sides, which are
rectangle fills.
""".
-spec quarter_ring(corner(), pos_integer(), pos_integer()) -> mask().
quarter_ring(Corner, R, Width)
  when is_integer(R), R >= 1, is_integer(Width), Width >= 1, Width =< R ->
    Inner = R - Width,
    pack(orient(Corner, corner_field(R, fun(XSpan, YSpan) ->
                                              disc_area(R, XSpan, YSpan) -
                                                  disc_area(Inner, XSpan,
                                                            YSpan)
                                      end))).

-doc """
The corner Corner of the shadow of a rounded rectangle of radius R blurred
by Blur: an (R + 2 Blur)-square whose outer corner lies Blur pixels outside
the rectangle's corner on both axes.
""".
-spec shadow_corner(corner(), non_neg_integer(), pos_integer()) -> mask().
shadow_corner(Corner, R, Blur)
  when is_integer(R), R >= 0, is_integer(Blur), Blur >= 1 ->
    %% Blurring a pixel reads Blur pixels on each side of it, so the shape
    %% is laid out a margin of 2 Blur beyond the square the mask covers.
    Margin = 2 * Blur,
    Side = R + 2 * Margin,
    Shape = span_field(Side, Side,
                       fun(XSpan, YSpan) ->
                               rounded_corner_area(R, shift(XSpan, -Margin),
                                                   shift(YSpan, -Margin))
                       end),
    pack(orient(Corner, blur(Shape, kernel(Blur)))).

-doc """
The strip across the side Side of a shadow blurred by Blur: one pixel along
the side and 2 Blur across it, from Blur pixels outside the rectangle's edge
to Blur inside it. It is drawn with the replicate bit along the side.
""".
-spec shadow_edge(side(), pos_integer()) -> mask().
shadow_edge(Side, Blur) when is_integer(Blur), Blur >= 1 ->
    %% The top side: the shape is everything below y = 0, laid out from
    %% 2 Blur above it to 2 Blur below, and wide enough for one blurred
    %% column.
    Margin = 2 * Blur,
    Shape = span_field(2 * Blur + 1, 2 * Margin,
                       fun(_XSpan, YSpan) ->
                               beyond_zero(shift(YSpan, -Margin))
                       end),
    pack(orient_side(Side, blur(Shape, kernel(Blur)))).

-doc """
The polyline through Points stroked LineWidth wide with round joins and
caps, in a Width by Height mask. One point is a dot of the line's width.
Points may lie outside the mask; the stroke is clipped to it. As a graph's,
the points' x never decreases.
""".
-spec stroke(pos_integer(), pos_integer(), [point(), ...], number()) ->
          mask().
stroke(Width, Height, [_ | _] = Points, LineWidth)
  when is_integer(Width), Width >= 1, is_integer(Height), Height >= 1,
       is_number(LineWidth), LineWidth > 0 ->
    Segments = segments(Points),
    case rising(Segments) of
        true -> ok;
        false -> error(badarg, [Width, Height, Points, LineWidth])
    end,
    Half = LineWidth / 2,
    Capsules = [capsule(Segment, Half) || Segment <- Segments],
    Reached = lists:foldl(fun(Capsule, Acc) ->
                                  note_reach(Capsule, Half, {Width, Height},
                                             Acc)
                          end, #{}, Capsules),
    Coverage = maps:map(fun(Pixel, Near) ->
                                pixel_coverage(Pixel, Near, Half)
                        end, Reached),
    pack(index_field(Width, Height,
                     fun(I, J) -> maps:get({I, J}, Coverage, 0.0) end)).

-doc """
The region between the polyline through Points and the bottom of a Width by
Height mask. The points' x never decreases; outside their first and last x
the region is empty.
""".
-spec area(pos_integer(), pos_integer(), [point(), ...]) -> mask().
area(Width, Height, [_ | _] = Points)
  when is_integer(Width), Width >= 1, is_integer(Height), Height >= 1 ->
    Segments = segments(Points),
    case rising(Segments) of
        true -> ok;
        false -> error(badarg, [Width, Height, Points])
    end,
    Columns = [column_pieces(Segments, pixel_span(I))
               || I <- lists:seq(0, Width - 1)],
    pack([[pieces_area(Pieces, pixel_span(J)) || Pieces <- Columns]
          || J <- lists:seq(0, Height - 1)]).

%%% Pixel geometry

%% The centre of pixel I of a row or column; the one place that fixes where
%% a pixel lies.
-spec centre(integer()) -> float().
centre(I) ->
    I + 0.5.

%% The extent of pixel I along its axis.
-spec pixel_span(integer()) -> span().
pixel_span(I) ->
    C = centre(I),
    {C - 0.5, C + 0.5}.

-spec shift(span(), number()) -> span().
shift({Low, High}, By) ->
    {Low + By, High + By}.

%% Rows of Fun(I, J), the pixels' indices, over a Width by Height mask.
-spec index_field(pos_integer(), pos_integer(),
                  fun((integer(), integer()) -> float())) -> field().
index_field(Width, Height, Fun) ->
    [[Fun(I, J) || I <- lists:seq(0, Width - 1)]
     || J <- lists:seq(0, Height - 1)].

%% Rows of Fun(XSpan, YSpan), the pixels' extents, over a Width by Height
%% mask.
-spec span_field(pos_integer(), pos_integer(),
                 fun((span(), span()) -> float())) -> field().
span_field(Width, Height, Fun) ->
    index_field(Width, Height,
                fun(I, J) -> Fun(pixel_span(I), pixel_span(J)) end).

%% The top-left corner of radius R, an R-square whose disc is centred on
%% its bottom-right corner: Fun takes the pixel's extents relative to that
%% centre.
corner_field(R, Fun) ->
    span_field(R, R, fun(XSpan, YSpan) ->
                             Fun(shift(XSpan, -R), shift(YSpan, -R))
                     end).

%% Every mask is computed for the top-left corner or the top side and
%% mirrored into place.
-spec orient(corner(), field()) -> field().
orient(top_left, Rows) -> Rows;
orient(top_right, Rows) -> mirror(Rows);
orient(bottom_left, Rows) -> lists:reverse(Rows);
orient(bottom_right, Rows) -> lists:reverse(mirror(Rows)).

-spec orient_side(side(), field()) -> field().
orient_side(top, Rows) -> Rows;
orient_side(bottom, Rows) -> lists:reverse(Rows);
orient_side(left, Rows) -> transpose(Rows);
orient_side(right, Rows) -> mirror(transpose(Rows)).

mirror(Rows) ->
    [lists:reverse(Row) || Row <- Rows].

transpose([]) ->
    [];
transpose([[] | _]) ->
    [];
transpose(Rows) ->
    [[hd(Row) || Row <- Rows] | transpose([tl(Row) || Row <- Rows])].

%% Coverage to bytes, rounding each pixel to the nearest of 256 levels.
-spec pack(field()) -> mask().
pack([First | _] = Rows) ->
    {length(First), length(Rows),
     << <<(min(255, max(0, round(C * 255))))>> || Row <- Rows, C <- Row >>}.

%%% Discs

%% The area of the box XSpan by YSpan inside the disc of radius R about the
%% origin. Inclusion and exclusion over the box's corners reduces it to the
%% signed area between the origin and each corner.
-spec disc_area(number(), span(), span()) -> float().
disc_area(R, _XSpan, _YSpan) when R == 0 ->
    0.0;
disc_area(R, {X0, X1}, {Y0, Y1}) ->
    origin_area(R, X1, Y1) - origin_area(R, X0, Y1) -
        origin_area(R, X1, Y0) + origin_area(R, X0, Y0).

%% The area of the rectangle between the origin and (X, Y) inside the disc,
%% negative when the rectangle lies on the negative side of one axis; the
%% disc's symmetry folds every quadrant onto the first.
origin_area(R, X, Y) ->
    sign(X) * sign(Y) * quadrant_area(R, abs(X), abs(Y)).

sign(V) when V < 0 -> -1;
sign(_) -> 1.

%% The area of [0, A] by [0, B] inside the disc of radius R: the rectangle's
%% height B up to where the arc comes down to it, then the arc.
quadrant_area(R, A, B) when A > R ->
    quadrant_area(R, R, B);
quadrant_area(R, A, B) when B >= R ->
    under_arc(R, A);
quadrant_area(R, A, B) ->
    Crossing = math:sqrt(R * R - B * B),
    case A =< Crossing of
        true -> A * B;
        false -> Crossing * B + under_arc(R, A) - under_arc(R, Crossing)
    end.

%% The area under the arc y = sqrt(R^2 - t^2) for t from 0 to X =< R.
under_arc(R, X) ->
    (X * math:sqrt(R * R - X * X) + R * R * math:asin(X / R)) / 2.

%% The area of the box XSpan by YSpan inside a rounded rectangle's top-left
%% corner: everything right of x = 0 and below y = 0, less the part of the
%% R-square at the origin outside the disc of radius R about (R, R).
-spec rounded_corner_area(non_neg_integer(), span(), span()) -> float().
rounded_corner_area(R, XSpan, YSpan) ->
    beyond_zero(XSpan) * beyond_zero(YSpan) - outside_arc(R, XSpan, YSpan).

%% The length of the part of a span above zero.
beyond_zero({Low, High}) ->
    max(0.0, High - max(Low, 0.0)).

outside_arc(R, XSpan, YSpan) ->
    case {within(XSpan, 0, R), within(YSpan, 0, R)} of
        {{X0, X1} = SquareX, {Y0, Y1} = SquareY} ->
            (X1 - X0) * (Y1 - Y0) -
                disc_area(R, shift(SquareX, -R), shift(SquareY, -R));
        _ ->
            0.0
    end.

%% The part of a span inside [Min, Max], or empty.
within({Low, High}, Min, Max) when Low < Max, High > Min ->
    {max(Low, Min), min(High, Max)};
within(_, _, _) ->
    empty.

%%% Blur

%% The Gaussian of standard deviation Blur / 2, integrated over each pixel
%% from -Blur to Blur and scaled to sum to one.
-spec kernel(pos_integer()) -> [float()].
kernel(Blur) ->
    Scale = Blur / 2 * math:sqrt(2),
    Masses = [(math:erf((K + 0.5) / Scale) - math:erf((K - 0.5) / Scale)) / 2
              || K <- lists:seq(-Blur, Blur)],
    Total = lists:sum(Masses),
    [Mass / Total || Mass <- Masses].

%% The field convolved with the kernel along both axes, keeping the pixels
%% whose whole neighbourhood the field holds: Blur fewer on every side.
-spec blur(field(), [float()]) -> field().
blur(Field, Kernel) ->
    Across = [convolve(Row, Kernel) || Row <- Field],
    transpose([convolve(Column, Kernel) || Column <- transpose(Across)]).

convolve(Values, Kernel) ->
    convolve(Values, Kernel, length(Values) - length(Kernel) + 1).

convolve(_Values, _Kernel, 0) ->
    [];
convolve([_ | Rest] = Values, Kernel, Count) ->
    [weighted_sum(Values, Kernel) | convolve(Rest, Kernel, Count - 1)].

weighted_sum(_Values, []) ->
    0.0;
weighted_sum([Value | Values], [Weight | Weights]) ->
    Value * Weight + weighted_sum(Values, Weights).

%%% Strokes

-type segment() :: {point(), point()}.

%% The polyline's segments; one point is a segment of length zero.
-spec segments([point(), ...]) -> [segment(), ...].
segments([Point]) ->
    [{Point, Point}];
segments(Points) ->
    lists:zip(lists:droplast(Points), tl(Points)).

%% Add the capsule to the list of each pixel it may reach: every pixel whose
%% centre lies within Limit, half the line's width and half a pixel's
%% diagonal, of its segment. In each row those are the pixels whose centres
%% lie in the row's interval of the segment's capsule of radius Limit.
note_reach({{{_, Y0}, {_, Y1}} = Segment, _, _} = Capsule, Half,
           {Width, Height}, Reached) ->
    Limit = Half + math:sqrt(0.5),
    Wide = capsule(Segment, Limit),
    Rows = centres_within(min(Y0, Y1) - Limit, max(Y0, Y1) + Limit, Height),
    Pixels = [{I, J} || J <- Rows,
                        {Left, Right} <- [row_interval(Wide, Limit, centre(J))],
                        I <- centres_within(Left, Right, Width)],
    lists:foldl(fun(Pixel, Acc) ->
                        maps:update_with(Pixel, fun(Old) -> [Capsule | Old] end,
                                         [Capsule], Acc)
                end, Reached, Pixels).

%% The indices of the pixels, among Count, whose centres lie in [Low, High]:
%% centre(I) is I + centre(0), so I runs from Low - centre(0) rounded up to
%% High - centre(0) rounded down.
centres_within(Low, High, Count) ->
    First = max(0, ceil(Low - centre(0))),
    Last = min(Count - 1, floor(High - centre(0))),
    case First =< Last of
        true -> lists:seq(First, Last);
        false -> []
    end.

%% The stroke's coverage of pixel (I, J), which the capsules may reach. One
%% capsule alone gives its exact band or disc area where the pixel lies
%% wholly within one of them; every other pixel is covered if one capsule
%% holds it, and integrates the union if none does.
pixel_coverage({I, J}, [{{A, B} = Segment, _, _} = Capsule], Half) ->
    {XSpan, YSpan} = {pixel_span(I), pixel_span(J)},
    case run_position(Segment, XSpan, YSpan) of
        within -> band_coverage({centre(I), centre(J)}, Segment, Half);
        before -> disc_coverage(A, XSpan, YSpan, Half);
        beyond -> disc_coverage(B, XSpan, YSpan, Half);
        across -> union_coverage(XSpan, YSpan, [Capsule], Half)
    end;
pixel_coverage({I, J}, Capsules, Half) ->
    {XSpan, YSpan} = {pixel_span(I), pixel_span(J)},
    case lists:any(fun(Capsule) -> holds(Capsule, Half, XSpan, YSpan) end,
                   Capsules) of
        true -> 1.0;
        false -> union_coverage(XSpan, YSpan, Capsules, Half)
    end.

%% Whether the capsule holds the whole pixel. Being convex, it does when it
%% holds the four corners, which it does when its intervals of the top and
%% bottom rows span the pixel.
holds(Capsule, Half, {X0, X1}, {Y0, Y1}) ->
    lists:all(fun(Y) ->
                      case row_interval(Capsule, Half, Y) of
                          {Left, Right} -> Left =< X0 andalso Right >= X1;
                          none -> false
                      end
              end, [Y0, Y1]).

%% Where the pixel lies along the segment: wholly within its run, between
%% the lines through its ends at right angles to it, where its capsule is a
%% band; wholly before its start or beyond its end, where the capsule is the
%% disc about that end; or across an end's line. Every pixel of a segment of
%% length zero, a dot, is before it: its disc.
run_position({{Ax, Ay}, {Bx, By}}, {X0, X1}, {Y0, Y1}) ->
    {Dx, Dy} = {Bx - Ax, By - Ay},
    Length2 = Dx * Dx + Dy * Dy,
    Along = [(X - Ax) * Dx + (Y - Ay) * Dy || X <- [X0, X1], Y <- [Y0, Y1]],
    {First, Last} = {lists:min(Along), lists:max(Along)},
    if
        Last =< 0 -> before;
        First >= Length2 -> beyond;
        First >= 0, Last =< Length2 -> within;
        true -> across
    end.

%% The area of the unit square centred on P inside the band Half on each
%% side of the segment's line.
band_coverage({Px, Py}, {{Ax, Ay}, {Bx, By}}, Half) ->
    Length = math:sqrt(square(Bx - Ax) + square(By - Ay)),
    {Nx, Ny} = {-(By - Ay) / Length, (Bx - Ax) / Length},
    Across = abs((Px - Ax) * Nx + (Py - Ay) * Ny),
    square_below(Half - Across, Nx, Ny) - square_below(-Half - Across, Nx, Ny).

%% The area of the pixel inside the disc of radius Half about the point.
disc_coverage({Cx, Cy}, XSpan, YSpan, Half) ->
    disc_area(Half, shift(XSpan, -Cx), shift(YSpan, -Cy)).

%% A segment's capsule, the points within Half of it, with its outline: the
%% ends, each the centre of a disc of radius Half, and the two sides, the
%% segments Half either side of it from one disc to the other. A dot is one
%% disc and no sides. The segment itself is kept for the pixels one capsule
%% alone reaches, whose band or disc it names.
-type capsule() :: {segment(), Ends :: [point()], Sides :: [segment()]}.

-spec capsule(segment(), number()) -> capsule().
capsule({{Ax, Ay} = A, {Bx, By} = B} = Segment, Half) ->
    Length = math:sqrt(square(Bx - Ax) + square(By - Ay)),
    case Length == 0 of
        true ->
            {Segment, [A], []};
        false ->
            {Nx, Ny} = {-(By - Ay) / Length * Half, (Bx - Ax) / Length * Half},
            Sides = [{{Ax + S * Nx, Ay + S * Ny}, {Bx + S * Nx, By + S * Ny}}
                     || S <- [1, -1]],
            {Segment, [A, B], Sides}
    end.

%% The area of the pixel inside the union of the segments' capsules: the
%% integral, over the pixel's height, of the length of each row's part
%% inside the union. A capsule is convex, so a row meets it in one interval,
%% and the union's part of the row is a union of intervals. Between breaks,
%% the heights where an outline passes from a side to an arc, turns at an
%% arc's top or bottom, or crosses the pixel's left or right edge, that
%% length is smooth but for kinks where two capsules' outlines cross, which
%% are no breaks, and three-point Gauss-Legendre quadrature integrates each
%% piece, kinks included.
union_coverage(XSpan, {Y0, Y1} = YSpan, Capsules, Half) ->
    Within = [trim_to_heights(Capsule, Half, YSpan) || Capsule <- Capsules],
    Breaks = lists:usort([Y0, Y1 | [Y || Capsule <- Within,
                                         Y <- outline_breaks(Capsule, Half,
                                                             XSpan),
                                         Y > Y0, Y < Y1]]),
    lists:sum([gauss(fun(Y) -> union_length(Within, Half, Y, XSpan) end,
                     Low, High)
               || {Low, High} <- lists:zip(lists:droplast(Breaks),
                                           tl(Breaks))]).

%% The capsule with only the discs and sides whose heights meet the open
%% span: at those heights the others add nothing to its row intervals.
trim_to_heights({Segment, Ends, Sides}, Half, {Y0, Y1}) ->
    {Segment, [End || {_, Cy} = End <- Ends, Cy - Half < Y1, Cy + Half > Y0],
     [Side || {{_, Uy}, {_, Vy}} = Side <- Sides,
              min(Uy, Vy) < Y1, max(Uy, Vy) > Y0]}.

%% The heights where the capsule's row interval, clipped to the columns X0
%% to X1, may change formula: each disc's top and bottom and its crossings
%% of the two edges, and each side's ends and crossings of them. A top or
%% end outside the columns is a harmless extra break.
outline_breaks({_, Ends, Sides}, Half, {X0, X1}) ->
    [Y || {Cx, Cy} <- Ends,
          Y <- [Cy - Half, Cy + Half |
                [Cy + Sign * math:sqrt(Half * Half - square(X - Cx))
                 || X <- [X0, X1], abs(X - Cx) < Half, Sign <- [1, -1]]]] ++
        [Y || {{Ux, Uy}, {Vx, Vy}} <- Sides,
              Y <- [Uy, Vy | [Uy + (X - Ux) * (Vy - Uy) / (Vx - Ux)
                              || X <- [X0, X1], (X - Ux) * (X - Vx) < 0]]].

%% The length of the row at height Y inside the union, within XSpan.
union_length(Capsules, Half, Y, {X0, X1}) ->
    Intervals = [{max(Left, X0), min(Right, X1)}
                 || Capsule <- Capsules,
                    {Left, Right} <- [row_interval(Capsule, Half, Y)],
                    Left < X1, Right > X0],
    merged_length(lists:sort(Intervals)).

%% The capsule's interval of the row at height Y, or none if the row misses
%% it. Its ends lie on the outline, each on a disc's arc or on a side, and
%% the discs' own intervals and the sides' crossings all lie within it, so
%% it is the least interval holding them all.
row_interval({_, Ends, Sides}, Half, Y) ->
    sides_hull(Sides, Y, discs_hull(Ends, Half, Y, none)).

discs_hull([{Cx, Cy} | Ends], Half, Y, Hull) when abs(Y - Cy) =< Half ->
    Chord = math:sqrt(Half * Half - square(Y - Cy)),
    discs_hull(Ends, Half, Y, widen(Hull, Cx - Chord, Cx + Chord));
discs_hull([_ | Ends], Half, Y, Hull) ->
    discs_hull(Ends, Half, Y, Hull);
discs_hull([], _Half, _Y, Hull) ->
    Hull.

%% A level side meets only the row at its own height, which has no width.
sides_hull([{{Ux, Uy}, {Vx, Vy}} | Sides], Y, Hull)
  when (Y - Uy) * (Y - Vy) =< 0, Uy /= Vy ->
    X = Ux + (Y - Uy) * (Vx - Ux) / (Vy - Uy),
    sides_hull(Sides, Y, widen(Hull, X, X));
sides_hull([_ | Sides], Y, Hull) ->
    sides_hull(Sides, Y, Hull);
sides_hull([], _Y, Hull) ->
    Hull.

widen(none, Left, Right) ->
    {Left, Right};
widen({Low, High}, Left, Right) ->
    {min(Low, Left), max(High, Right)}.

%% The total length of intervals sorted by their left ends, counting once
%% what overlaps.
merged_length([]) ->
    0.0;
merged_length([{Left, Right} | Rest]) ->
    merged_length(Rest, Left, Right, 0.0).

merged_length([{Left, Right} | Rest], Low, High, Sum) when Left =< High ->
    merged_length(Rest, Low, max(Right, High), Sum);
merged_length([{Left, Right} | Rest], Low, High, Sum) ->
    merged_length(Rest, Left, Right, Sum + High - Low);
merged_length([], Low, High, Sum) ->
    Sum + High - Low.

%% Three-point Gauss-Legendre quadrature of Fun over [Low, High], exact for
%% polynomials of degree five.
gauss(Fun, Low, High) ->
    {Mid, Radius} = {(Low + High) / 2, (High - Low) / 2},
    Offset = Radius * math:sqrt(3 / 5),
    Radius * (5 * Fun(Mid - Offset) + 8 * Fun(Mid) + 5 * Fun(Mid + Offset))
        / 9.

%% The area of the unit square centred on the origin where the coordinate
%% along the unit direction (Nx, Ny) is at most T. Along that direction the
%% square's area is spread as the sum of two uniform spreads |Nx| and |Ny|
%% wide: flat over the middle and falling linearly to zero over the outer
%% Narrow on each side. Its integral rises quadratically, then linearly, and
%% is symmetric about one half. For an axis-aligned direction Narrow is
%% zero and the area is the pixel's overlap with the half-line.
square_below(T, Nx, Ny) when T < 0 ->
    1.0 - square_below(-T, Nx, Ny);
square_below(T, Nx, Ny) ->
    Wide = max(abs(Nx), abs(Ny)),
    Narrow = min(abs(Nx), abs(Ny)),
    Outer = (Wide + Narrow) / 2,
    Inner = (Wide - Narrow) / 2,
    if
        T >= Outer -> 1.0;
        T =< Inner -> 0.5 + T / Wide;
        true -> 1.0 - square(Outer - T) / (2 * Wide * Narrow)
    end.

square(V) ->
    V * V.

%%% Areas

%% Whether the segments' x never decreases.
rising(Segments) ->
    lists:all(fun({{X0, _}, {X1, _}}) -> X0 =< X1 end, Segments).

%% The pieces of the polyline over a column: each segment's part whose x
%% lies in the column, as {X0, Y0, X1, Y1} with X0 < X1.
column_pieces(Segments, {Left, Right}) ->
    lists:filtermap(fun(Segment) -> column_piece(Segment, Left, Right) end,
                    Segments).

column_piece({{X0, _}, {X1, _}} = Segment, Left, Right) when X0 < X1 ->
    case within({X0, X1}, Left, Right) of
        empty -> false;
        Overlap -> {true, clip_segment(Segment, Overlap)}
    end;
column_piece(_Segment, _Left, _Right) ->
    false.

clip_segment({{X0, Y0}, {X1, Y1}}, {Low, High}) ->
    Slope = (Y1 - Y0) / (X1 - X0),
    {Low, Y0 + (Low - X0) * Slope, High, Y0 + (High - X0) * Slope}.

%% The area below the pieces inside a row. A row is one pixel high, so at
%% abscissa x the covered height is the row's bottom less the line's y,
%% clamped to [0, 1]; over each piece that height is integrated exactly.
pieces_area(Pieces, {_Top, Bottom}) ->
    lists:sum([(X1 - X0) * mean_depth(Bottom - Y0, Bottom - Y1)
               || {X0, Y0, X1, Y1} <- Pieces]).

%% The mean of clamp(t, 0, 1) as t runs linearly from T0 to T1: the
%% difference of its antiderivative over the run.
mean_depth(T0, T1) when abs(T1 - T0) < 1.0e-9 ->
    clamp_unit((T0 + T1) / 2);
mean_depth(T0, T1) ->
    (depth_integral(T1) - depth_integral(T0)) / (T1 - T0).

clamp_unit(T) ->
    min(1.0, max(0.0, T)).

%% The integral of clamp(t, 0, 1) from 0 to T.
depth_integral(T) when T =< 0 -> 0.0;
depth_integral(T) when T =< 1 -> T * T / 2;
depth_integral(T) -> T - 0.5.
