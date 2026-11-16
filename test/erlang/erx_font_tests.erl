%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% erx_font, the reader of Plan 9 subfont files (docs/design-display.md,
%% "Erlang clients"), run by test/host/erx_font_test.rb on stock's emulator
%% in a directory that holds the subfonts of display/font/fixed: the shipped
%% subfonts parse and load into a draw connection, the file's two pixel
%% forms read alike, and each malformed file is refused for its reason.
-module(erx_font_tests).
-include_lib("eunit/include/eunit.hrl").
-export([small/0, file/3]).

-define(K1, 16#31).
-define(K8, 16#38).
-define(ARGB32, 16#48081828).

%% A two-glyph subfont, 16 by 2 at one bit a pixel: glyph 0 is columns 0
%% to 8, glyph 1 columns 8 to 16 placed one pixel left of the pen.
small() ->
    #{chan => <<"k1">>, w => 16, pixels => <<16#F0, 16#0F, 16#AA, 16#55>>, height => 2, ascent => 1,
      entries => [{0, 0, 2, 0, 8}, {8, 0, 2, -1, 8}, {16, 0, 0, 0, 0}]}.

%% A subfont file of Spec, its pixels as rows, as one compressed block, or
%% as one compressed block per row. Text replaces the value of any of the
%% header fields chan, x0, w, h, n, height and ascent with other text or number.
file(Spec, Form, Text) ->
    #{chan := Chan, w := W, pixels := Pixels, height := Height, ascent := Ascent, entries := Entries} = Spec,
    Line = line(Spec),
    H = byte_size(Pixels) div Line,
    Field = fun(Name, Value) -> field(maps:get(Name, Text, Value)) end,
    Header = [Field(chan, Chan), Field(x0, 0), field(0), Field(w, W), Field(h, H)],
    Table = << <<X:16/little, Top, Bottom, Left:8/signed, Width>> || {X, Top, Bottom, Left, Width} <- Entries >>,
    iolist_to_binary([image(Form, Header, Pixels, W, H, Line),
                      Field(n, length(Entries) - 1), Field(height, Height), Field(ascent, Ascent), Table]).

image(rows, Header, Pixels, _W, _H, _Line) ->
    [Header, Pixels];
image(compressed, Header, Pixels, W, H, _Line) ->
    ["compressed\n", Header, block(H, erx_draw_image:encode(Pixels, {0, 0, W, H}))];
image(per_row, Header, Pixels, W, _H, Line) ->
    Rows = [Row || <<Row:Line/binary>> <= Pixels],
    ["compressed\n", Header,
     [block(Y + 1, erx_draw_image:encode(Row, {0, Y, W, Y + 1})) || {Y, Row} <- lists:enumerate(0, Rows)]].

block(MaxY, Codes) -> [field(MaxY), field(byte_size(Codes)), Codes].

line(#{chan := Chan, w := W}) ->
    {ok, _, Depth} = erx_chan:parse(Chan),
    erx_draw_image:bytes_per_line({0, 0, W, 1}, Depth).

field(Value) when is_integer(Value) -> field(integer_to_binary(Value));
field(Text) -> iolist_to_binary(io_lib:format("~11s ", [Text])).

parsed(Spec, Form) ->
    {ok, Subfont} = erx_font:parse(file(Spec, Form, #{})),
    Subfont.

refused(Spec) -> refused(Spec, #{}).

refused(Spec, Text) -> erx_font:parse(file(Spec, rows, Text)).

%% The shipped subfonts: 6 by 13 cells, ascent 10, Latin-1's 256 glyphs,
%% the punctuation block's 235 and the box drawing block's 256, the last
%% ending at the image's right edge.
shipped_test_() ->
    [?_test(begin
                {ok, Bytes} = file:read_file(Name),
                {ok, #{chan := ?K1, r := {0, 0, W, 13}, height := 13, ascent := 10, glyphs := Glyphs}} =
                    erx_font:parse(Bytes),
                ?assertEqual({N, W}, {length(Glyphs), element(2, lists:last(Glyphs))}),
                ?assertEqual([6], lists:usort([X1 - X0 || {X0, X1, _, _, _, Width} <- Glyphs, Width > 0]))
            end)
     || {Name, N} <- [{"6x13.0000", 256}, {"6x13.2000", 235}, {"6x13.2500", 256}]].

%% A shipped subfont loads into a new connection message by message, and
%% text drawn from it is one draw per glyph, masked by the glyph's columns
%% and rows of the font cache.
shipped_load_test() ->
    {ok, Bytes} = file:read_file("6x13.0000"),
    {ok, #{glyphs := Glyphs} = Subfont} = erx_font:parse(Bytes),
    [{OX, _, OTop, _, _, _}, {KX, _, KTop, _, _, _}] = [lists:nth(C + 1, Glyphs) || C <- [$o, $k]],
    Connection = erx_draw_core:new(#{r => {0, 0, 640, 480}, chan => ?ARGB32,
                                     quota => #{pixels => 1024 * 1024, side => 16384}}),
    Colour = {alloc, 2, 0, 0, ?K8, 1, {0, 0, 1, 1}, {0, 0, 1, 1}, 0},
    Loaded = lists:foldl(fun(Message, State) ->
                                 {ok, Next, _} = erx_draw_core:step(State, Message),
                                 Next
                         end, Connection, erx_font:load(Subfont, 1) ++ [Colour]),
    {ok, _, Draws} = erx_draw_core:step(Loaded, {string, 0, 2, 1, {10, 20}, {0, 0, 640, 480}, {0, 0}, [$o, $k]}),
    ?assertMatch([{draw, 0, _, 2, _, 1, {OX, OTop}, _, _}, {draw, 0, _, 2, _, 1, {KX, KTop}, _, _}], Draws).

%% Rows, one compressed block and a block per row read as the same subfont.
forms_test() ->
    Expected = #{chan => ?K1, r => {0, 0, 16, 2}, pixels => <<16#F0, 16#0F, 16#AA, 16#55>>,
                 height => 2, ascent => 1, glyphs => [{0, 8, 0, 2, 0, 8}, {8, 16, 0, 2, -1, 8}]},
    ?assertEqual([Expected, Expected, Expected], [parsed(small(), Form) || Form <- [rows, compressed, per_row]]).

%% load/2 for the small subfont: the image, its one band, the cache and a
%% record per glyph copied from the image itself, left as its byte.
load_test() ->
    ?assertEqual([{alloc, 7, 0, 0, ?K1, 0, {0, 0, 16, 2}, {0, 0, 16, 2}, 0},
                  {load, 7, {0, 0, 16, 2}, <<16#F0, 16#0F, 16#AA, 16#55>>},
                  {font, 7, 2, 1},
                  {glyph, 7, 7, 0, {0, 0, 8, 2}, {0, 0}, 0, 8},
                  {glyph, 7, 7, 1, {8, 0, 16, 2}, {8, 0}, 255, 8}],
                 erx_font:load(parsed(small(), rows), 7)).

%% Pixels over 8192 bytes load in bands of whole rows: at 4096 bytes a row,
%% two rows a band.
bands_test() ->
    Pixels = << <<(Y * 16 + X rem 16)>> || Y <- lists:seq(0, 4), X <- lists:seq(0, 4095) >>,
    Spec = #{chan => <<"k8">>, w => 4096, pixels => Pixels, height => 5, ascent => 4,
             entries => [{0, 0, 5, 0, 8}, {8, 0, 0, 0, 0}]},
    Loads = [{R, P} || {load, 1, R, P} <- erx_font:load(parsed(Spec, compressed), 1)],
    ?assertEqual([{0, 0, 4096, 2}, {0, 2, 4096, 4}, {0, 4, 4096, 5}], [R || {R, _} <- Loads]),
    ?assertEqual(Pixels, iolist_to_binary([P || {_, P} <- Loads])).

%% Every proper prefix of a file is refused, in both forms, and so is a byte
%% after the table.
truncated_test_() ->
    [?_assertMatch({error, _}, erx_font:parse(binary:part(Bytes, 0, Size)))
     || Form <- [rows, compressed], Bytes <- [file(small(), Form, #{})], Size <- lists:seq(0, byte_size(Bytes) - 1)].

trailing_test() ->
    ?assertEqual({error, trailing}, erx_font:parse(<<(file(small(), rows, #{}))/binary, 0>>)).

header_test_() ->
    Small = small(),
    [?_assertEqual({error, header}, refused(Small, #{chan => <<"q1">>})),
     ?_assertEqual({error, header}, refused(Small, #{chan => <<"0">>})),
     ?_assertEqual({error, header}, refused(Small, #{w => <<"16x">>})),
     ?_assertEqual({error, header}, refused(Small, #{w => <<"1 6">>})),
     ?_assertEqual({error, header}, refused(Small, #{w => <<"">>})),
     ?_assertEqual({error, header}, refused(Small, #{x0 => 1})),
     ?_assertEqual({error, header}, refused(Small, #{w => 0})),
     ?_assertEqual({error, header}, refused(Small, #{h => 0})),
     ?_assertEqual({error, header}, refused(Small, #{w => 16#10000})),
     ?_assertEqual({error, header}, refused(Small, #{h => 256})),
     ?_assertEqual({error, header}, refused(Small, #{height => <<"two">>}))].

%% A row of more than 8192 bytes loads in tiles of columns whose rows hold
%% at most 8192 bytes, each tile in bands of rows: at 8 bits a pixel, tiles
%% of 8192 columns, and at 24, tiles of 2730 columns, 8190 bytes a row.
%% Each `y` lies inside the image of a draw connection, and the tiles put
%% every pixel back where the file has it.
tiles_test() ->
    Wide = [{0, 0, 8192, 1}, {0, 1, 8192, 2}, {0, 2, 8192, 3},
            {8192, 0, 16384, 1}, {8192, 1, 16384, 2}, {8192, 2, 16384, 3},
            {16384, 0, 20000, 2}, {16384, 2, 20000, 3}],
    Deep = [{0, 0, 2730, 1}, {0, 1, 2730, 2}, {0, 2, 2730, 3},
            {2730, 0, 5460, 1}, {2730, 1, 5460, 2}, {2730, 2, 5460, 3},
            {5460, 0, 6000, 3}],
    ?assertEqual(Wide, tiles(<<"k8">>, 20000, 3)),
    ?assertEqual(Deep, tiles(<<"r8g8b8">>, 6000, 3)).

%% The rectangles of the `y`s that load a W by H subfont of channel Chan,
%% once each has stepped through a draw connection and their pixels, put
%% back at their rectangles, have made the file's image again.
tiles(Chan, W, H) ->
    Spec = #{chan => Chan, w => W, pixels => <<>>, height => H, ascent => 1,
             entries => [{0, 0, H, 0, 8}, {W, 0, 0, 0, 0}]},
    Line = line(Spec),
    Pixels = << <<(I rem 251 + 1)>> || I <- lists:seq(0, Line * H - 1) >>,
    Messages = erx_font:load(parsed(Spec#{pixels := Pixels}, rows), 1),
    Connection = erx_draw_core:new(#{r => {0, 0, 640, 480}, chan => ?ARGB32,
                                     quota => #{pixels => 1024 * 1024, side => 32768}}),
    lists:foldl(fun(Message, State) ->
                        {ok, Next, _} = erx_draw_core:step(State, Message),
                        Next
                end, Connection, Messages),
    Loads = [{R, P} || {load, 1, R, P} <- Messages],
    {ok, _, Depth} = erx_chan:parse(Chan),
    ?assertEqual(Pixels, lists:foldl(fun({R, P}, Image) -> put_rect(Image, Line, Depth, R, P) end,
                                     <<0:(Line * H)/unit:8>>, Loads)),
    [R || {R, _} <- Loads].

%% Image, whose rows are Line bytes each, with the rows of Pixels in place
%% at rectangle R, whose columns start and end on a byte.
put_rect(Image, Line, Depth, {X0, Y0, X1, Y1}, Pixels) ->
    Bytes = (X1 - X0) * Depth div 8,
    Rows = [Row || <<Row:Bytes/binary>> <= Pixels],
    ?assertEqual(Y1 - Y0, length(Rows)),
    lists:foldl(fun({Y, Row}, Acc) ->
                        At = Y * Line + X0 * Depth div 8,
                        <<Before:At/binary, _:Bytes/binary, After/binary>> = Acc,
                        <<Before/binary, Row/binary, After/binary>>
                end, Image, lists:zip(lists:seq(Y0, Y1 - 1), Rows)).

%% Compressed blocks that overrun the last row, end at or before the row
%% they start on, are empty, hold codes short of their rows or past them,
%% or stop before the last row.
blocks_test_() ->
    Header = ["compressed\n", field(<<"k1">>), field(0), field(0), field(16), field(2)],
    Codes = erx_draw_image:encode(<<16#F0, 16#0F, 16#AA, 16#55>>, {0, 0, 16, 2}),
    Size = byte_size(Codes),
    Subfont = [field(2), field(2), field(1), <<0:(3 * 48)>>],
    Refused = fun(Blocks) -> erx_font:parse(iolist_to_binary([Header, Blocks, Subfont])) end,
    [?_assertEqual({error, pixels}, Refused([field(3), field(Size), Codes])),
     ?_assertEqual({error, pixels}, Refused([field(0), field(Size), Codes])),
     ?_assertEqual({error, pixels}, Refused([field(2), field(0)])),
     ?_assertEqual({error, pixels}, Refused([field(2), field(Size - 1), binary:part(Codes, 0, Size - 1)])),
     ?_assertEqual({error, pixels}, Refused([field(2), field(Size + 1), Codes, 0])),
     ?_assertEqual({error, pixels}, Refused([field(1), field(Size), Codes]))].

%% As libdraw's loadchar does, rows past the image are clamped to it,
%% bottom first, and an ascent above the height is kept.
clamped_test() ->
    Small = small(),
    #{ascent := 9, glyphs := Glyphs} =
        parsed(Small#{ascent := 9, entries := [{0, 1, 3, 0, 8}, {8, 216, 208, 0, 0}, {16, 0, 0, 0, 0}]}, rows),
    ?assertEqual([{0, 8, 1, 2, 0, 8}, {8, 16, 2, 2, 0, 0}], Glyphs).

glyphs_test_() ->
    Small = small(),
    [?_assertEqual({error, glyphs}, refused(Small#{entries := [{0, 0, 0, 0, 0}]})),
     ?_assertEqual({error, glyphs}, refused(Small, #{n => erx_draw_core:max_glyphs() + 1})),
     ?_assertEqual({error, glyphs}, refused(Small, #{ascent => -1})),
     ?_assertEqual({error, glyphs}, refused(Small, #{ascent => 256})),
     ?_assertEqual({error, glyphs}, refused(Small, #{height => -1})),
     ?_assertEqual({error, glyphs}, refused(Small#{entries := [{8, 0, 2, 0, 8}, {0, 0, 2, 0, 8}, {16, 0, 0, 0, 0}]})),
     ?_assertEqual({error, glyphs}, refused(Small#{entries := [{0, 0, 2, 0, 8}, {8, 0, 2, 0, 8}, {17, 0, 0, 0, 0}]})),
     ?_assertEqual({error, glyphs}, refused(Small, #{n => 3}))].
