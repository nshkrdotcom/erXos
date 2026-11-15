%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the overlapping window policy erx_wm_rio (test/host/erx_wm_test.rb),
%% after docs/design-display.md, "Verification and testing", the window system.
%%
%% The keyboard property is checked exhaustively over a small model: two sessions, at most
%% three windows, and every sequence of up to ?DEPTH acts, deduplicated by the state they
%% reach. A client's acts are `new` and the wctl requests top, bottom, hide, show, move and
%% resize, and a window's end; the user's acts are a click on a window's centre, a click
%% on the background, a menu choice that shows a hidden window, and the menu's commands
%% hide, move, resize and delete applied to a window's centre. The model keeps its own
%% pick, set only by the user's clicks and by the menu's show, move and resize, and after
%% every act checks that a key down goes to that window while it is in the table and
%% shown and nowhere otherwise, that decorate/3 marks that window alone, that a click on a
%% window that is not current reaches no client, and that every rectangle lies within
%% the screen.

-module(erx_wm_rio_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SCREEN, {0, 0, 1000, 800}).
%% A point no window of the model covers: default windows end by 776 by 576, a move puts
%% one at 300,300, the menu moves windows toward the screen's corner, and a resize gives one
%% at most 300 by 200 at the corner or a sweep from a centre.
-define(BACKGROUND, {990, 790}).
-define(MAX_WINDOWS, 3).
-define(DEPTH, 7).
-define(STATES_MIN, 100000).
-define(SESSIONS, [<<"10">>, <<"20">>]).
-define(WCTL, [top, bottom, hide, show, {move, {300, 300, 301, 301}}, {resize, {0, 0, 300, 200}}]).
-define(LEFT, 1).
-define(RIGHT, 4).

%% The exhaustive run ----------------------------------------------------------

