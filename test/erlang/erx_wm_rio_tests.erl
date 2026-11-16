%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the overlapping window policy erx_wm_rio (test/host/erx_wm_test.rb),
%% after docs/design-display.md, "Verification and testing", the window system.
%%
%% The keyboard property is checked exhaustively over a small model: two sessions, at most
%% three windows, and every sequence of up to ?DEPTH acts, deduplicated by the state they
%% reach. A client's acts are `new` and the wctl requests top, bottom, hide, show, move and
%% resize, and a window's end; the user's acts are a press of the left button on a window's
%% centre or the background, a press of the right button on the background (the menu) and,
%% while a command waits, on a window's centre, a release (over each menu item while the
%% menu is open), a press of the right button while a move or resize is held, and Escape.
%% Client acts happen in every mode, so a request or an end can arrive while the policy
%% holds a menu, a waiting command or a move. The model asks the policy as erx_input
%% does: about a press and a key's down, and about the rest of a gesture only when the
%% press's answer gave the gesture to the policy. It keeps its own pick, set only by a
%% press on a shown window that is not current, a menu release over a hidden window, and
%% a move's or resize's naming press, and its own idea of the policy's mode; after every
%% act it checks that a key down goes to the pick while it is in the table and shown and
%% nowhere otherwise, that decorate/3 marks that window alone, that no press on a window
%% that is not current and no naming press reaches a client, that Escape and the right
%% button cancel a waiting or held command, and that every rectangle lies within the
%% screen. Every call passes the display's session, ?SESSION.

-module(erx_wm_rio_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(SCREEN, {0, 0, 1000, 800}).
%% A point no window of the model covers: default windows end by 776 by 576, a move puts
%% one at 300,300, the menu moves windows toward the screen's corner, and a resize gives one
%% at most 300 by 200 at the corner or a sweep from a centre.
-define(BACKGROUND, {990, 790}).
-define(MAX_WINDOWS, 3).
-define(DEPTH, 8).
-define(STATES_MIN, 100000).
-define(SESSION, <<"10">>).
-define(SESSIONS, [?SESSION, <<"20">>]).
-define(WCTL, [top, bottom, hide, show, {move, {300, 300, 301, 301}}, {resize, {0, 0, 300, 200}}]).
-define(LEFT, 1).
-define(RIGHT, 4).
-define(KEY_A, {key, down, 30, $a, $a, []}).
-define(ESCAPE, {key, down, 1, ?ERX_INPUT_RUNE_KESC, ?ERX_INPUT_RUNE_KESC, []}).

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
                                Key = maps:without([pressed], World1),
                                case S of
                                    #{Key := _} -> {Found, S};
                                    #{} -> {[World1 | Found], S#{Key => true}}
                                end
                        end, Acc, acts(World))
        end, {[], Seen}, Frontier),
    explore(Next, Seen1, Depth - 1).

