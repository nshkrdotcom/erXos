%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_layout_tests).
-moduledoc """
EUnit cases of erx_ui_layout, the box model (docs/design-display.md, "The
box model"): worked layouts of each container and rule, then the
properties of "Verification and testing" over random trees and window
sizes: a node within its parent's content box, siblings of a column, row,
grid or scroll apart, the same shape as the input, no node smaller in a
larger window, a padded node's content box its rectangle less its pads,
and the layout's contract, a subtree laid out alike wherever its slot
lies.
""".

-include_lib("eunit/include/eunit.hrl").

-define(TREES, 3000).

%%% Worked layouts.

%% A widget whose natural size is the width and height its test names.
measure(_Kind, #{test_size := Size}) -> Size;
measure(_Kind, _Props) -> {0, 0}.

widget(Props) -> {label, Props, []}.
sized_widget(Width, Height) -> widget(#{test_size => {Width, Height}}).

layout(Tree, Size) -> erx_ui_layout:layout(Tree, Size, fun measure/2).

rects({_Rect, _Content, Children}) -> [Rect || {Rect, _, _} <- Children].

weights_share_the_leftover_test() ->
    Column = {column, #{}, [widget(#{weight => 1}), widget(#{weight => 2})]},
    ?assertEqual([{0, 0, 40, 100}, {0, 100, 40, 200}],
                 rects(layout(Column, {40, 300}))).

an_odd_unit_goes_to_the_first_of_equal_weights_test() ->
    Row = {row, #{}, [widget(#{weight => 1}) || _ <- [1, 2, 3]]},
    ?assertEqual([{0, 0, 101, 10}, {101, 0, 100, 10}, {201, 0, 100, 10}],
                 rects(layout(Row, {301, 10}))).

without_weights_the_leftover_stays_empty_test() ->
    Column = {column, #{}, [sized_widget(5, 10), sized_widget(5, 20)]},
    ?assertEqual([{0, 0, 30, 10}, {0, 10, 30, 20}], rects(layout(Column, {30, 100}))).

needs_come_before_the_leftover_test() ->
    Column = {column, #{}, [sized_widget(10, 30), widget(#{weight => 1})]},
    ?assertEqual([{0, 0, 50, 30}, {0, 30, 50, 70}],
                 rects(layout(Column, {50, 100}))).

too_little_room_cuts_in_order_test() ->
    Column = {column, #{}, [sized_widget(5, 30) || _ <- [1, 2, 3]]},
    ?assertEqual([{0, 0, 10, 30}, {0, 30, 10, 20}, {0, 50, 10, 0}],
                 rects(layout(Column, {10, 50}))).

%% A 10 by 4 widget with a pad of 5 in a 100 by 40 window: it needs 20 by
%% 14, its pads inside it, and its content is its rectangle less the pads.
pad_and_align_place_a_node_in_its_slot_test() ->
    Padded = fun(Align) -> #{test_size => {10, 4}, pad => 5, align => Align} end,
    ?assertMatch({{0, 0, 20, 14}, {5, 5, 10, 4}, []},
                 layout(widget(Padded(start)), {100, 40})),
    ?assertMatch({{40, 13, 20, 14}, {45, 18, 10, 4}, []},
                 layout(widget(Padded(center)), {100, 40})),
    ?assertMatch({{80, 26, 20, 14}, {85, 31, 10, 4}, []},
                 layout(widget(Padded('end')), {100, 40})),
    ?assertMatch({{0, 0, 100, 40}, {5, 5, 90, 30}, []},
                 layout(widget(Padded(fill)), {100, 40})).

%% A column's pad keeps its children off its edges.
a_pad_insets_a_containers_children_test() ->
    Column = {column, #{pad => 3}, [sized_widget(5, 10), sized_widget(5, 10)]},
    ?assertMatch({{0, 0, 40, 50}, {3, 3, 34, 44}, [{{3, 3, 34, 10}, _, []},
                                                   {{3, 13, 34, 10}, _, []}]},
                 layout(Column, {40, 50})).

%% A width is the whole node, its pad inside it, as LVGL's is.
a_width_holds_its_pad_test() ->
    Fixed = widget(#{test_size => {10, 10}, width => 30, pad => 5, align => center}),
    ?assertMatch({{35, 40, 30, 20}, {40, 45, 20, 10}, []}, layout(Fixed, {100, 100})).

%% Pads wider than the node leave no content, in its middle; a pad cut to
%% half the node would leave 1 of 3 but 0 of 4.
a_pad_wider_than_its_node_leaves_no_content_test() ->
    ?assertMatch({{0, 0, 3, 4}, {1, 2, 0, 0}, []}, layout(widget(#{pad => 5}), {3, 4})),
    ?assertMatch({{0, 0, 4, 4}, {2, 2, 0, 0}, []}, layout(widget(#{pad => 5}), {4, 4})).

%% Under the default fill, the 30 wide label keeps its width at the start
%% and stretches only down, where it has no fixed size.
a_width_is_a_fixed_size_that_fill_does_not_stretch_test() ->
    Fixed = widget(#{test_size => {10, 10}, width => 30}),
    Centred = widget(#{test_size => {10, 10}, width => 30, align => center}),
    ?assertMatch({{0, 0, 30, 100}, _, []}, layout(Fixed, {100, 100})),
    ?assertMatch({{35, 45, 30, 10}, _, []}, layout(Centred, {100, 100})).

%% A header, a list taller than the window and a footer: the scroll takes
%% the room the others leave, and its rows scroll inside it.
a_scroll_takes_the_room_its_parent_gives_it_test() ->
    Rows = [sized_widget(10, 20) || _ <- lists:seq(1, 100)],
    Screen = {column, #{}, [sized_widget(10, 20), {scroll, #{weight => 1}, Rows},
                            sized_widget(10, 20)]},
    ?assertMatch({_, _, [{{0, 0, 100, 20}, _, []},
                         {{0, 20, 100, 160}, {0, 20, 100, 2000}, _},
                         {{0, 180, 100, 20}, _, []}]},
                 layout(Screen, {100, 200})).

a_grid_fills_row_by_row_test() ->
    Cells = [sized_widget(10, 5), sized_widget(20, 5), sized_widget(10, 8)],
    Grid = {grid, #{columns => 2, align => start}, Cells},
    ?assertMatch({{0, 0, 30, 13}, _,
                  [{{0, 0, 10, 5}, _, _}, {{10, 0, 20, 5}, _, _},
                   {{0, 5, 10, 8}, _, _}]},
                 layout(Grid, {100, 100})).

a_scroll_content_is_as_tall_as_its_column_test() ->
    Scroll = {scroll, #{}, [sized_widget(5, 30) || _ <- [1, 2, 3]]},
    ?assertMatch({{0, 0, 20, 50}, {0, 0, 20, 90},
                  [{{0, 0, 20, 30}, _, _}, {{0, 30, 20, 30}, _, _},
                   {{0, 60, 20, 30}, _, _}]},
                 layout(Scroll, {20, 50})).

a_stack_gives_every_child_its_box_test() ->
    Stack = {stack, #{}, [widget(#{}), sized_widget(4, 4)]},
    ?assertEqual([{0, 0, 30, 20}, {0, 0, 30, 20}], rects(layout(Stack, {30, 20}))).

a_hidden_node_takes_no_room_test() ->
    Hidden = {row, #{visible => false}, [sized_widget(50, 50)]},
    Column = {column, #{}, [sized_widget(5, 10), Hidden, widget(#{weight => 1})]},
    ?assertMatch({_, _, [{{0, 0, 20, 10}, _, []},
                         {{0, 10, 0, 0}, {0, 10, 0, 0}, [{{0, 10, 0, 0}, _, []}]},
                         {{0, 10, 20, 90}, _, []}]},
                 layout(Column, {20, 100})).

%%% Properties over random trees.

%% Each property is its own case, so a seeded fault names the property
%% that catches it.
containment_test_() -> {timeout, 120, fun() -> every_tree(fun contained/3) end}.
siblings_apart_test_() -> {timeout, 120, fun() -> every_tree(fun apart/3) end}.
same_shape_test_() -> {timeout, 120, fun() -> every_tree(fun same_shape/3) end}.
deterministic_test_() -> {timeout, 120, fun() -> every_tree(fun deterministic/3) end}.
monotonic_test_() -> {timeout, 120, fun() -> every_tree(fun monotonic/3) end}.
padded_test_() -> {timeout, 120, fun() -> every_tree(fun padded/3) end}.
contract_test_() -> {timeout, 120, fun() -> every_tree(fun moved/3) end}.

%% Runs Check(Tree, Size, Placed) over ?TREES random trees and sizes, from
%% a fixed seed so a failure repeats.
every_tree(Check) ->
    rand:seed(exsss, {16#1a, 16#7, 16#0e}),
    lists:foreach(fun(_) ->
                          Tree = random_tree(4),
                          Size = {rand:uniform(300) - 1, rand:uniform(300) - 1},
                          Check(Tree, Size, layout(Tree, Size))
                  end, lists:seq(1, ?TREES)).

%% Every node within its parent's content box, the root within the
%% window, and each content box holding its own rectangle.
contained(Tree, {Width, Height}, Placed) ->
    contained(Tree, {0, 0, Width, Height}, Placed, []).

contained({Kind, _Props, Children}, Parent, {Rect, Content, Placed}, Path) ->
    ?assert(inside(Rect, Parent), {outside, Path, Rect, Parent}),
    ?assert(holds(Kind, Content, Rect), {content, Path, Content, Rect}),
    lists:foreach(fun({Index, Child, ChildPlaced}) ->
                          contained(Child, Content, ChildPlaced, Path ++ [Index])
                  end, indexed(Children, Placed)).

inside({X, Y, W, H}, {PX, PY, PW, PH}) ->
    W >= 0 andalso H >= 0 andalso X >= PX andalso Y >= PY
        andalso X + W =< PX + PW andalso Y + H =< PY + PH.

%% A content box starts within its rectangle and is no wider; only a
%% scroll's may be taller.
holds(scroll, {X, Y, W, H}, {RX, RY, RW, RH}) ->
    inside({X, Y, W, min(H, RY + RH - Y)}, {RX, RY, RW, RH});
holds(_Kind, Content, Rect) ->
    inside(Content, Rect).

%% No two children of a column, row, grid or scroll share a pixel.
apart(Tree, _Size, Placed) ->
    children_apart(Tree, Placed, []).

children_apart({Kind, _Props, Children}, {_Rect, _Content, Placed}, Path) ->
    case lists:member(Kind, [column, row, grid, scroll]) of
        true -> assert_disjoint([Rect || {Rect, _, _} <- Placed], Path);
        false -> ok
    end,
    lists:foreach(fun({Index, Child, ChildPlaced}) ->
                          children_apart(Child, ChildPlaced, Path ++ [Index])
                  end, indexed(Children, Placed)).

assert_disjoint([], _Path) ->
    ok;
assert_disjoint([Rect | Rest], Path) ->
    lists:foreach(fun(Other) ->
                          ?assertNot(overlap(Rect, Other), {overlap, Path, Rect, Other})
                  end, Rest),
    assert_disjoint(Rest, Path).

overlap({X1, Y1, W1, H1}, {X2, Y2, W2, H2}) ->
    X1 < X2 + W2 andalso X2 < X1 + W1 andalso Y1 < Y2 + H2 andalso Y2 < Y1 + H1.

%% One placed node for each node of the tree, children for children.
same_shape({_Kind, _Props, Children}, Size, {_Rect, _Content, Placed}) ->
    ?assertEqual(length(Children), length(Placed)),
    lists:foreach(fun({_, Child, ChildPlaced}) -> same_shape(Child, Size, ChildPlaced) end,
                  indexed(Children, Placed)).

%% The same tree and size placed again, from a tree rebuilt term by term,
%% give the same placement.
deterministic(Tree, Size, Placed) ->
    ?assertEqual(Placed, layout(binary_to_term(term_to_binary(Tree)), Size)).

%% A window grown by up to three pixels each way gives no node a smaller
%% rectangle or content box.
monotonic(Tree, {Width, Height}, Placed) ->
    Larger = {Width + rand:uniform(4) - 1, Height + rand:uniform(4) - 1},
    no_smaller(Placed, layout(Tree, Larger), []).

no_smaller({Rect, Content, Children}, {LargerRect, LargerContent, LargerChildren}, Path) ->
    ?assert(covers(LargerRect, Rect), {shrank, Path, Rect, LargerRect}),
    ?assert(covers(LargerContent, Content), {shrank, Path, Content, LargerContent}),
    lists:foreach(fun({Index, Child, LargerChild}) ->
                          no_smaller(Child, LargerChild, Path ++ [Index])
                  end, indexed(Children, LargerChildren)).

covers({_, _, LargerW, LargerH}, {_, _, W, H}) -> LargerW >= W andalso LargerH >= H.

%% The layout's contract ("The layout's contract"): what a node gets comes
%% down as its slot, so the tree laid out in a window of one size and in a
%% slot of that size at an offset gives the same rectangles, moved by the
%% offset. The slot is a stack's, after a spacer as wide as the offset
%% across in a row and one as tall as it down in a column; the row and
%% the stack are the only weights, so each takes all the room left, and
%% each spacer comes first, so a tree that needs more than the room is cut
%% in the stack, never in a spacer.
moved(Tree, {Width, Height}, Placed) ->
    {DX, DY} = {rand:uniform(200) - 1, rand:uniform(200) - 1},
    Slotted = {column, #{},
               [{spacer, #{height => DY}, []},
                {row, #{weight => 1},
                 [{spacer, #{width => DX}, []}, {stack, #{weight => 1}, [Tree]}]}]},
    {_, _, [_Down, {_, _, [_Across, {_, _, [InSlot]}]}]} =
        layout(Slotted, {DX + Width, DY + Height}),
    ?assertEqual(shifted(Placed, DX, DY), InSlot).

shifted({{X, Y, W, H}, {CX, CY, CW, CH}, Children}, DX, DY) ->
    {{X + DX, Y + DY, W, H}, {CX + DX, CY + DY, CW, CH}, [shifted(C, DX, DY) || C <- Children]}.

%% A shown node's content box is its rectangle less its pad on each side,
%% or nothing in its middle where the pads do not fit; a scroll's may be
%% taller. Its rectangle, where it takes the pointer, keeps its pads:
%% under fill and without a fixed size it spans its whole slot, checked
%% where the slot follows from the parent alone: the window for the root,
%% a stack's content box for its children, the content box's width for a
%% column's or a scroll's and its height for a row's.
padded(Tree, {Width, Height}, Placed) ->
    padded(Tree, {window, {0, 0, Width, Height}}, Placed, []).

padded({Kind, Props, Children}, Parent, {Rect, Content, Placed}, Path) ->
    case maps:get(visible, Props, true) of
        false ->
            ok;
        true ->
            assert_inset(Kind, maps:get(pad, Props, 0), Rect, Content, Path),
            assert_fills(Parent, Props, Rect, Path),
            lists:foreach(fun({Index, Child, ChildPlaced}) ->
                                  padded(Child, {Kind, Content}, ChildPlaced,
                                         Path ++ [Index])
                          end, indexed(Children, Placed))
    end.

assert_inset(Kind, Pad, {X, Y, W, H} = Rect, {CX, CY, CW, CH} = Content, Path) ->
    {InnerX, InnerW} = inset(X, W, Pad),
    {InnerY, InnerH} = inset(Y, H, Pad),
    Height = CH =:= InnerH orelse (Kind =:= scroll andalso CH > InnerH),
    ?assert({CX, CY, CW} =:= {InnerX, InnerY, InnerW} andalso Height,
            {not_inset, Path, Pad, Rect, Content}).

inset(Start, Length, Pad) ->
    Inner = max(0, Length - 2 * Pad),
    {Start + (Length - Inner) div 2, Inner}.

assert_fills({Parent, {SX, SY, SW, SH}}, Props, {X, Y, W, H} = Rect, Path) ->
    Fill = maps:get(align, Props, fill) =:= fill,
    Across = Fill andalso not maps:is_key(width, Props)
        andalso lists:member(Parent, [window, stack, column, scroll]),
    Down = Fill andalso not maps:is_key(height, Props)
        andalso lists:member(Parent, [window, stack, row]),
    ?assert(not Across orelse {X, W} =:= {SX, SW}, {not_filled, Path, Rect, Parent}),
    ?assert(not Down orelse {Y, H} =:= {SY, SH}, {not_filled, Path, Rect, Parent}).

indexed(As, Bs) ->
    lists:zip3(lists:seq(0, length(As) - 1), As, Bs).

%%% Random trees.

%% A tree at most Depth containers deep, with props drawn from the ranges
%% that matter to the layout: small sizes, pads and weights, so that
%% needs, leftovers and cuts all occur.
random_tree(0) ->
    random_widget();
random_tree(Depth) ->
    case rand:uniform(3) of
        1 -> random_widget();
        _ -> random_container(Depth)
    end.

random_widget() ->
    Kind = pick([label, button, spacer, slider]),
    {Kind, maps:merge(random_props(), #{test_size => {rand:uniform(60) - 1,
                                                      rand:uniform(30) - 1}}), []}.

random_container(Depth) ->
    Kind = pick([column, row, grid, scroll, stack]),
    Props = case Kind of
                grid -> (random_props())#{columns => rand:uniform(4)};
                _ -> random_props()
            end,
    {Kind, Props, [random_tree(Depth - 1) || _ <- lists:seq(1, rand:uniform(6) - 1)]}.

%% Each prop is drawn one time in three, but a weight every time, so that
%% lines of several unequal weights, where sharing the leftover is
%% hardest to keep monotonic, are common.
random_props() ->
    Candidates = [{width, rand:uniform(120) - 1, 3},
                  {height, rand:uniform(120) - 1, 3},
                  {weight, rand:uniform(7) - 1, 1},
                  {pad, rand:uniform(9) - 1, 3},
                  {align, pick([start, center, 'end', fill]), 3},
                  {visible, rand:uniform(8) > 1, 3}],
    maps:from_list([{Name, Value} || {Name, Value, OneIn} <- Candidates,
                                     rand:uniform(OneIn) =:= 1]).

pick(Choices) -> lists:nth(rand:uniform(length(Choices)), Choices).
