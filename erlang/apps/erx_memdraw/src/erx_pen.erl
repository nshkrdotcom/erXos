%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pen).
-moduledoc """
The pen rule of kerned text (docs/design-desktop-programs.md, "Kerning"),
its one implementation, which every reader of a font's pairs calls: the pen
moves from glyph A to the next glyph B by A's advance plus the pair's
adjustment, Kern(A, B), which is 0 where no pair names the two. Every
source of pairs guarantees a kerned advance in 0 to 255, `erx_font` by
checking the file and the window menu's module by being generated from a
checked subfont, so the pen never moves backward.

The module is pure and knows nothing of how glyphs are named: `erx_font`
passes a subfont's glyph indices, the window menu its characters.
""".

-export([place/3]).

-doc """
Each glyph's pen offset from the line's start, in the order of `Glyphs`,
and the line's width: the sum of the advances and of the adjustments
between neighbours.
""".
-spec place([Glyph], fun((Glyph) -> non_neg_integer()), fun((Glyph, Glyph) -> integer())) ->
          {[non_neg_integer()], non_neg_integer()}.
place(Glyphs, Advance, Kern) ->
    place(Glyphs, Advance, Kern, 0, []).

place([], _Advance, _Kern, X, Offsets) ->
    {lists:reverse(Offsets), X};
place([Last], Advance, _Kern, X, Offsets) ->
    {lists:reverse([X | Offsets]), X + Advance(Last)};
place([A | [B | _] = Rest], Advance, Kern, X, Offsets) ->
    place(Rest, Advance, Kern, X + Advance(A) + Kern(A, B), [X | Offsets]).
