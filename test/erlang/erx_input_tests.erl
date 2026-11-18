%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The input router's core, erx_input (docs/design-display.md, "The input router" and
%% "Verification and testing"), as a state machine under the single policy and the
%% keymap us, with two windows of two sessions over the whole screen: the display's
%% session picks which one is shown, so a change of session moves the keyboard and the
%% pointer from one window to the other, and no session hides both.
%%
%% Two exhaustive runs step every sequence of up to ?DEPTH inputs, then end every source,
%% and check what each window received:
%%   * keys: per window, source and code, a down, its repeats and one up, in that order;
%%     no down or repeat while the window is hidden; the chord's key reaches no window;
%%     once every source has ended, no timer is set (key_order, key_while_hidden,
%%     chord_delivered, timer_left);
%%   * pointer: a hidden window receives only the events of the records that let a
%%     button or touch go, and once every source has ended every window's last event
%%     holds no button (pointer_while_hidden, pointer_held_at_end).
%% Every key's down or repeat that reaches a window reaches one the screen shows: the `frame`
%% action answers the frame of the table's layout, `{shown, D}`, so `focus` moves the
%% table ahead of the screen until a frame follows (key_not_displayed).
%% A random run checks that every pointer event lies inside the screen of its step
%% (pointer_outside_screen), with records before the first screen and screen changes.
-module(erx_input_tests).

%% A stub policy, input/5 of erx_wm, for the cases that need one.
-export([input/5]).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(DEPTH, 6).
-define(SCREEN, {0, 0, 640, 480}).
-define(A, ?ERX_EVDEV_KEY_A).
-define(SHIFT, ?ERX_EVDEV_KEY_LEFTSHIFT).
-define(CHORD, ?ERX_EVDEV_KEY_ESC).
-define(LEFT, ?ERX_EVDEV_BTN_LEFT).
-define(RIGHT, ?ERX_EVDEV_BTN_RIGHT).
-define(CONFIG, #{keymap => us, repeat_delay => 500, repeat_period => 126, chord => [?CHORD]}).

%% The world one sequence runs in: the router, its view, the clock, the sources' pids,
%% the last wake, what each window received, newest first, with its state then, and the
%% ids of the windows the screen shows. It starts with the first frame answered.
world() ->
    Sources = #{s1 => spawn(fun() -> ok end), s2 => spawn(fun() -> ok end)},
    World = #{state => erx_input:new(?CONFIG), session => <<"a">>, at => 0, sources => Sources,
              wake => none, got => [], screen => ?SCREEN, action => screen, displayed => []},
    frame(step({screen, ?SCREEN}, World)).

