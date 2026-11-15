%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_wm_rio).
-moduledoc """
The overlapping window policy of a desktop (docs/design-display.md,
"Windows and the window system"), after Plan 9's rio: windows in a
stacking order, each shown window framed by a hairline border whose
colour marks the current window, pointer events to the window under the
pointer, key events to the current window, and the right button outside
every window kept for the window system's menu. Every session's windows
are shown alike; the policy takes no session into account.

**The current window** is derived, never stored: the state keeps the
user's pick, and the current window is the picked window while it is in
the table and shown, and none otherwise (current/2). Only input/5 sets
the pick, and only on the user's own acts: a press on a shown window
that is not current, and a menu choice that shows, moves or resizes a
window. place/6 and arrange/4 never touch it, so no client gains the
keyboard by a `wctl` request, a `mkdir` or another window's end. Window
ids are never reused, so a pick whose window ended derives no window and
needs no cleanup.

**Geometry**, as rio's wctl.c, with every rectangle kept on the screen.
A new window gets rio's default rectangle, at most 600 by 400 pixels,
its corner 32 pixels in from the screen's and 16 more for each of the
last ten windows made, moved onto the screen; it is shown and raised,
and is not picked. `resize` takes the rectangle as given and refuses one
smaller than rio's 100 pixels wide or than the border and one line high,
or not within the screen. `move` keeps the size, puts the corner at the
rectangle's first corner and slides the window onto the screen. `hide`
and `show` refuse a window already in that state; `show` and `top`
raise the window, `bottom` lowers it. arrange/4 slides every window onto
a changed screen, shrinking one larger than it.

**Pointer.** Motion with no button held goes to the window under the
pointer. A press on the current window is delivered, and the router
keeps the rest of its gesture with that window. A press on another shown
window raises and picks it, answering `{windows, Table}`, so that click
reaches no client. The right button (Plan 9's button 3, bit 4) pressed
outside every window opens the menu (menu/2), and anything else outside
every window is dropped. A wheel step goes to the current window.

**The menu** is a column of items below the press point, moved onto the
screen: `resize`, `move`, `delete`, `hide` and then each hidden window,
topmost first, as `{show, Id}`. Releasing the button over `{show, Id}`
shows, raises and picks that window. Releasing it over one of the four
commands waits for the next press, which names the window it acts on:
`hide` hides it, `delete` answers `{delete, Id}`, which erx_winfs
performs by ending the window, and `move` and `resize` pick it and take
the press's gesture, whose release raises the window, while it is still
shown, and moves it by the pointer's travel or gives it the rectangle
swept from the press to the release. The items are laid out when the
menu opens and kept until it closes, so no client's request changes
what lies under the release. A press that names no window, a release
over no item, and a release where the menu was pressed do nothing.

**Cancel.** A chosen command is cancelled before it takes effect by the
Escape key's down or a press of the right button: while it waits for
the naming press, which a right press therefore never is, and, for
`move` and `resize`, during the naming press's gesture, whose release
then changes nothing. The pick a naming press made stays.
""".

-behaviour(erx_wm).

-export([init/1, place/6, arrange/4, decorate/3, input/5, current/2, menu/2]).
-export_type([state/0]).

-include("generated/erx_abi.hrl").

-type item() :: erx_wm:menu_item().
-type command() :: resize | move | delete | hide.
-type point() :: {erx_wm:coord(), erx_wm:coord()}.

-doc """
What the policy is doing between input events: nothing; showing the
menu opened at a point; waiting for the press that names the window a
command acts on; holding the gesture that moves or resizes a window,
from the point it was pressed at; or holding, until its release, the
rest of a gesture whose act is done or cancelled: the press that named
the window to delete, or a move or resize cancelled.
""".
-type mode() :: idle
              | {menu, point(), [{item(), erx_wm:rect()}]}
              | {choose, command()}
              | {move | resize, erx_wm:window_id(), point()}
              | spent.

-doc "The policy's state, threaded by erx_winfs and erx_input.".
-type state() :: #{pick := erx_wm:window_id() | none,
                   cascade := 0..9,
                   mode := mode()}.