no_window_takes_the_keyboard_but_by_the_user_s_pick_test_() ->
    {timeout, 240, fun() ->
                           States = explore([start()], #{}, ?DEPTH),
                           ?debugFmt("~b states", [States]),
                           %% A run that reaches few states checks little.
                           ?assert(States > ?STATES_MIN)
                   end}.

%% The number of distinct states reached.
explore([], Seen, _Depth) ->
    map_size(Seen);
explore(_Frontier, Seen, 0) ->
    map_size(Seen);
explore(Frontier, Seen, Depth) ->
    {Next, Seen1} = lists:foldl(
        fun(World, Acc) ->
            lists:foldl(fun(Act, {Found, S}) ->
                                World1 = act(Act, World),
                                ok = check(Act, World1),
                                Key = key(World1),
                                case S of
                                    #{Key := _} -> {Found, S};
                                    #{} -> {[World1 | Found], S#{Key => true}}
                                end
                        end, Acc, acts(World))
        end, {[], Seen}, Frontier),
    explore(Next, Seen1, Depth - 1).

start() ->
    {Table, State} = erx_wm_rio:arrange([], ?SCREEN, none, erx_wm_rio:init(#{})),
    #{table => Table, state => State, pick => none, next => 1, clicked => none}.

key(#{table := Table, state := State, pick := Pick, next := Next}) ->
    {Table, State, Pick, Next}.

acts(#{table := Table, next := Next}) ->
    Ids = [Id || #{id := Id} <- Table],
    [{new, S} || Next =< ?MAX_WINDOWS, S <- ?SESSIONS]
        ++ [{wctl, Id, C} || Id <- Ids, C <- ?WCTL]
        ++ [{'end', Id} || Id <- Ids]
        ++ [{click, Id} || Id <- Ids]
        ++ [background, menu_show_each]
        ++ [{menu, C, Id} || Id <- Ids, C <- [hide, move, resize, delete]].

%% A client's acts never move the model's pick.
act({new, Session}, #{table := Table, state := State, next := Id} = W) ->
    Row = #{id => Id, dir => {Session, integer_to_binary(Id)}, rect => ?SCREEN, state => hidden},
    {ok, Table1, State1} = erx_wm_rio:place(new, Id, [Row | Table], ?SCREEN, none, State),
    W#{table := Table1, state := State1, next := Id + 1, clicked := none};
act({wctl, Id, Command}, #{table := Table, state := State} = W) ->
    case erx_wm_rio:place(Command, Id, Table, ?SCREEN, none, State) of
        {ok, Table1, State1} -> W#{table := Table1, state := State1, clicked := none};
        {error, einval} -> W#{clicked := none}
    end;
act({'end', Id}, W) ->
    ended(Id, W#{clicked := none});
%% The user's acts.
act({click, Id}, #{table := Table} = W) ->
    click(centre(Id, Table), W);
act(background, W) ->
    click(?BACKGROUND, W);
act(menu_show_each, #{table := Table} = W) ->
    %% Shows the topmost hidden window from the menu, when there is one.
    case [Id || #{id := Id, state := hidden} <- Table] of
        [Id | _] ->
            {World, Items} = open_menu(W),
            {Route, World1} = ask(pointer(centre_of({show, Id}, Items), 0), World),
            (performed(Route, World1))#{pick := Id, clicked := none};
        [] ->
            W#{clicked := none}
    end;
act({menu, Command, Id}, #{table := Table} = W) ->
    Target = centre(Id, Table),
    {World, Items} = open_menu(W),
    {drop, World1} = ask(pointer(centre_of(Command, Items), 0), World),
    Under = under(Target, Table),
    {Route, World2} = ask(pointer(Target, ?LEFT), World1),
    Pick = case Command of
               _ when Under =:= none -> maps:get(pick, W);
               move -> Under;
               resize -> Under;
               _ -> maps:get(pick, W)
           end,
    World3 = case {Command, Route} of
                 {delete, {wm, {delete, Under}}} -> ended(Under, World2);
                 {delete, drop} when Under =:= none -> World2;
                 {hide, {windows, _}} -> performed(Route, World2);
                 {hide, drop} when Under =:= none -> World2;
                 {_, {wm, Command}} -> World2;
                 {_, drop} when Under =:= none -> World2;
                 _ -> error({menu_command_answered, Command, Under, Route})
             end,
    %% The release of the press that named the window.
    {Release, World4} = ask(pointer(released(Command, Target), 0), World3),
    (performed(Release, World4))#{pick := Pick, clicked := none}.

%% A left click: the press is asked, and its release too when the press's gesture is the
%% policy's. The model picks the window under the point.
click(Point, #{table := Table, state := State} = W) ->
    Under = under(Point, Table),
    Before = erx_wm_rio:current(Table, State),
    {Press, World} = ask(pointer(Point, ?LEFT), W),
    World1 = performed(Press, World),
    World2 = case Press of
                 {wm, _} -> performed(element(1, ask(pointer(Point, 0), World1)), World1);
                 _ -> World1
             end,
    Pick = case Under of none -> maps:get(pick, W); _ -> Under end,
    World2#{pick := Pick, clicked := {Under, Before, Press}}.

open_menu(W) ->
    {{wm, menu}, World} = ask(pointer(?BACKGROUND, ?RIGHT), W),
    #{table := Table, state := State} = World,
    {World, erx_wm_rio:menu(Table, State)}.

ask(Input, #{table := Table, state := State} = W) ->
    {Route, State1} = erx_wm_rio:input(Input, Table, none, State),
    {Route, W#{state := State1}}.

performed({windows, Table}, #{table := Old} = W) ->
    ?assertEqual(lists:sort(ids(Old)), lists:sort(ids(Table))),
    W#{table := Table};
performed(_Route, W) ->
    W.

ended(Id, #{table := Table, state := State} = W) ->
    {Table1, State1} = erx_wm_rio:arrange([R || #{id := I} = R <- Table, I =/= Id], ?SCREEN, none, State),
    W#{table := Table1, state := State1}.

%% The checks ------------------------------------------------------------------

check(Act, #{table := Table, state := State, pick := Pick, clicked := Clicked}) ->
    Expected = case [Id || #{id := Id, state := shown} <- Table, Id =:= Pick] of
                   [Id] -> Id;
                   [] -> none
               end,
    Key = #{device => <<"kbd">>, at => 0, event => {key, down, 30, $a, $a, []}},
    case erx_wm_rio:input(Key, Table, none, State) of
        {{to, Expected, Key}, _} -> ok;
        {drop, _} when Expected =:= none -> ok;
        Other -> error({key_not_to_the_pick, Act, Expected, Other})
    end,
    Accent = erx_theme:color(accent),
    Marked = lists:usort([Id || {Id, Sides} <- erx_wm_rio:decorate(Table, ?SCREEN, State),
                                {_, Colour} <- Sides, Colour =:= Accent]),
    Marked =:= [Expected || Expected =/= none] orelse error({border_not_on_the_pick, Act, Expected, Marked}),
    case Clicked of
        {Under, Before, {to, _, _}} when Under =/= Before -> error({click_reached_a_client, Act, Under});
        _ -> ok
    end,
    [error({off_screen, Act, Id, R}) || #{id := Id, rect := R} <- Table, not erx_wm:within(R, ?SCREEN)],
    #{mode := idle} = State,
    ok.

%% The model's own geometry ----------------------------------------------------

under({X, Y}, Table) ->
    case [Id || #{id := Id, state := shown, rect := {X0, Y0, X1, Y1}} <- Table,
                X >= X0, X < X1, Y >= Y0, Y < Y1] of
        [Id | _] -> Id;
        [] -> none
    end.

centre(Id, Table) ->
    {ok, #{rect := {X0, Y0, X1, Y1}}} = erx_wm:fetch(Id, Table),
    {(X0 + X1) div 2, (Y0 + Y1) div 2}.

centre_of(Item, Items) ->
    {Item, {X0, Y0, X1, Y1}} = lists:keyfind(Item, 1, Items),
    {(X0 + X1) div 2, (Y0 + Y1) div 2}.

%% Where the press naming a window is released: a move travels toward the screen's corner, so
%% no window reaches the background point, and a resize sweeps a rectangle good enough to take.
released(resize, {X, Y}) -> {X + 150, Y + 120};
released(_Command, {X, Y}) -> {X - 40, Y - 30}.

pointer({X, Y}, Buttons) ->
    #{device => <<"mouse">>, at => 0, event => {pointer, X, Y, Buttons}}.

ids(Table) -> [Id || #{id := Id} <- Table].

%% Cases -----------------------------------------------------------------------

made(N) ->
    lists:foldl(fun(Id, {Table, State}) ->
                        Row = #{id => Id, dir => {<<"10">>, integer_to_binary(Id)}, rect => ?SCREEN,
                                state => hidden},
                        {ok, T, S} = erx_wm_rio:place(new, Id, [Row | Table], ?SCREEN, none, State),
                        {T, S}
                end, erx_wm_rio:arrange([], ?SCREEN, none, erx_wm_rio:init(#{})), lists:seq(1, N)).

new_windows_cascade_on_the_screen_and_take_no_keyboard_test() ->
    {[#{id := 2, rect := {48, 48, 648, 448}, state := shown},
      #{id := 1, rect := {32, 32, 632, 432}, state := shown}] = Table, State} = made(2),
    ?assertEqual(none, erx_wm_rio:current(Table, State)).

resize_is_refused_off_the_screen_or_too_small_and_move_slides_on_test() ->
    {Table, State} = made(1),
    ?assertEqual({error, einval}, erx_wm_rio:place({resize, {0, 0, 50, 50}}, 1, Table, ?SCREEN, none, State)),
    ?assertEqual({error, einval}, erx_wm_rio:place({resize, {900, 0, 1100, 200}}, 1, Table, ?SCREEN, none, State)),
    {ok, [#{rect := {400, 400, 1000, 800}}], _} =
        erx_wm_rio:place({move, {900, 900, 0, 0}}, 1, Table, ?SCREEN, none, State),
    ?assertEqual({error, einval}, erx_wm_rio:place(hide, 1, [W#{state := hidden} || W <- Table],
                                                   ?SCREEN, none, State)).

arrange_shrinks_and_slides_windows_onto_a_smaller_screen_test() ->
    {Table, State} = made(1),
    {[#{rect := Rect}], _} = erx_wm_rio:arrange(Table, {0, 0, 320, 200}, none, State),
    ?assertEqual({0, 0, 320, 200}, Rect).

the_menu_lists_the_commands_then_the_hidden_windows_test() ->
    {Table, State} = made(3),
    Hidden = [case W of #{id := 2} -> W#{state := hidden}; _ -> W end || W <- Table],
    {{wm, menu}, Open} = erx_wm_rio:input(pointer(?BACKGROUND, ?RIGHT), Hidden, none, State),
    Items = erx_wm_rio:menu(Hidden, Open),
    ?assertEqual([resize, move, delete, hide, {show, 2}], [I || {I, _} <- Items]),
    [?assert(erx_wm:within(R, ?SCREEN)) || {_, R} <- Items],
    ?assertEqual(none, erx_wm_rio:menu(Hidden, State)).

a_press_on_the_background_without_the_menu_button_does_nothing_test() ->
    {Table, State} = made(1),
    ?assertMatch({drop, #{mode := idle}}, erx_wm_rio:input(pointer(?BACKGROUND, ?LEFT), Table, none, State)).

bad_configuration_is_refused_test() ->
    ?assertError(badarg, erx_wm_rio:init(#{chord => [1]})).
