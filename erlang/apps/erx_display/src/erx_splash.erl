%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_splash).
-moduledoc """
The splash (docs/design-display.md, "The splash"): what the screen draws
over its background from its start until its first layout that shows a
window. A pure function of the screen's rectangle, its palette and the
mark's mask: the erXos wordmark, erx_splash_mark's mask generated from
erxos-logo.svg, in the palette's `text` colour, centred across the screen
and a little above its middle, and below it three dots in `secondary`,
the quiet sign that the system is still starting.

The plan is a list of draws, each a colour drawn through an 8-bit
coverage mask, `{X, Y}` its top left corner on the screen. The draws
fit within the screen; on a screen too small to hold the whole splash,
the plan is empty and the screen shows the background alone, never a
clipped mark.
""".

-export([plan/3]).
-export_type([draw/0]).

%% The dots: their diameter, the gap between two, and the space between the
%% mark's bottom and their top, in pixels.
-define(DOT, 6).
-define(DOT_GAP, 10).
-define(DOT_SPACE, 48).
-define(DOTS, 3).

-type draw() :: {{integer(), integer()}, erx_mask:mask(), erx_screen_core:color()}.

-doc """
The splash's draws on screen rectangle `Screen` in `Palette`, with `Mark`
the wordmark's mask: the mark, then each dot from left to right.
""".
-spec plan(erx_screen_core:rect(), erx_theme:palette(), erx_mask:mask()) -> [draw()].
plan({X0, Y0, X1, Y1}, Palette, {MarkWidth, MarkHeight, _} = Mark) ->
    CentreX = (X0 + X1) div 2,
    Total = MarkHeight + ?DOT_SPACE + ?DOT,
    %% The whole sits with its middle at 45 percent of the height, where the
    %% eye takes a screen's centre to be.
    Top = Y0 + (Y1 - Y0) * 45 div 100 - Total div 2,
    Dot = erx_mask:stroke(?DOT, ?DOT, [{?DOT / 2, ?DOT / 2}], ?DOT),
    DotsWidth = ?DOTS * ?DOT + (?DOTS - 1) * ?DOT_GAP,
    DotsLeft = CentreX - DotsWidth div 2,
    DotsTop = Top + MarkHeight + ?DOT_SPACE,
    Secondary = erx_theme:color(Palette, secondary),
    Left = CentreX - MarkWidth div 2,
    case Left >= X0 andalso Left + MarkWidth =< X1 andalso Top >= Y0 andalso Top + Total =< Y1 of
        true ->
            [{{Left, Top}, Mark, erx_theme:color(Palette, text)}
             | [{{DotsLeft + I * (?DOT + ?DOT_GAP), DotsTop}, Dot, Secondary} || I <- lists:seq(0, ?DOTS - 1)]];
        false ->
            []
    end.