%% The frame of the table's layout answered: the screen now shows the table's shown windows.
frame(World) ->
    #{windows := Windows} = view(World),
    Displayed = [{Id, Rect} || #{id := Id, rect := Rect, state := shown} <- Windows],
    step({shown, Displayed}, World#{displayed := [Id || {Id, _} <- Displayed]}).

view(#{session := Session, screen := Screen}) ->
    Windows = [#{id => Id, dir => {Dir, <<"w">>}, rect => Screen,
                 state => case Dir of Session -> shown; _ -> hidden end}
               || {Id, Dir} <- [{1, <<"a">>}, {2, <<"b">>}]],
    #{windows => Windows, session => Session, policy => erx_wm_single, policy_state => #{}}.

step(In, #{state := State, got := Got, wake := Wake, displayed := Displayed} = World) ->
    View = #{windows := Windows} = view(World),
    {Next, [{policy_state, #{}} | Outs]} = erx_input:step(In, View, State),
    {Got1, Wake1} = lists:foldl(
                      fun({to, Id, #{event := Event}}, {G, Wk}) ->
                              {ok, #{state := WindowState}} = erx_wm:fetch(Id, Windows),
                              ok = on_screen(Id, Event, Displayed),
                              {[{Id, WindowState, Event, maps:get(action, World)} | G], Wk};
                         ({wake, At}, {G, _}) -> {G, At};
                         (_Other, Acc) -> Acc
                      end, {Got, Wake}, Outs),
    World#{state := Next, got := Got1, wake := Wake1}.

on_screen(Id, {key, Edge, _, _, _, _} = Event, Displayed) when Edge =/= up ->
    case lists:member(Id, Displayed) of
        true -> ok;
        false -> error({key_not_displayed, Id, Event})
    end;
on_screen(_Id, _Event, _Displayed) ->
    ok.

%% One action of a run, at a clock 300 ms on from the last.
act(Action, #{at := At0, sources := Sources} = World0) ->
    At = At0 + 300,
    World = World0#{at := At, action := Action},
    case Action of
        {gone, Source} -> step({gone, maps:get(Source, Sources), At}, World);
        {Source, Record} ->
            step({record, maps:get(Source, Sources), atom_to_binary(Source), At, Record}, World);
        tick -> step({tick, At}, World);
        focus -> World#{session := next_session(maps:get(session, World))};
        frame -> frame(World)
    end.

next_session(<<"a">>) -> <<"b">>;
next_session(<<"b">>) -> none;
next_session(none) -> <<"a">>.

%% Every sequence of up to Depth actions from Alphabet, each checked by Check after every
%% source has ended.
explore(0, _Alphabet, World, Check) ->
    Check(finish(World));
explore(Depth, Alphabet, World, Check) ->
    Check(finish(World)),
    lists:foreach(fun(Action) -> explore(Depth - 1, Alphabet, act(Action, World), Check) end, Alphabet).

finish(World) -> act({gone, s2}, act({gone, s1}, World)).

%% Keys -----------------------------------------------------------------------

keys_alphabet() ->
    [{s1, {key, down, ?A}}, {s1, {key, up, ?A}}, {s1, {key, down, ?SHIFT}}, {s1, {key, up, ?SHIFT}},
     {s1, {key, down, ?CHORD}}, {s1, {key, up, ?CHORD}}, {s2, {key, down, ?A}}, {s2, {key, up, ?A}},
     focus, frame, {s1, release}, {gone, s1}, tick].

check_keys(#{got := Got, wake := Wake}) ->
    Keys = [{Id, State, Event} || {Id, State, {key, _, _, _, _, _} = Event, _} <- lists:reverse(Got)],
    [error({chord_delivered, E}) || {_, _, {key, _, ?CHORD, _, _, _} = E} <- Keys],
    [error({key_while_hidden, Id, E}) || {Id, hidden, {key, Edge, _, _, _, _} = E} <- Keys, Edge =/= up],
    %% Grouped by window and code, over the sources in turn: keys of both sources share
    %% a code only for the letter, so each source's own order is checked by its group.
    Groups = lists:foldl(fun({Id, _, {key, Edge, Code, _, _, _}}, Acc) ->
                                 maps:update_with({Id, Code}, fun(L) -> [Edge | L] end, [Edge], Acc)
                         end, #{}, Keys),
    maps:foreach(fun(Group, Edges) -> ok = key_order(Group, lists:reverse(Edges), 0) end, Groups),
    case Wake of none -> ok; _ -> error({timer_left, Wake}) end.

%% Each edge against the downs outstanding for the group: an up needs one, a repeat needs
%% one, and none is outstanding at the end. The letter's group counts both sources' downs.
key_order(_Group, [], 0) -> ok;
key_order(Group, [], Held) -> error({key_order, Group, {held_at_end, Held}});
key_order(Group, [down | Rest], Held) -> key_order(Group, Rest, Held + 1);
key_order(Group, [repeat | Rest], Held) when Held > 0 -> key_order(Group, Rest, Held);
key_order(Group, [up | Rest], Held) when Held > 0 -> key_order(Group, Rest, Held - 1);
key_order(Group, [Edge | _], _Held) -> error({key_order, Group, Edge}).

keys_exhaustive_test_() ->
    {timeout, 600, fun() -> explore(?DEPTH, keys_alphabet(), world(), fun check_keys/1) end}.

%% Pointer --------------------------------------------------------------------

pointer_alphabet() ->
    [{s1, {key, down, ?LEFT}}, {s1, {key, up, ?LEFT}},
     {s1, {touch, 0, down, 100, 100}}, {s1, {touch, 0, move, 200, 200}}, {s1, {touch, 0, up, 200, 200}},
     {s1, {pointer, abs, 60000, 60000}}, {s2, {key, down, ?LEFT}}, {s2, {key, up, ?LEFT}},
     focus, {s1, release}, {gone, s1}].

check_pointer(#{got := Got}) ->
    Last = lists:foldl(fun({Id, State, {pointer, _, _, Buttons}, Action}, Seen) ->
                               case {State, lets_go(Action)} of
                                   {hidden, false} -> error({pointer_while_hidden, Id, Action});
                                   _ -> ok
                               end,
                               Seen#{Id => Buttons};
                          (_Key, Seen) -> Seen
                       end, #{}, lists:reverse(Got)),
    [error({pointer_held_at_end, Id, B}) || {Id, B} <- maps:to_list(Last), B =/= 0],
    ok.

%% The actions that let a button or touch go, the only ones a hidden window hears of.
lets_go({_, {key, up, _}}) -> true;
lets_go({_, {touch, _, up, _, _}}) -> true;
lets_go({_, release}) -> true;
lets_go({gone, _}) -> true;
lets_go(_Action) -> false.

pointer_exhaustive_test_() ->
    {timeout, 600, fun() -> explore(?DEPTH, pointer_alphabet(), world(), fun check_pointer/1) end}.

%% A window hidden mid-gesture hears its own buttons go up, and never of a button
%% pressed after it was hidden: the right button's down and up reach no window.
hidden_window_hears_only_its_own_buttons_test() ->
    Pressed = lists:foldl(fun act/2, world(),
                          [{s1, {key, down, ?LEFT}}, focus, {s1, {key, down, ?RIGHT}}]),
    #{got := Got} = lists:foldl(fun act/2, Pressed,
                                [{s1, {key, up, ?LEFT}}, {s1, {key, up, ?RIGHT}}]),
    ?assertEqual([{1, shown, 1}, {1, hidden, 0}],
                 [{Id, State, B} || {Id, State, {pointer, _, _, B}, _} <- lists:reverse(Got)]).

%% A doubled touch down, and a move or an up at a slot not held, change nothing.
unmatched_touch_changes_nothing_test() ->
    W0 = act({s1, {touch, 0, down, 10, 10}}, world()),
    lists:foreach(
      fun(Record) ->
              #{state := S0} = W0,
              #{state := S1, got := Got} = act({s1, Record}, W0#{got := []}),
              ?assertEqual([], Got),
              ?assertEqual(erx_input:dropped(S0) + 1, erx_input:dropped(S1))
      end, [{touch, 0, down, 10, 10}, {touch, 1, move, 10, 10}, {touch, 1, up, 10, 10}]).

%% A key typed with Shift held types the shift layer, and its k set names Shift.
shift_selects_the_layer_test() ->
    W = act({s1, {key, down, ?A}}, act({s1, {key, down, ?SHIFT}}, world())),
    [{1, shown, {key, down, ?A, $A, $a, [?ERX_INPUT_RUNE_KSHIFT]}, _} | _] = maps:get(got, W).

%% A window's repeat: delayed, periodic, with the runes of its down, stopped by the up.
repeat_test() ->
    W0 = act({s1, {key, down, ?A}}, world()),
    #{state := S0, at := At, wake := Due} = W0,
    ?assertEqual(At + 500, Due),
    View = view(W0),
    ?assertMatch({_, [{policy_state, _}]}, erx_input:step({tick, Due - 1}, View, S0)),
    {S1, [{policy_state, _} | Outs]} = erx_input:step({tick, Due}, View, S0),
    ?assertMatch([{to, 1, #{event := {key, repeat, ?A, $a, $a, []}}}, {wake, _}], Outs),
    Up = {record, maps:get(s1, maps:get(sources, W0)), <<"s1">>, Due + 1, {key, up, ?A}},
    {_, [{policy_state, _} | Outs2]} = erx_input:step(Up, View, S1),
    ?assertMatch([{to, 1, #{event := {key, up, ?A, $a, $a, []}}}, {wake, none}], Outs2).

%% Records before the first screen are dropped and counted.
before_the_screen_test() ->
    S0 = erx_input:new(?CONFIG),
    View = view(#{session => <<"a">>, screen => ?SCREEN}),
    {S1, [{policy_state, #{}}]} = erx_input:step({record, self(), <<"k">>, 0, {key, down, ?A}}, View, S0),
    ?assertEqual(1, erx_input:dropped(S1)).

%% The table ahead of the screen ------------------------------------------------

%% docs/design-display.md, "The input router", "A key's down": under the single policy,
%% while the table has chosen a window whose frame the screen has not answered, a key's
%% down reaches neither that window nor the one leaving the screen, and the first after
%% {shown, D} reaches the window D shows. A key held before the change still goes up at
%% the window its down went to.

%% The shown window ends and the table shows the session's next one.
a_key_reaches_no_window_while_the_next_is_not_yet_shown_test() ->
    Before = single([{1, <<"a">>, shown}, {2, <<"a">>, hidden}], <<"a">>),
    After = single([{2, <<"a">>, shown}], <<"a">>),
    {S, Got} = run([{key(down, ?A), Before},
                    {key(up, ?A), Before},
                    {key(down, ?A), After},
                    {key(up, ?A), After},
                    {shown(2), After},
                    {key(down, ?A), After}], shown_first(Before)),
    ?assertEqual([{1, down, ?A}, {1, up, ?A}, {2, down, ?A}], Got),
    ?assertEqual(1, erx_input:dropped(S)).

%% The table chooses a window the screen does not show yet, as when the display's session
%% moves; Shift, held on the window leaving the screen, goes up there.
a_key_reaches_neither_window_until_the_chosen_one_is_shown_test() ->
    Before = single([{1, <<"a">>, shown}, {2, <<"b">>, hidden}], <<"a">>),
    After = single([{1, <<"a">>, hidden}, {2, <<"b">>, shown}], <<"b">>),
    {S, Got} = run([{key(down, ?SHIFT), Before},
                    {key(down, ?A), After},
                    {key(up, ?A), After},
                    {key(up, ?SHIFT), After},
                    {shown(2), After},
                    {key(down, ?A), After}], shown_first(Before)),
    ?assertEqual([{1, down, ?SHIFT}, {1, up, ?SHIFT}, {2, down, ?A}], Got),
    ?assertEqual(1, erx_input:dropped(S)).

%% Before the first frame is answered the screen shows no window, so no key reaches one.
no_key_before_the_first_frame_test() ->
    View = single([{1, <<"a">>, shown}], <<"a">>),
    {S0, _} = erx_input:step({screen, ?SCREEN}, View, erx_input:new(?CONFIG)),
    {S, Got} = run([{key(down, ?A), View}, {key(up, ?A), View}], S0),
    ?assertEqual([], Got),
    ?assertEqual(1, erx_input:dropped(S)).

%% A key held in the kiosk while a front window opens and ends: the front window's end
%% returns the kiosk to the table while the screen still shows the front window, and
%% the kiosk's repeats resume only once {shown, D} shows it again.
a_repeat_reaches_no_window_until_it_is_shown_again_test() ->
    Kiosk = single([{1, <<"a">>, shown}], <<"a">>),
    Front = single([{1, <<"a">>, hidden}, {2, <<"a">>, shown}], <<"a">>),
    {_S, Got} = run([{key(down, ?A), Kiosk},
                     {shown(2), Front},
                     {{tick, 600}, Kiosk},
                     {shown(1), Kiosk},
                     {{tick, 700}, Kiosk},
                     {key(up, ?A), Kiosk}], shown_first(Kiosk)),
    ?assertEqual([{1, down, ?A}, {1, repeat, ?A}, {1, up, ?A}], Got).

%% A policy that answers a window the screen shows but the table hides: its down is
%% dropped and counted, whatever the policy answers.
a_key_reaches_no_window_the_table_hides_test() ->
    View = (single([{1, <<"a">>, hidden}, {2, <<"a">>, shown}], <<"a">>))#{policy := ?MODULE},
    {S, Got} = run([{key(down, ?A), View}, {key(up, ?A), View}], shown_first(View)),
    ?assertEqual([], Got),
    ?assertEqual(1, erx_input:dropped(S)).

input(Event, _Windows, _Screen, _Session, State) -> {{to, 1, Event}, State}.

%% A view of the single policy over Windows, {Id, Dir, State}, with Session the display's.
single(Windows, Session) ->
    #{windows => [#{id => Id, dir => {Dir, <<"w">>}, rect => ?SCREEN, state => State}
                  || {Id, Dir, State} <- Windows],
      session => Session, policy => erx_wm_single, policy_state => #{}}.

%% A router with the screen, whose first frame shows window 1.
shown_first(View) ->
    {S, _} = run([{{screen, ?SCREEN}, View}, {shown(1), View}], erx_input:new(?CONFIG)),
    S.

shown(Id) -> {shown, [{Id, ?SCREEN}]}.

%% A key's record with the test process as the keyboard, so every step's downs and ups match.
key(Edge, Code) -> {record, self(), <<"kbd">>, 0, {key, Edge, Code}}.

%% Each input stepped over its view, from State: the state after and the keys delivered,
%% {Window, Edge, Code}, in order.
run(Steps, State) ->
    lists:foldl(fun({In, View}, {S, Got}) ->
                        {S1, [{policy_state, _} | Outs]} = erx_input:step(In, View, S),
                        {S1, Got ++ [{Id, Edge, Code}
                                     || {to, Id, #{event := {key, Edge, Code, _, _, _}}} <- Outs]}
                end, {State, []}, Steps).

%% Random ----------------------------------------------------------------------

pointer_inside_the_screen_test() ->
    _ = rand:seed(exsss, {1, 2, 3}),
    lists:foreach(fun(_) -> random_run(60) end, lists:seq(1, 500)).

random_run(Steps) ->
    Source = spawn(fun() -> ok end),
    View0 = view(#{session => <<"a">>, screen => ?SCREEN}),
    lists:foldl(
      fun(_, {S, Screen}) ->
              {In, Screen1} = random_input(Source, Screen),
              View = case Screen1 of
                         none -> View0;
                         _ -> view(#{session => <<"a">>, screen => Screen1})
                     end,
              {S1, [{policy_state, _} | Outs]} = erx_input:step(In, View, S),
              [inside(X, Y, Screen1) || {to, _, #{event := {pointer, X, Y, _}}} <- Outs],
              {S1, Screen1}
      end, {erx_input:new(?CONFIG), none}, lists:seq(1, Steps)).

random_input(Source, Screen) ->
    Big = 16#7fffffff,
    case rand:uniform(5) of
        1 ->
            X0 = rand:uniform(2000) - 1000, Y0 = rand:uniform(2000) - 1000,
            New = {X0, Y0, X0 + rand:uniform(800), Y0 + rand:uniform(600)},
            {{screen, New}, New};
        2 ->
            {{record, Source, <<"m">>, 0, {pointer, rel, rand:uniform(2 * Big + 1) - Big - 1,
                                           rand:uniform(2 * Big + 1) - Big - 1}}, Screen};
        3 ->
            {{record, Source, <<"m">>, 0, {pointer, abs, rand:uniform(65536) - 1,
                                           rand:uniform(65536) - 1}}, Screen};
        4 ->
            {{record, Source, <<"m">>, 0, {touch, 0, case rand:uniform(3) of 1 -> down; 2 -> move; 3 -> up end,
                                           rand:uniform(65536) - 1, rand:uniform(65536) - 1}}, Screen};
        5 ->
            {{record, Source, <<"m">>, 0, {key, case rand:uniform(2) of 1 -> down; 2 -> up end, ?LEFT}}, Screen}
    end.

inside(X, Y, {X0, Y0, X1, Y1}) when X >= X0, X < X1, Y >= Y0, Y < Y1 -> ok;
inside(X, Y, Screen) -> error({pointer_outside_screen, X, Y, Screen}).
