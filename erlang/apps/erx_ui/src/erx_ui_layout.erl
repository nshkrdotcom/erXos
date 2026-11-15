%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_layout).
-moduledoc """
The box model of the Erlang renderer (docs/design-display.md, "The widget
server", "The box model"): layout/3 places a widget tree in a window of a
given size and returns a tree of the same shape holding each node's
rectangles. A pure function: the renderer's own Measure gives a widget's
natural size, so nothing here reads a font, a process or the clock.

It works in two passes. The first, bottom-up, gives every node its
natural size and its need, the natural size with its pad on each side.
The second, top-down, gives each child of a container a slot, and
places the node within its slot by its pad and align. Three decisions
carry the properties the tests check: distribute/2 shares a length
between needs and weights, so slots fit their parent and none shrinks
when the room grows; spans/2 lays slots end to end, so siblings never
overlap; and span/6 places a node within its slot, so a node never
leaves it.

The tree is trusted: the widget server validated it whole with the
generated erx_ui_schema before the renderer saw any of it, so every
property is in range and the schema's depth bound of 64 bounds the
recursion here. Defaults are the schema's, and a container kind that
arrangement/1, the one table of the containers, does not name fails
with badmatch rather than being placed as a widget.
""".

-export([layout/3]).
-export_type([size/0, rect/0, measure/0, placed/0]).

-type size() :: {Width :: non_neg_integer(), Height :: non_neg_integer()}.
-type rect() :: {X :: non_neg_integer(), Y :: non_neg_integer(),
                 Width :: non_neg_integer(), Height :: non_neg_integer()}.
%% A widget's natural size, before its pad, such as its text's extent in
%% the renderer's subfont. It is called for widgets alone, never for a
%% container.
-type measure() :: fun((Kind :: atom(), Props :: map()) -> size()).
%% Rect is where the node is; Content the box its children are placed
%% in, equal to Rect for every kind but scroll, whose content is as tall
%% as its column needs. A scroll's descendants are placed in that box
%% unscrolled, so they may lie outside the window: the renderer shifts
%% them by its own scroll offset and clips them to the scroll's Rect.
-type placed() :: {Rect :: rect(), Content :: rect(), Children :: [placed()]}.

-type direction() :: vertical | horizontal.
%% How a kind places its children, the one table of the containers.
-type arrangement() :: {line, direction()} | scroll | grid | stack | widget.