-define(MIN_DX, 100).
%% rio's goodrect asks for the border, a pixel inside it on each side and a line of the
%% font; the font is the client's, so one pixel stands for the line.
-define(MIN_DY, (2 * (erx_theme:hairline() + 1) + 1)).
-define(DEFAULT_DX, 600).
-define(DEFAULT_DY, 400).
-define(CASCADE_START, 32).
-define(CASCADE_STEP, 16).
-define(CASCADE_LENGTH, 10).
-define(MENU_BUTTON, 4).
-define(ITEM_DX, 200).
-define(ITEM_DY, (maps:get(line, erx_theme:role(body)) + 2 * erx_theme:space(s))).
-define(COMMANDS, [resize, move, delete, hide]).

-doc "The policy's initial state; a configuration with any key raises `badarg`.".
-spec init(map()) -> state().
init(Config) when Config =:= #{} ->
    #{pick => none, cascade => 0, mode => idle};
init(Config) ->
    error(badarg, [Config]).

-doc "Answers a geometry request about window `Id`; see the moduledoc.".
-spec place(erx_wm:request(), erx_wm:window_id(), [erx_wm:window()], erx_wm:rect(),
            erx_wm:session(), state()) ->
          {ok, [erx_wm:window()], state()} | {error, einval}.
place(Request, Id, Windows, Screen, _Session, State) ->
    case {nonempty(Screen), erx_wm:fetch(Id, Windows)} of
        {true, {ok, Window}} -> request(Request, Window, Windows, Screen, State);
        _ -> {error, einval}
    end.

-doc "Every window slid onto the screen, as after the screen changed.".
-spec arrange([erx_wm:window()], erx_wm:rect(), erx_wm:session(), state()) ->
          {[erx_wm:window()], state()}.
