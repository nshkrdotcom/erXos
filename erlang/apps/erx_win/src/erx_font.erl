%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_font).
-moduledoc """
Plan 9 subfont files, read and loaded into a font cache of a draw
connection (docs/design-display.md, "Erlang clients"). A subfont file is
untrusted: it comes from a release or from whoever wrote the file, so
`parse/1` checks all of it before `load/2` makes a message from it.

The file, as font(7) and image(7) lay it out, is an image, then a subfont
header and the glyph table:

* the image: optionally `compressed\n`, then five fields of 12 bytes, each
  one word padded with blanks (font(7) right-justifies it in 11 and adds
  a blank): the channel (`erx_chan:parse/1`) and the rectangle's minimum and maximum
  corners; then the pixels, either each row in turn or, compressed,
  blocks of rows, each two fields (the block's last row plus one and its
  byte count) and that many bytes of image(6)'s codes
  (`erx_draw_image:decode/3`), which must fill the block's rows exactly;
* the subfont header: three fields, the glyph count n, the height and the
  ascent;
* n+1 entries of 6 bytes: x (two bytes, low first), top, bottom, left (a
  signed byte) and width; glyph i covers columns x(i) to x(i+1) and rows
  top to bottom of the image, is placed left pixels right of the pen and
  advances it by width. The last entry gives only the end of glyph n-1;
* optionally, erXos's pair section (docs/design-desktop-programs.md,
  "Kerning"), which a stock Plan 9 reader never reads: two fields, the
  word `kern` and the pair count k, then k entries of 5 bytes, the first
  glyph's index and the second's (two bytes each, low first) and the
  adjustment of the first glyph's advance when the second follows it (a
  signed byte).

`parse/1` refuses what a load could not use as it stands: an image that
does not start at the origin, since a glyph's x and rows are offsets in
it, as libdraw's loadchar reads them; an image wider or taller than a
glyph's columns and rows can reach, x being two bytes and the rows one; an
old image whose first field is a depth rather than a channel; a glyph count
of none or more than a font cache
holds (`erx_draw_core:max_glyphs/0`); an ascent outside a byte, the field
`i` carries it in; a glyph whose columns leave the image or run backwards;
and bytes after the glyph table unless they are a pair section. A pair
section is refused whole, for any fault once its first field reads `kern`:
a count below 1 or not matched by exactly its entries, an index at or past
the glyph count, entries not strictly ascending by first index and then
second, an adjustment of 0, a pair naming a glyph of width 0, which a font
reader takes as missing, and a kerned advance outside 0 to 255, so the pen
never moves backward. A glyph's rows are clamped into the
image as loadchar clamps them, since real subfonts give empty glyphs rows
past it, and an ascent above the height is kept, as plan9port keeps it.
Every count
is matched against the bytes present, so nothing is allocated for bytes the
file does not hold, and decoding takes no more steps than the file has
bytes.

`load/2` turns a subfont into the messages that make one image of the
client's connection hold it: `b` allocates it, `y` loads its pixels, `i`
makes it a font cache and one `l` per glyph records the glyph, copying it
onto itself. Each `y` it makes carries at most 8192 bytes of pixels, so
the image is cut into tiles of columns whose rows hold at most that many
bytes each, and each tile into bands of rows: a subfont holds all its
glyphs side by side in one row of the image, which may be far wider than
that, and a `y` may load any rectangle inside the image (draw(3)).
The image is its own
cache, so a glyph's index is its index in the subfont and text in it is a
sequence of `s` messages.

`width/2` and `runs/2` place a line of glyph indices by the pairs, through
`erx_pen`: `runs/2` cuts the line where an adjustment is not 0, and each
run is one `s` message at its offset, so the draw server, which advances
each glyph by its width, never sees a pair. The pairs stay the file's
bytes and a pair is found by halving them, so a subfont costs its size.
""".