%% A node after the first pass.
-record(sized, {kind :: atom(),
                props :: map(),
                natural :: size(),      % its own size, without its pad
                need :: size(),         % its natural size and pad
                weight :: non_neg_integer(),
                children :: [#sized{}]}).

-doc """
Places Tree, a tree erx_ui_schema has validated, in a window of
{Width, Height}, with Measure giving each widget's natural size.
""".
-spec layout(erx_ui_model:tree(), size(), measure()) -> placed().
layout(Tree, {Width, Height}, Measure) ->
    place(sized(Tree, Measure), {0, 0, Width, Height}).

%%% The first pass: natural sizes and needs.

-spec sized(erx_ui_model:tree(), measure()) -> #sized{}.
sized({Kind, Props, Children}, Measure) ->
    Sized = [sized(Child, Measure) || Child <- Children],
    {Natural, Need, Weight} = footprint(Kind, Props, Sized, Measure),
    #sized{kind = Kind, props = Props, natural = Natural, need = Need,
           weight = Weight, children = Sized}.

%% A node's natural size, its need and its weight; a hidden node has none.
footprint(Kind, Props, Children, Measure) ->
    case prop(visible, Props) of
        false ->
            {{0, 0}, {0, 0}, 0};
        true ->
            {MeasuredWidth, MeasuredHeight} =
                natural(arrangement(Kind), Kind, Props, Children, Measure),
            Width = maps:get(width, Props, MeasuredWidth),
            Height = maps:get(height, Props, MeasuredHeight),
            Pad = 2 * pad(Props),
            {{Width, Height}, {Width + Pad, Height + Pad},
             maps:get(weight, Props, 0)}
    end.

%% What a node's content asks for when it carries no width or height.
natural(widget, Kind, Props, [], Measure) ->
    Measure(Kind, Props);
natural({line, Direction}, _Kind, _Props, Children, _Measure) ->
    Needs = [Need || #sized{need = Need} <- Children],
    turn(Direction, lists:sum([along(Direction, Need) || Need <- Needs]),
         largest([breadth(Direction, Need) || Need <- Needs]));
%% A scroll asks for its widest child across and nothing down, so it
%% takes the room its parent gives it and the rest of its column scrolls.
natural(scroll, _Kind, _Props, Children, _Measure) ->
    {largest([Width || #sized{need = {Width, _}} <- Children]), 0};
natural(stack, _Kind, _Props, Children, _Measure) ->
    {largest([Width || #sized{need = {Width, _}} <- Children]),
     largest([Height || #sized{need = {_, Height}} <- Children])};
natural(grid, _Kind, Props, Children, _Measure) ->
    {Columns, Rows} = grid_tracks(Props, Children),
    {lists:sum([Width || {Width, _} <- Columns]),
     lists:sum([Height || {Height, _} <- Rows])}.

%%% The second pass: slots and rectangles.

-spec place(#sized{}, rect()) -> placed().
place(#sized{props = Props} = Node, Slot) ->
    case prop(visible, Props) of
        true -> place_shown(Node, Slot);
        false -> collapse(Node, Slot)
    end.

%% A hidden node and its subtree sit at zero size where the slot starts.
collapse(#sized{children = Children}, {X, Y, _, _}) ->
    Point = {X, Y, 0, 0},
    {Point, Point, [collapse(Child, Point) || Child <- Children]}.

place_shown(#sized{kind = Kind, props = Props, natural = Natural,
                   children = Children}, Slot) ->
    Rect = within(Slot, Natural, Props),
    Content = content(Kind, Rect, Children),
    {Rect, Content, place_children(arrangement(Kind), Props, Children, Content)}.

%% A node's rectangle in its slot, in each direction alike: what its pad
%% leaves, then all of that or its natural size placed by its align. A
%% width or height is a fixed size, which fill does not stretch.
within({X, Y, Width, Height}, {NaturalWidth, NaturalHeight}, Props) ->
    Pad = pad(Props),
    Align = prop(align, Props),
    {Left, PlacedWidth} =
        span(X, Width, NaturalWidth, Pad, Align, maps:is_key(width, Props)),
    {Top, PlacedHeight} =
        span(Y, Height, NaturalHeight, Pad, Align, maps:is_key(height, Props)),
    {Left, Top, PlacedWidth, PlacedHeight}.

%% What remains inside the pad is the room less both pads, or nothing in
%% the room's middle when the pads do not fit, so it never shrinks as the
%% room grows; a pad cut to half the room would leave 1 of 3 but 0 of 4.
span(Start, Room, Natural, Pad, Align, Fixed) ->
    Inner = max(0, Room - 2 * Pad),
    Given = (Room - Inner) div 2,
    Size = case Align =:= fill andalso not Fixed of
               true -> Inner;
               false -> min(Natural, Inner)
           end,
    {Start + Given + offset(Align, Inner - Size), Size}.

offset(fill, _Free) -> 0;
offset(start, _Free) -> 0;
offset(center, Free) -> Free div 2;
offset('end', Free) -> Free.

%% A scroll's children are a column at least as tall as the scroll; the
%% renderer moves that box under the scroll's rectangle.
content(scroll, {X, Y, Width, Height}, Children) ->
    {X, Y, Width,
     max(Height, lists:sum([Down || #sized{need = {_, Down}} <- Children]))};
content(_Kind, Rect, _Children) ->
    Rect.

place_children(widget, _Props, [], _Content) ->
    [];
place_children(scroll, Props, Children, Content) ->
    place_children({line, vertical}, Props, Children, Content);
place_children(stack, _Props, Children, Content) ->
    [place(Child, Content) || Child <- Children];
place_children({line, Direction}, _Props, Children, Content) ->
    Room = along(Direction, dimensions(Content)),
    Lengths = distribute(Room, [{along(Direction, Need), Weight}
                                || #sized{need = Need, weight = Weight}
                                       <- Children]),
    Slots = [slot(Direction, Content, Span)
             || Span <- spans(start(Direction, Content), Lengths)],
    lists:zipwith(fun place/2, Children, Slots);
place_children(grid, Props, Children, {X, Y, Width, Height}) ->
    {Columns, Rows} = grid_tracks(Props, Children),
    ColumnSpans = spans(X, distribute(Width, Columns)),
    RowSpans = spans(Y, distribute(Height, Rows)),
    lists:append(lists:zipwith(fun(Row, RowSpan) ->
                                       place_row(Row, ColumnSpans, RowSpan)
                               end,
                               grid_rows(Props, Children), RowSpans)).

%% A grid row's cells, each in its column; the last row may be short.
place_row([], _ColumnSpans, _RowSpan) ->
    [];
place_row([Cell | Cells], [{X, Width} | ColumnSpans], {Y, Height} = RowSpan) ->
    [place(Cell, {X, Y, Width, Height}) | place_row(Cells, ColumnSpans, RowSpan)].

slot(vertical, {X, _, Width, _}, {Y, Length}) -> {X, Y, Width, Length};
slot(horizontal, {_, Y, _, Height}, {X, Length}) -> {X, Y, Length, Height}.

%% Where each length starts when they are laid end to end from Start.
spans(Start, Lengths) ->
    {Spans, _End} = lists:mapfoldl(fun(Length, At) ->
                                           {{At, Length}, At + Length}
                                   end, Start, Lengths),
    Spans.

%%% Sharing a length.

%% The lengths that tracks of {Need, Weight} take from Room. When their
%% needs fit, each takes its need and the room left over is shared by
%% weight; when they do not, they take their needs in order until the
%% room runs out. Either way the lengths sum to at most Room, and none
%% shrinks when Room grows.
-spec distribute(non_neg_integer(), [{non_neg_integer(), non_neg_integer()}]) ->
          [non_neg_integer()].
distribute(Room, Tracks) ->
    Needs = [Need || {Need, _} <- Tracks],
    case Room - lists:sum(Needs) of
        Left when Left >= 0 ->
            lists:zipwith(fun erlang:'+'/2, Needs,
                          share(Left, [Weight || {_, Weight} <- Tracks]));
        _ ->
            cut(Room, Needs)
    end.

cut(_Room, []) ->
    [];
cut(Room, [Need | Needs]) ->
    Taken = min(Need, Room),
    [Taken | cut(Room - Taken, Needs)].

%% Left shared by highest averages (D'Hondt): each unit goes to the
%% weight with the largest Weight / (Units + 1), the first on a tie, so
%% the units for Left + 1 are those for Left and one more, and no weight
%% gets less from more room. Every weight first takes its quota,
%% Left * Weight div Total: those are exactly the units the method hands
%% out before any average falls below Total / Left, so fewer units than
%% there are weights remain to go one at a time. With no weight nothing
%% is shared.
share(Left, Weights) ->
    case lists:sum(Weights) of
        0 ->
            [0 || _ <- Weights];
        Total ->
            Quotas = [Left * Weight div Total || Weight <- Weights],
            award(Left - lists:sum(Quotas), lists:zip(Weights, Quotas))
    end.

%% Shares, as {Weight, Units}, after Left more units are handed out.
award(0, Shares) ->
    [Units || {_Weight, Units} <- Shares];
award(Left, Shares) ->
    award(Left - 1, add_one(highest_average(Shares), Shares)).

%% The share with the largest Weight / (Units + 1), the first on a tie,
%% compared without division.
highest_average([First | Rest]) ->
    lists:foldl(fun(Share, Best) ->
                        case above(Share, Best) of
                            true -> Share;
                            false -> Best
                        end
                end, First, Rest).

above({Weight, Units}, {BestWeight, BestUnits}) ->
    Weight * (BestUnits + 1) > BestWeight * (Units + 1).

%% A unit more for the first share equal to Best, which is the one
%% highest_average/1 chose: an equal share earlier would have won the tie.
add_one(Best, [Best | Rest]) ->
    {Weight, Units} = Best,
    [{Weight, Units + 1} | Rest];
add_one(Best, [Share | Rest]) ->
    [Share | add_one(Best, Rest)].

%%% Grids.

%% A grid's children in rows of its columns, in order.
grid_rows(Props, Children) ->
    rows(prop(columns, Props), Children).

rows(_Columns, []) ->
    [];
rows(Columns, Children) when Columns > 0 ->
    {Row, Rest} = take(Columns, Children),
    [Row | rows(Columns, Rest)].

%% The first N of a list, or all of it when it is shorter, and the rest.
take(0, List) ->
    {[], List};
take(_N, []) ->
    {[], []};
take(N, [Head | Tail]) ->
    {Taken, Rest} = take(N - 1, Tail),
    {[Head | Taken], Rest}.

%% The {Need, Weight} of each column and each row: its widest or tallest
%% cell's need and its heaviest cell's weight.
grid_tracks(Props, Children) ->
    Rows = grid_rows(Props, Children),
    {[track(fun({Width, _}) -> Width end, Column) || Column <- columns(Rows)],
     [track(fun({_, Height}) -> Height end, Row) || Row <- Rows]}.

track(Dimension, Cells) ->
    {largest([Dimension(Need) || #sized{need = Need} <- Cells]),
     largest([Weight || #sized{weight = Weight} <- Cells])}.

%% The columns of rows that are all full but perhaps the last.
columns(Rows) ->
    case [Row || [_ | _] = Row <- Rows] of
        [] -> [];
        Live -> [[Cell || [Cell | _] <- Live] | columns([Tail || [_ | Tail] <- Live])]
    end.

%%% Directions and the table of containers.

-spec arrangement(atom()) -> arrangement().
arrangement(column) -> {line, vertical};
arrangement(row) -> {line, horizontal};
arrangement(scroll) -> scroll;
arrangement(grid) -> grid;
arrangement(stack) -> stack;
arrangement(Widget) ->
    #{children := false} = erx_ui_schema:kind(Widget),
    widget.

%% A property's value, or the default abi/formats/ui.txt declares for it.
prop(Name, Props) ->
    case Props of
        #{Name := Value} -> Value;
        #{} -> maps:get(default, erx_ui_schema:property(Name))
    end.

%% ui.txt declares no default pad: an absent pad is none.
pad(Props) -> maps:get(pad, Props, 0).

along(vertical, {_, Height}) -> Height;
along(horizontal, {Width, _}) -> Width.

breadth(vertical, {Width, _}) -> Width;
breadth(horizontal, {_, Height}) -> Height.

%% The size whose length along Direction is Along and across it Breadth.
turn(vertical, Along, Breadth) -> {Breadth, Along};
turn(horizontal, Along, Breadth) -> {Along, Breadth}.

start(vertical, {_, Y, _, _}) -> Y;
start(horizontal, {X, _, _, _}) -> X.

dimensions({_, _, Width, Height}) -> {Width, Height}.

largest(Values) -> lists:max([0 | Values]).