%% The world: the policy's table and state, and the model's pick, the policy's mode as the
%% model expects it, the gesture's destination as erx_input fixes it (none while no button
%% is held) and the point and answer of the act just done, for the checks.
start() ->
    {Table, State} = erx_wm_rio:arrange([], ?SCREEN, ?SESSION, erx_wm_rio:init(#{})),
    #{table => Table, state => State, pick => none, next => 1, mode => idle, gesture => none,
      pressed => none}.

acts(#{table := Table, next := Next, mode := Mode, gesture := Gesture}) ->
    Ids = [Id || #{id := Id} <- Table],
    Centres = [centre(Id, Table) || Id <- Ids],
    Client = [{new, S} || Next =< ?MAX_WINDOWS, S <- ?SESSIONS]
        ++ [{wctl, Id, C} || Id <- Ids, C <- ?WCTL]
        ++ [{'end', Id} || Id <- Ids],
    User = case {Gesture, Mode} of
               {none, {choose, _}} ->
                   [{press, P, B} || P <- [?BACKGROUND | Centres], B <- [?LEFT, ?RIGHT]];
               {none, _} ->
                   [{press, ?BACKGROUND, ?RIGHT} | [{press, P, ?LEFT} || P <- [?BACKGROUND | Centres]]];
               {_, {menu, Press, Items}} ->
                   [{release, P} || P <- [Press | [centre_of(Item, Items) || {Item, _} <- Items]]];
               {_, {drag, Command, _Id, From}} ->
                   [{release, released(Command, From)}, right_held];
               {_, _} ->
                   [release]
           end,
    Client ++ User ++ [escape].

%% A client's acts never move the model's pick.
act({new, Session}, #{table := Table, state := State, next := Id} = W) ->
    Row = #{id => Id, dir => {Session, integer_to_binary(Id)}, rect => ?SCREEN, state => hidden},
    {ok, Table1, State1} = erx_wm_rio:place(new, Id, [Row | Table], ?SCREEN, ?SESSION, State),
    W#{table := Table1, state := State1, next := Id + 1, pressed := none};
act({wctl, Id, Command}, #{table := Table, state := State} = W) ->
    case erx_wm_rio:place(Command, Id, Table, ?SCREEN, ?SESSION, State) of
        {ok, Table1, State1} -> W#{table := Table1, state := State1, pressed := none};
        {error, einval} -> W#{pressed := none}
    end;
act({'end', Id}, W) ->
    ended(Id, W#{pressed := none});
%% The user's acts.
act({press, Point, Button}, #{table := Table, state := State, mode := Mode} = W) ->
    Under = under(Point, Table),
    Before = erx_wm_rio:current(Table, State),
    {Route, World} = ask(pointer(Point, Button), W),
    World1 = (performed(Route, World))#{gesture := destination(Route),
                                        pressed := {Point, Under, Before, Route}},
    pressed(Mode, Button, Under, Point, Route, World1);
act({release, Point}, #{gesture := policy, mode := Mode, table := Before} = W) ->
    {Route, World} = ask(pointer(Point, 0), W),
    released_over(Mode, Point, Before, Route, (performed(Route, World))#{gesture := none, pressed := none});
act({release, _Point}, W) ->
    W#{gesture := none, mode := idle, pressed := none};
act(release, W) ->
    act({release, ?BACKGROUND}, W);
act(right_held, #{gesture := policy, mode := {drag, _, _, From}} = W) ->
    {Route, World} = ask(pointer(From, ?LEFT bor ?RIGHT), W),
    Route =:= drop orelse error({right_press_not_cancelled, Route}),
    World#{mode := spent, pressed := none};
act(escape, #{table := Table, state := State, mode := Mode} = W) ->
    Event = #{device => <<"kbd">>, at => 0, event => ?ESCAPE},
    {Route, World} = ask(Event, W),
    case {Mode, Route} of
        {{choose, _}, drop} -> World#{mode := idle, pressed := none};
        {{drag, _, _, _}, drop} -> World#{mode := spent, pressed := none};
        {{choose, _}, _} -> error({escape_not_cancelled, Mode, Route});
        {{drag, _, _, _}, _} -> error({escape_not_cancelled, Mode, Route});
        _ ->
            Route =:= to_current(Event, Table, State) orelse error({escape_misrouted, Mode, Route}),
            World#{pressed := none}
    end.

%% The model's mode after a press, and the pick it makes: a press on a shown window that is
%% not current picks it; the right button on the background opens the menu; while a
%% command waits, the right button cancels it and the left names its window.
pressed(idle, _Button, Under, _Point, Route, #{pressed := {_, _, Before, _}} = W) when Under =/= none ->
    case {Route, Under =:= Before} of
        {{to, Under, _}, true} -> W#{pick := Under};
        {{to, _, _}, false} -> error({click_reached_a_client, Under});
        {{windows, [#{id := Under} | _]}, false} -> W#{pick := Under};
        _ -> error({press_answered, idle, Under, Route})
    end;
pressed(idle, ?RIGHT, none, Point, {wm, menu}, #{table := Table, state := State} = W) ->
    W#{mode := {menu, Point, erx_wm_rio:menu(Table, State)}};
pressed(idle, _Button, none, _Point, drop, W) ->
    W;
pressed({choose, _}, ?RIGHT, _Under, _Point, drop, W) ->
    W#{mode := idle};
pressed({choose, _} = Mode, ?RIGHT, _Under, _Point, Route, _W) ->
    error({right_press_not_cancelled, Mode, Route});
pressed({choose, _}, ?LEFT, none, _Point, drop, W) ->
    W#{mode := idle};
pressed({choose, hide}, ?LEFT, Under, _Point, {windows, _}, #{table := Table} = W) ->
    {ok, #{state := hidden}} = erx_wm:fetch(Under, Table),
    W#{mode := idle};
pressed({choose, delete}, ?LEFT, Under, _Point, {delete, Under}, W) ->
    (ended(Under, W))#{mode := spent};
pressed({choose, Command}, ?LEFT, Under, Point, {wm, Command}, W) when Command =:= move; Command =:= resize ->
    W#{mode := {drag, Command, Under, Point}, pick := Under};
pressed(Mode, Button, Under, _Point, Route, _W) ->
    error({press_answered, Mode, Button, Under, Route}).

%% The model's mode after the release of the policy's gesture, and the pick a menu release
%% over a window hidden in the table Before it makes; the menu's items are those laid out at
%% its press.
released_over({menu, Press, Items}, Point, Before, Route, W) ->
    Item = [I || Point =/= Press, {I, {X0, Y0, X1, Y1}} <- Items,
                 element(1, Point) >= X0, element(1, Point) < X1,
                 element(2, Point) >= Y0, element(2, Point) < Y1],
    case {Item, Route} of
        {[{show, Id}], {windows, [#{id := Id, state := shown} | _]}} ->
            {ok, #{state := hidden}} = erx_wm:fetch(Id, Before),
            W#{mode := idle, pick := Id};
        {[{show, Id}], drop} ->
            [error({show_dropped, Id}) || {ok, #{state := hidden}} <- [erx_wm:fetch(Id, Before)]],
            W#{mode := idle};
        {[{show, _}], _} -> error({show_answered, Item, Route});
        {[Command], drop} -> W#{mode := {choose, Command}};
        {[], drop} -> W#{mode := idle};
        _ -> error({release_answered, Item, Route})
    end;
%% A move's or resize's release raises its window while it is shown; any other release of
%% the policy's gesture, a cancelled or spent one included, changes nothing.
released_over({drag, _Command, Id, _From}, _Point, Before, Route, W) ->
    case {erx_wm:fetch(Id, Before), Route} of
        {{ok, #{state := shown}}, {windows, [#{id := Id} | _]}} -> W#{mode := idle};
        {{ok, #{state := shown}}, _} -> error({drag_not_taken, Id, Route});
        {_, drop} -> W#{mode := idle};
        _ -> error({release_answered, Id, Route})
    end;
released_over(_Mode, _Point, _Before, drop, W) ->
    W#{mode := idle}.

ask(Input, #{table := Table, state := State} = W) ->
    {Route, State1} = erx_wm_rio:input(Input, Table, ?SCREEN, ?SESSION, State),
    {Route, W#{state := State1}}.

%% The gesture's destination, as erx_input fixes it from the press's answer.
destination({to, _, _}) -> window;
destination({wm, _}) -> policy;
destination({delete, _}) -> policy;
destination(_) -> nowhere.

performed({windows, Table}, #{table := Old} = W) ->
    ?assertEqual(lists:sort(ids(Old)), lists:sort(ids(Table))),
    W#{table := Table};
performed(_Route, W) ->
    W.

ended(Id, #{table := Table, state := State} = W) ->
    {Table1, State1} = erx_wm_rio:arrange([R || #{id := I} = R <- Table, I =/= Id], ?SCREEN, ?SESSION,
                                          State),
    W#{table := Table1, state := State1}.

to_current(Event, Table, State) ->
    case erx_wm_rio:current(Table, State) of
        none -> drop;
        Id -> {to, Id, Event}
    end.

%% The checks ------------------------------------------------------------------

check(Act, #{table := Table, state := State, pick := Pick, mode := Mode, pressed := Pressed}) ->
    Expected = case [Id || #{id := Id, state := shown} <- Table, Id =:= Pick] of
                   [Id] -> Id;
                   [] -> none
               end,
    Key = #{device => <<"kbd">>, at => 0, event => ?KEY_A},
    case erx_wm_rio:input(Key, Table, ?SCREEN, ?SESSION, State) of
        {{to, Expected, Key}, _} -> ok;
        {drop, _} when Expected =:= none -> ok;
        Other -> error({key_not_to_the_pick, Act, Expected, Other})
    end,
    Accent = erx_theme:color(accent),
    Marked = lists:usort([Id || {Id, Sides} <- erx_wm_rio:decorate(Table, ?SCREEN, State),
                                {_, Colour} <- Sides, Colour =:= Accent]),
    Marked =:= [Expected || Expected =/= none] orelse error({border_not_on_the_pick, Act, Expected, Marked}),
    case Pressed of
        {_Point, Under, Before, {to, _, _}} when Under =/= Before -> error({click_reached_a_client, Act, Under});
        _ -> ok
    end,
    [error({off_screen, Act, Id, R}) || #{id := Id, rect := R} <- Table, not erx_wm:within(R, ?SCREEN)],
    same_mode(Mode, maps:get(mode, State)) orelse error({mode_diverged, Act, Mode, maps:get(mode, State)}),
    ok.

%% Whether the policy's mode is the one the model expects.
same_mode(idle, idle) -> true;
same_mode({menu, Press, Items}, {menu, Press, Items}) -> true;
same_mode({choose, Command}, {choose, Command}) -> true;
same_mode({drag, Command, Id, From}, {Command, Id, From}) -> true;
same_mode(spent, spent) -> true;
same_mode(_Model, _Policy) -> false.

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
                        {ok, T, S} = erx_wm_rio:place(new, Id, [Row | Table], ?SCREEN, ?SESSION, State),
                        {T, S}
                end, erx_wm_rio:arrange([], ?SCREEN, ?SESSION, erx_wm_rio:init(#{})), lists:seq(1, N)).

new_windows_cascade_on_the_screen_and_take_no_keyboard_test() ->
    {[#{id := 2, rect := {48, 48, 648, 448}, state := shown},
      #{id := 1, rect := {32, 32, 632, 432}, state := shown}] = Table, State} = made(2),
    ?assertEqual(none, erx_wm_rio:current(Table, State)).

resize_is_refused_off_the_screen_or_too_small_and_move_slides_on_test() ->
    {Table, State} = made(1),
    ?assertEqual({error, einval}, erx_wm_rio:place({resize, {0, 0, 50, 50}}, 1, Table, ?SCREEN, ?SESSION, State)),
    ?assertEqual({error, einval}, erx_wm_rio:place({resize, {900, 0, 1100, 200}}, 1, Table, ?SCREEN, ?SESSION, State)),
    {ok, [#{rect := {400, 400, 1000, 800}}], _} =
        erx_wm_rio:place({move, {900, 900, 0, 0}}, 1, Table, ?SCREEN, ?SESSION, State),
    ?assertEqual({error, einval}, erx_wm_rio:place(hide, 1, [W#{state := hidden} || W <- Table],
                                                   ?SCREEN, ?SESSION, State)).

arrange_shrinks_and_slides_windows_onto_a_smaller_screen_test() ->
    {Table, State} = made(1),
    {[#{rect := Rect}], _} = erx_wm_rio:arrange(Table, {0, 0, 320, 200}, ?SESSION, State),
    ?assertEqual({0, 0, 320, 200}, Rect).

the_menu_lists_the_commands_then_the_hidden_windows_test() ->
    {Table, State} = made(3),
    Hidden = [case W of #{id := 2} -> W#{state := hidden}; _ -> W end || W <- Table],
    {{wm, menu}, Open} = erx_wm_rio:input(pointer(?BACKGROUND, ?RIGHT), Hidden, ?SCREEN, ?SESSION, State),
    Items = erx_wm_rio:menu(Hidden, Open),
    ?assertEqual([resize, move, delete, hide, {show, 2}], [I || {I, _} <- Items]),
    [?assert(erx_wm:within(R, ?SCREEN)) || {_, R} <- Items],
    ?assertEqual(none, erx_wm_rio:menu(Hidden, State)).

a_press_on_the_background_without_the_menu_button_does_nothing_test() ->
    {Table, State} = made(1),
    ?assertMatch({drop, #{mode := idle}}, erx_wm_rio:input(pointer(?BACKGROUND, ?LEFT), Table, ?SCREEN, ?SESSION, State)).

bad_configuration_is_refused_test() ->
    ?assertError(badarg, erx_wm_rio:init(#{chord => [1]})).