-export([parse/1, load/2, width/2, runs/2]).
-export_type([subfont/0, glyph/0, index/0, reason/0]).

%% A header field: a number or descriptor right-justified in 11, then a blank.
-define(FIELD, 12).
%% The most bytes of pixels one `y` of `load/2` carries.
-define(Y_BYTES, 8192).
%% A pair section's entry: two glyph indices and an adjustment.
-define(PAIR, 5).
%% The widest and tallest image whose columns and rows a glyph reaches:
%% its x is two bytes, its top and bottom one each.
-define(MAX_W, 16#ffff).
-define(MAX_H, 255).

-doc """
Glyph i of a subfont, in the shape of a font cache's record, since the
subfont's image is its cache: its columns and rows in the image, its
offset from the pen and its advance.
""".
-type glyph() :: erx_draw_core:glyph().

-doc "A glyph's index in its subfont, as a pair entry holds it.".
-type index() :: 0..16#ffff.

-doc """
A subfont as `parse/1` read it: its image's channel and rectangle, which
starts at the origin, the image's pixels row by row as a `y` message lays
them, the font's height and ascent, its glyphs in index order, and its pair
section's entries as the file holds them, ascending, empty for a file
without one.
""".
-type subfont() :: #{chan := erx_chan:code(),
                     r := {0, 0, pos_integer(), pos_integer()}, pixels := binary(),
                     height := non_neg_integer(), ascent := byte(), glyphs := [glyph(), ...],
                     pairs := binary()}.

-doc """
Why a file is refused: `header` for a missing or malformed field of the
image or subfont header, or an image not at the origin or larger than a
glyph reaches; `pixels` for
pixels short of the rectangle or codes that
do not fill a block; `glyphs` for a table short of n+1 entries, a glyph
count, height or ascent out of range, or a glyph's columns outside the
image or backwards;
`trailing` for bytes after the table that are not a pair section; and
`kern` for any fault of a pair section.
""".
-type reason() :: header | pixels | glyphs | trailing | kern.