arrange(Windows, Screen, _Session, State) ->
    {[W#{rect := fitted(Rect, Screen)} || W = #{rect := Rect} <- Windows], State}.

-doc """
Each shown window's border, one hairline inside its rectangle, in the
theme's `accent` for the current window and `line` for the others.
""".
-spec decorate([erx_wm:window()], erx_wm:rect(), state()) ->
          [{erx_wm:window_id(), [{erx_wm:rect(), erx_wm:color()}]}].
decorate(Windows, _Screen, State) ->
    Current = current(Windows, State),
    [{Id, [{Side, color(Id, Current)} || Side <- border(Rect)]}
     || #{id := Id, rect := Rect} <- erx_wm:shown(Windows)].

-doc "Routes one input event the router asks about; see the moduledoc.".
-spec input(erx_wm:input(), [erx_wm:window()], erx_wm:rect(), erx_wm:session(), state()) ->
          {erx_wm:route(), state()}.
input(#{event := {pointer, X, Y, Buttons}} = Input, Windows, Screen, _Session, #{mode := Mode} = State) ->
    case {Buttons band ?MENU_BUTTON, cancelled(Mode)} of
        {?MENU_BUTTON, {ok, Next}} -> {drop, State#{mode := Next}};
        _ -> pointer(Mode, {X, Y}, Buttons, Input, Windows, Screen, State)
    end;
input(#{event := {key, down, _, _, ?ERX_INPUT_RUNE_KESC, _}} = Input, Windows, _Screen, _Session,
      #{mode := Mode} = State) ->
    %% The Escape key by its unshifted rune, so a control chord that types ESC cancels nothing.
    case cancelled(Mode) of
        {ok, Next} -> {drop, State#{mode := Next}};
        none -> {to_current(Input, Windows, State), State}
    end;
input(#{event := {key, _, _, _, _, _}} = Input, Windows, _Screen, _Session, State) ->
    {to_current(Input, Windows, State), State};
input(#{event := {wheel, _}} = Input, Windows, _Screen, _Session, State) ->
    {to_current(Input, Windows, State), State};
input(#{event := {touch, _, _, _, _}}, _Windows, _Screen, _Session, State) ->
    %% The router makes a touch a pointer with button 1, so none is asked.
    {drop, State}.

-doc "The current window: the pick while it is in the table and shown, or none.".
-spec current([erx_wm:window()], state()) -> erx_wm:window_id() | none.
current(Windows, #{pick := Pick}) ->
    case erx_wm:fetch(Pick, Windows) of
        {ok, #{state := shown}} -> Pick;
        _ -> none
    end.

-doc """
The menu while it is open, each item with its rectangle on the screen
in order, or none; what the menu's drawer shows.
""".
-spec menu([erx_wm:window()], state()) -> [{item(), erx_wm:rect()}] | none.
menu(_Windows, #{mode := {menu, _Press, Items}}) ->
    Items;
menu(_Windows, _State) ->
    none.

%% The menu's items as the press that opens it finds them, fixed for the menu's life, so
%% no client's request reorders what lies under the user's release; the rows that do not
%% fit on the screen are left out.
laid_out({X, Y}, Windows, Screen) ->
    Items = ?COMMANDS ++ [{show, Id} || #{id := Id, state := hidden} <- Windows],
    Dy = ?ITEM_DY,
    {X0, Y0, _, _} = fitted({X, Y, X + ?ITEM_DX, Y + Dy * length(Items)}, Screen),
    [{Item, Rect} || {I, Item} <- lists:enumerate(0, Items),
                     Rect <- [{X0, Y0 + I * Dy, X0 + ?ITEM_DX, Y0 + (I + 1) * Dy}],
                     erx_wm:within(Rect, Screen)].

%% Geometry -------------------------------------------------------------------

request(new, Window, Windows, Screen, #{cascade := Index} = State) ->
    {ok, raise(Window#{rect := default_rect(Index, Screen), state := shown}, Windows),
     State#{cascade := (Index + 1) rem ?CASCADE_LENGTH}};
request({resize, Rect}, Window, Windows, Screen, State) ->
    case good_rect(Rect, Screen) of
        true -> {ok, replace(Window#{rect := Rect}, Windows), State};
        false -> {error, einval}
    end;
request({move, {X, Y, _, _}}, Window, Windows, Screen, State) ->
    case moved(Window, {X, Y}, Screen) of
        {ok, Rect} -> {ok, replace(Window#{rect := Rect}, Windows), State};
        error -> {error, einval}
    end;
request(hide, #{state := shown} = Window, Windows, _Screen, State) ->
    {ok, replace(Window#{state := hidden}, Windows), State};
request(show, #{state := hidden} = Window, Windows, _Screen, State) ->
    {ok, raise(Window#{state := shown}, Windows), State};
request(top, Window, Windows, _Screen, State) ->
    {ok, raise(Window, Windows), State};
request(bottom, Window, Windows, _Screen, State) ->
    {ok, lower(Window, Windows), State};
request(_Refused, _Window, _Windows, _Screen, _State) ->
    {error, einval}.

%% rio's newrect: a cascade of ten corners, each window at most the default size and
%% never wider or taller than the screen less a border.
default_rect(Index, {SX0, SY0, SX1, SY1} = Screen) ->
    Border = erx_theme:hairline(),
    Dx = max(1, min(?DEFAULT_DX, SX1 - SX0 - 2 * Border)),
    Dy = max(1, min(?DEFAULT_DY, SY1 - SY0 - 2 * Border)),
    Offset = ?CASCADE_START + ?CASCADE_STEP * Index,
    fitted({SX0 + Offset, SY0 + Offset, SX0 + Offset + Dx, SY0 + Offset + Dy}, Screen).

%% rio's goodrect, with the window kept wholly on the screen.
good_rect({X0, Y0, X1, Y1} = Rect, Screen) ->
    X1 - X0 >= ?MIN_DX andalso Y1 - Y0 >= ?MIN_DY andalso erx_wm:within(Rect, Screen).

%% The window's rectangle with its corner at Corner, slid onto the screen, or error when
%% it is larger than the screen.
moved(#{rect := {X0, Y0, X1, Y1}}, {X, Y}, Screen) ->
    Rect = slid({X, Y, X + (X1 - X0), Y + (Y1 - Y0)}, Screen),
    case erx_wm:within(Rect, Screen) of
        true -> {ok, Rect};
        false -> error
    end.

%% Slides the rectangle, size unchanged, toward the screen until it lies on it; one larger
%% than the screen ends at the screen's first corner.
slid({X0, Y0, X1, Y1}, {SX0, SY0, SX1, SY1}) ->
    X = max(SX0, min(X0, SX1 - (X1 - X0))),
    Y = max(SY0, min(Y0, SY1 - (Y1 - Y0))),
    {X, Y, X + (X1 - X0), Y + (Y1 - Y0)}.

%% The rectangle no larger than the screen, slid onto it.
fitted({X0, Y0, X1, Y1}, {SX0, SY0, SX1, SY1} = Screen) ->
    slid({X0, Y0, X0 + min(X1 - X0, SX1 - SX0), Y0 + min(Y1 - Y0, SY1 - SY0)}, Screen).

nonempty({X0, Y0, X1, Y1}) -> X0 < X1 andalso Y0 < Y1.

contains({X0, Y0, X1, Y1}, {X, Y}) -> X >= X0 andalso X < X1 andalso Y >= Y0 andalso Y < Y1.

replace(#{id := Id} = Window, Windows) ->
    [case W of #{id := Id} -> Window; _ -> W end || W <- Windows].

raise(#{id := Id} = Window, Windows) ->
    [Window | [W || #{id := Other} = W <- Windows, Other =/= Id]].

lower(#{id := Id} = Window, Windows) ->
    [W || #{id := Other} = W <- Windows, Other =/= Id] ++ [Window].

%% The border's four sides, one hairline inside the rectangle; a window too small for
%% them is filled by them.
border({X0, Y0, X1, Y1}) ->
    B = lists:min([erx_theme:hairline(), (X1 - X0) div 2, (Y1 - Y0) div 2]),
    [Side || {SX0, SY0, SX1, SY1} = Side <- [{X0, Y0, X1, Y0 + B}, {X0, Y1 - B, X1, Y1},
                                               {X0, Y0 + B, X0 + B, Y1 - B},
                                               {X1 - B, Y0 + B, X1, Y1 - B}],
            SX0 < SX1, SY0 < SY1].

color(Id, Id) -> erx_theme:color(accent);
color(_Id, _Current) -> erx_theme:color(line).

%% Input ----------------------------------------------------------------------

%% A pointer event by what the policy is doing. A press is an event with buttons held
%% that the router asks about with no gesture running; the events the router asks about
%% with buttons held during a gesture are the policy's own gesture, the menu's or a
%% move's or resize's, whose release is the event with no button held.
pointer(idle, Point, 0, Input, Windows, _Screen, State) ->
    {to_under(Point, Input, Windows), State};
pointer(idle, Point, Buttons, Input, Windows, Screen, State) ->
    press(under(Point, Windows), Point, Buttons, Input, Windows, Screen, State);
pointer({menu, Press, Items}, Point, 0, _Input, Windows, _Screen, State) ->
    chosen(item(Press, Point, Items), Windows, State#{mode := idle});
pointer({choose, _}, Point, 0, Input, Windows, _Screen, State) ->
    %% Motion while the policy waits for the press that names a window.
    {to_under(Point, Input, Windows), State};
pointer({choose, Command}, Point, _Buttons, _Input, Windows, _Screen, State) ->
    named(Command, under(Point, Windows), Point, Windows, State#{mode := idle});
pointer({Gesture, Id, From}, To, 0, _Input, Windows, Screen, State) when Gesture =:= move; Gesture =:= resize ->
    {swept(Gesture, Id, From, To, Windows, Screen), State#{mode := idle}};
pointer(spent, _Point, 0, _Input, _Windows, _Screen, State) ->
    {drop, State#{mode := idle}};
pointer(_HeldGesture, _Point, _Buttons, _Input, _Windows, _Screen, State) ->
    {drop, State}.

%% The mode a cancel leaves, Escape's down or a right press, when a chosen command has not
%% taken effect: no command waits, and a held move or resize spends the rest of its
%% gesture; none in every other mode.
cancelled({choose, _}) -> {ok, idle};
cancelled({Gesture, _Id, _From}) when Gesture =:= move; Gesture =:= resize -> {ok, spent};
cancelled(_Mode) -> none.

%% A press with no gesture of the policy's running: delivered on the current window, a
%% pick of any other shown window, the menu outside every window.
press(none, Point, Buttons, _Input, Windows, Screen, State) when Buttons band ?MENU_BUTTON =/= 0 ->
    {{wm, menu}, State#{mode := {menu, Point, laid_out(Point, Windows, Screen)}}};
press(none, _Point, _Buttons, _Input, _Windows, _Screen, State) ->
    {drop, State};
press(Id, _Point, _Buttons, Input, Windows, _Screen, State) ->
    case current(Windows, State) of
        Id -> {{to, Id, Input}, State};
        _Other -> {{windows, raised(Id, Windows)}, State#{pick := Id}}
    end.

%% The menu item released over: a hidden window shown, raised and picked, or a command
%% that waits for the press naming its window.
chosen({show, Id}, Windows, State) ->
    case erx_wm:fetch(Id, Windows) of
        {ok, #{state := hidden} = Window} -> {{windows, raise(Window#{state := shown}, Windows)},
                                             State#{pick := Id}};
        _ -> {drop, State}
    end;
chosen(none, _Windows, State) ->
    {drop, State};
chosen(Command, _Windows, State) ->
    {drop, State#{mode := {choose, Command}}}.

%% The press that names the window a command acts on.
named(_Command, none, _Point, _Windows, State) ->
    {drop, State};
named(hide, Id, _Point, Windows, State) ->
    {ok, Window} = erx_wm:fetch(Id, Windows),
    {{windows, replace(Window#{state := hidden}, Windows)}, State};
named(delete, Id, _Point, _Windows, State) ->
    {{delete, Id}, State#{mode := spent}};
named(Gesture, Id, Point, _Windows, State) when Gesture =:= move; Gesture =:= resize ->
    {{wm, Gesture}, State#{pick := Id, mode := {Gesture, Id, Point}}}.

%% A move's or resize's release: the window raised, moved by the pointer's travel or
%% given the rectangle swept, when it is still shown and the result is good.
swept(Gesture, Id, From, To, Windows, Screen) ->
    case erx_wm:fetch(Id, Windows) of
        {ok, #{state := shown} = Window} ->
            {windows, raise(resized(Gesture, Window, From, To, Screen), Windows)};
        _ -> drop
    end.

resized(move, #{rect := {X0, Y0, _, _}} = Window, {FX, FY}, {TX, TY}, Screen) ->
    case moved(Window, {X0 + TX - FX, Y0 + TY - FY}, Screen) of
        {ok, Rect} -> Window#{rect := Rect};
        error -> Window
    end;
resized(resize, Window, {FX, FY}, {TX, TY}, Screen) ->
    Rect = {min(FX, TX), min(FY, TY), max(FX, TX) + 1, max(FY, TY) + 1},
    case good_rect(Rect, Screen) of
        true -> Window#{rect := Rect};
        false -> Window
    end.

raised(Id, Windows) ->
    {ok, Window} = erx_wm:fetch(Id, Windows),
    raise(Window, Windows).

%% The item released over; a release where the menu was pressed chooses nothing, so a
%% right click that does not travel arms no command.
item(Press, Press, _Items) ->
    none;
item(_Press, Point, Items) ->
    case [Item || {Item, Rect} <- Items, contains(Rect, Point)] of
        [Item] -> Item;
        [] -> none
    end.

to_current(Input, Windows, State) ->
    case current(Windows, State) of
        none -> drop;
        Id -> {to, Id, Input}
    end.

to_under(Point, Input, Windows) ->
    case under(Point, Windows) of
        none -> drop;
        Id -> {to, Id, Input}
    end.

%% The topmost shown window whose rectangle holds the point.
under(Point, Windows) ->
    case [Id || #{id := Id, rect := Rect} <- erx_wm:shown(Windows), contains(Rect, Point)] of
        [Id | _] -> Id;
        [] -> none
    end.