-doc "The subfont in file `Bytes`, or why it is refused.".
-spec parse(binary()) -> {ok, subfont()} | {error, reason()}.
parse(Bytes) when is_binary(Bytes) ->
    try
        {Image, AfterImage} = image(Bytes),
        {[N, Height, Ascent], AfterHeader} = numbers(3, AfterImage),
        check(N >= 1 andalso N =< erx_draw_core:max_glyphs()
              andalso Ascent >= 0 andalso Ascent =< 255 andalso Height >= 0, glyphs),
        TableBytes = 6 * (N + 1),
        {Table, AfterTable} = case AfterHeader of
                                  <<T:TableBytes/binary, Rest/binary>> -> {T, Rest};
                                  _ -> throw(glyphs)
                              end,
        Glyphs = glyphs(Table, maps:get(r, Image)),
        Pairs = pairs(AfterTable, Glyphs),
        {ok, Image#{height => Height, ascent => Ascent, glyphs => Glyphs, pairs => Pairs}}
    catch
        throw:Reason -> {error, Reason}
    end.

-doc """
The width of a line of `Subfont`'s glyphs, by their advances and pairs.
Each index is below the subfont's glyph count, as the caller's mapping
from characters to glyphs gives it.
""".
-spec width(subfont(), [index()]) -> non_neg_integer().
width(Subfont, Line) ->
    {_Offsets, Width} = place(Subfont, Line),
    Width.

-doc """
A line of `Subfont`'s glyphs cut into runs, each with its pen offset from
the line's start: a run ends where the adjustment between two glyphs is
not 0, so within a run each glyph follows the last by its advance, as an
`s` message draws it. A line without pairs is one run. Each index is below
the subfont's glyph count.
""".
-spec runs(subfont(), [index()]) -> [{non_neg_integer(), [index(), ...]}].
runs(#{glyphs := Glyphs} = Subfont, Line) ->
    {Offsets, _Width} = place(Subfont, Line),
    cut(lists:zip(Line, Offsets), advance(Glyphs)).

%% Placed glyphs, each {Glyph, Offset}, cut into runs. The open run starts
%% at Start, holds Run in reverse and its advances end at End; the next
%% glyph joins it when it stands at End, which is when the adjustment
%% between it and the glyph before it is 0, and starts a run otherwise.
cut([], _Advance) ->
    [];
cut([{Glyph, X} | Placed], Advance) ->
    cut(Placed, Advance, X, [Glyph], X + Advance(Glyph)).

cut([], _Advance, Start, Run, _End) ->
    [{Start, lists:reverse(Run)}];
cut([{Glyph, X} | Placed], Advance, Start, Run, End) when X =:= End ->
    cut(Placed, Advance, Start, [Glyph | Run], X + Advance(Glyph));
cut([{Glyph, X} | Placed], Advance, Start, Run, _End) ->
    [{Start, lists:reverse(Run)} | cut(Placed, Advance, X, [Glyph], X + Advance(Glyph))].

%% Each glyph's pen offset and the line's width, by erx_pen.
place(#{glyphs := Glyphs, pairs := Pairs}, Line) ->
    erx_pen:place(Line, advance(Glyphs), fun(A, B) -> kern(Pairs, A, B) end).

%% A glyph's advance by its index.
advance(Glyphs) ->
    Widths = widths(Glyphs),
    fun(Index) -> element(Index + 1, Widths) end.

%% The glyphs' advances, element I + 1 glyph I's.
widths(Glyphs) -> list_to_tuple([Width || {_, _, _, _, _, Width} <- Glyphs]).

%% The adjustment of glyph A followed by glyph B: the pair's, found by
%% halving the ascending entries, or 0 when no entry names them.
kern(Pairs, A, B) ->
    kern(Pairs, {A, B}, 0, byte_size(Pairs) div ?PAIR).

kern(_Pairs, _Key, Low, Low) ->
    0;
kern(Pairs, Key, Low, High) ->
    Middle = (Low + High) div 2,
    Skip = Middle * ?PAIR,
    <<_:Skip/binary, First:16/little, Second:16/little, Adjustment:8/signed, _/binary>> = Pairs,
    if
        {First, Second} =:= Key -> Adjustment;
        {First, Second} < Key -> kern(Pairs, Key, Middle + 1, High);
        true -> kern(Pairs, Key, Low, Middle)
    end.

-doc """
The draw messages that make image `Id` of a connection hold `Subfont` as
a font cache: its allocation, its pixels, the cache and one glyph record
per glyph, for `erx_draw_codec` to encode.
""".
-spec load(subfont(), erx_draw_codec:image_id()) -> [erx_draw_codec:msg()].
load(#{chan := Chan, r := {0, 0, W, H} = R, pixels := Pixels, ascent := Ascent,
       glyphs := Glyphs}, Id) ->
    {ok, Depth} = erx_chan:depth(Chan),
    Line = erx_draw_image:bytes_per_line(R, Depth),
    Loads = [load_rect(Id, Pixels, Line, Depth, Rect) || Rect <- tiles(W, H, Depth)],
    Records = [{glyph, Id, Id, Index, {X0, Top, X1, Bottom}, {X0, Top}, Left band 16#ff, Width}
               || {Index, {X0, X1, Top, Bottom, Left, Width}} <- lists:enumerate(0, Glyphs)],
    [{alloc, Id, 0, 0, Chan, 0, R, R, 0}]
        ++ Loads ++ [{font, Id, length(Glyphs), Ascent} | Records].

%% The rectangles of the `y`s that load a W by H image of depth Depth, each
%% of at most ?Y_BYTES bytes of pixels: tiles of as many columns as a row
%% of ?Y_BYTES bytes holds, left to right, each cut into bands of as many
%% rows as fit, top to bottom. A depth divides 8 or is a multiple of 8
%% (erx_chan:depth/1), so every tile starts on a byte of its rows and a
%% whole tile's row is at most ?Y_BYTES bytes.
tiles(W, H, Depth) ->
    Columns = ?Y_BYTES * 8 div Depth,
    lists:append([bands({X0, 0, min(X0 + Columns, W), H}, Depth) || X0 <- lists:seq(0, W - 1, Columns)]).

%% The bands of rows of a tile, columns X0 to X1 of all H rows.
bands({X0, 0, X1, H}, Depth) ->
    Rows = ?Y_BYTES div erx_draw_image:bytes_per_line({X0, 0, X1, 1}, Depth),
    [{X0, Y0, X1, min(Y0 + Rows, H)} || Y0 <- lists:seq(0, H - 1, Rows)].

%% The `y` of rectangle R of the image, from the bytes of each of its rows
%% that hold R's columns; the image's rows are Line bytes each.
load_rect(Id, Pixels, Line, Depth, {X0, Y0, _, Y1} = R) ->
    Start = X0 * Depth div 8,
    Bytes = erx_draw_image:bytes_per_line(R, Depth),
    {load, Id, R, << <<(binary:part(Pixels, Y * Line + Start, Bytes))/binary>> || Y <- lists:seq(Y0, Y1 - 1) >>}.

%% The image: its header, then its pixels as each row in turn.
image(<<"compressed\n", Bytes/binary>>) -> image(Bytes, compressed);
image(Bytes) -> image(Bytes, rows).

image(Bytes, Form) ->
    {Descriptor, AfterChan} = field(Bytes),
    {Chan, Depth} = case erx_chan:parse(Descriptor) of
                        {ok, C, D} -> {C, D};
                        {error, einval} -> throw(header)
                    end,
    {[X0, Y0, W, H], AfterRect} = numbers(4, AfterChan),
    check(X0 =:= 0 andalso Y0 =:= 0 andalso W >= 1 andalso W =< ?MAX_W andalso H >= 1 andalso H =< ?MAX_H,
          header),
    R = {0, 0, W, H},
    Line = erx_draw_image:bytes_per_line(R, Depth),
    {Pixels, Rest} = pixels(Form, AfterRect, R, Depth, Line),
    {#{chan => Chan, r => R, pixels => Pixels}, Rest}.

pixels(rows, Bytes, {0, 0, _, H}, _Depth, Line) ->
    Size = Line * H,
    case Bytes of
        <<Pixels:Size/binary, Rest/binary>> -> {Pixels, Rest};
        _ -> throw(pixels)
    end;
pixels(compressed, Bytes, R, Depth, _Line) ->
    blocks(Bytes, R, Depth, 0, []).

%% Each block's rows, from row MinY, until the blocks reach the last row.
blocks(Bytes, {0, 0, _, H}, _Depth, H, Done) ->
    {iolist_to_binary(lists:reverse(Done)), Bytes};
blocks(Bytes, {0, 0, W, H} = R, Depth, MinY, Done) ->
    {[MaxY, Count], AfterBlock} = numbers(2, Bytes),
    check(MaxY > MinY andalso MaxY =< H andalso Count >= 1, pixels),
    case AfterBlock of
        <<Codes:Count/binary, Rest/binary>> ->
            case erx_draw_image:decode(Codes, {0, MinY, W, MaxY}, Depth) of
                {ok, Rows, <<>>} -> blocks(Rest, R, Depth, MaxY, [Rows | Done]);
                _ -> throw(pixels)
            end;
        _ ->
            throw(pixels)
    end.

%% The glyphs of the table's n+1 entries, each from its entry to the next
%% one's x, whose columns must lie in the image in order. Its rows are
%% clamped into the image, bottom first, as libdraw's loadchar clamps
%% them, since real subfonts give empty glyphs rows past the image.
glyphs(Table, {0, 0, W, H}) ->
    Entries = [{X, Top, Bottom, Left, Width}
               || <<X:16/little, Top, Bottom, Left:8/signed, Width>> <= Table],
    Glyphs = lists:zipwith(fun({X0, Top, Bottom, Left, Width}, {X1, _, _, _, _}) ->
                                   Rows = min(Bottom, H),
                                   {X0, X1, min(Top, Rows), Rows, Left, Width}
                           end, lists:droplast(Entries), tl(Entries)),
    check(lists:all(fun({X0, X1, _, _, _, _}) -> X0 =< X1 andalso X1 =< W end, Glyphs), glyphs),
    Glyphs.

%% The pair section's entries, or none when the glyph table ends the file.
%% Bytes that do not start with a field reading `kern` are trailing; after
%% one, every fault is `kern`, the count's included, so the count is read
%% as digits alone rather than by the header's number reader. The count is
%% matched against the bytes before any entry is read.
pairs(<<>>, _Glyphs) ->
    <<>>;
pairs(<<Marker:?FIELD/binary, Section/binary>>, Glyphs) ->
    check(text(Marker, trailing) =:= <<"kern">>, trailing),
    {Count, Entries} = case Section of
                           <<CountField:?FIELD/binary, E/binary>> -> {digits(text(CountField, kern), kern), E};
                           _ -> throw(kern)
                       end,
    check(Count >= 1 andalso byte_size(Entries) =:= ?PAIR * Count, kern),
    check_entries(Entries, widths(Glyphs), {-1, -1}),
    %% A copy, so a subfont of a compressed file does not keep the file.
    binary:copy(Entries);
pairs(_Short, _Glyphs) ->
    throw(trailing).

%% Each entry names two glyphs of width above 0 (drawn_width/2), comes after
%% the one before it (Previous, which starts below every pair), adjusts by
%% other than 0 and keeps the first glyph's kerned advance in 0 to 255.
check_entries(<<>>, _Widths, _Previous) ->
    ok;
check_entries(<<A:16/little, B:16/little, Adjustment:8/signed, Rest/binary>>, Widths, Previous) ->
    Kerned = drawn_width(A, Widths) + Adjustment,
    drawn_width(B, Widths),
    check({A, B} > Previous, kern),
    check(Adjustment =/= 0 andalso Kerned >= 0 andalso Kerned =< 255, kern),
    check_entries(Rest, Widths, {A, B}).

%% The width of the glyph an entry names, which must be a glyph of the
%% subfont and of width above 0: the one bound on an entry's indices.
drawn_width(Index, Widths) when Index < tuple_size(Widths) ->
    Width = element(Index + 1, Widths),
    check(Width > 0, kern),
    Width;
drawn_width(_Index, _Widths) ->
    throw(kern).

%% Count numeric header fields.
numbers(Count, Bytes) ->
    lists:mapfoldl(fun(_, Rest) ->
                           {Text, After} = field(Rest),
                           {number(Text), After}
                   end, Bytes, lists:seq(1, Count)).

%% A header field's text and the bytes after it.
field(<<Field:?FIELD/binary, Rest/binary>>) -> {text(Field, header), Rest};
field(_) -> throw(header).

%% A field's text: one word, blank-padded within its 12 bytes, else Reason.
text(Field, Reason) ->
    case binary:split(Field, <<" ">>, [global, trim_all]) of
        [Text] -> Text;
        _ -> throw(Reason)
    end.

%% A header field's decimal number, optionally negative.
number(<<$-, Digits/binary>>) -> -digits(Digits, header);
number(Digits) -> digits(Digits, header).

%% The number a run of decimal digits spells, else Reason.
digits(Digits, Reason) ->
    case Digits =/= <<>> andalso << <<D>> || <<D>> <= Digits, D >= $0, D =< $9 >> =:= Digits of
        true -> binary_to_integer(Digits);
        false -> throw(Reason)
    end.

check(true, _Reason) -> ok;
check(false, Reason) -> throw(Reason).
