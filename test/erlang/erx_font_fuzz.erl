%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random files through erx_font:parse/1, the reader of Plan 9 subfont
%% files, which are untrusted. Whatever arrives, it returns `{ok, Subfont}`
%% or `{error, Reason}` for a reason of its closed set and never raises. A
%% file it accepts holds what the design says a subfont holds (pixels of
%% exactly its rectangle, glyphs inside the image, an ascent that fits a
%% byte) and loads whole: every message load/2 makes encodes, and once a
%% connection whose quota holds it accepts the image's `b`, which it must
%% for a well-formed file, erx_draw_core accepts every message after it. Its
%% pairs (docs/design-desktop-programs.md, "Kerning") ascend, name drawn
%% glyphs and keep every kerned advance in 0 to 255. A byte added after an
%% accepted file is refused, with kern when it has pairs and trailing when it
%% has none, and so is a random prefix of it, except that a file with pairs
%% cut exactly at the end of its glyph table is the same subfont without
%% them. The inputs are random bytes, well-formed subfonts of random
%% channels, sizes, glyphs, pixel forms and, one in four, pairs, which must
%% parse to the subfont they were made
%% from, those with a byte changed, inserted or removed, and the shipped
%% subfonts in the current directory with a byte changed. The seed comes
%% from make check-fuzz.

-module(erx_font_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(REASONS, [header, pixels, glyphs, trailing, kern]).
%% A pair section's two fields, the word kern and the count.
-define(SECTION_FIELDS, 24).
-define(ARGB32, 16#48081828).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Shipped = [Bytes || Name <- filelib:wildcard("6x13.*"), {ok, Bytes} <- [file:read_file(Name)]],
    3 = length(Shipped),
    lists:foreach(fun(_) ->
                          {Spec, File} = well_formed(),
                          {ok, Parsed} = round_of(File, must),
                          agrees(Spec, Parsed, File),
                          round_of(rand:bytes(rand:uniform(200)), may),
                          round_of(mutated(File), may),
                          round_of(changed(lists:nth(rand:uniform(3), Shipped)), may)
                  end, lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~p rounds ok~n", [?ROUNDS]).

%% One parse, which must not raise, must answer a known reason, and when it
%% accepts must keep the invariants; Admit says whether the connection
%% must admit its image.
round_of(Bytes, Admit) ->
    Said = try erx_font:parse(Bytes)
           catch Class:Reason:Stack -> error({raised, Bytes, Class, Reason, Stack})
           end,
    case Said of
        {ok, Subfont} ->
            holds(Subfont, Bytes),
            loads(Subfont, Bytes, Admit),
            neighbours(Subfont, Bytes);
        {error, Why} ->
            true = lists:member(Why, ?REASONS) orelse error({unknown_reason, Bytes, Why})
    end,
    Said.

%% A byte appended to an accepted file is refused, with kern after a pair
%% section and trailing after a glyph table; every proper prefix is refused,
%% except the one that ends at the glyph table of a file with pairs, which is
%% the same subfont without them.
neighbours(#{pairs := <<>>}, Bytes) ->
    {error, trailing} = erx_font:parse(appended(Bytes)),
    prefix(Bytes, none);
neighbours(#{pairs := Pairs} = Subfont, Bytes) ->
    {error, kern} = erx_font:parse(appended(Bytes)),
    TableEnd = byte_size(Bytes) - ?SECTION_FIELDS - byte_size(Pairs),
    Unkerned = {ok, Subfont#{pairs := <<>>}},
    Unkerned = erx_font:parse(binary:part(Bytes, 0, TableEnd)),
    prefix(Bytes, TableEnd).

appended(Bytes) -> <<Bytes/binary, (rand:uniform(256) - 1)>>.

%% A random proper prefix of Bytes is refused, unless its size is Skip, the
%% end of the glyph table of a file with pairs, which neighbours/2 checks.
prefix(Bytes, Skip) ->
    Size = rand:uniform(byte_size(Bytes)) - 1,
    case {Size =:= Skip, erx_font:parse(binary:part(Bytes, 0, Size))} of
        {true, _} -> ok;
        {false, {error, _}} -> ok;
        {false, Said} -> error({prefix_accepted, Bytes, Size, Said})
    end.

holds(#{chan := Chan, r := {0, 0, W, H} = R, pixels := Pixels, height := Height, ascent := Ascent,
        glyphs := Glyphs, pairs := Pairs} = Subfont, Bytes) ->
    {ok, Depth} = erx_chan:depth(Chan),
    Inside = fun({X0, X1, Top, Bottom, _, _}) -> X0 =< X1 andalso X1 =< W andalso Top =< Bottom andalso Bottom =< H end,
    case W >= 1 andalso W =< 16#ffff andalso H >= 1 andalso H =< 255 andalso byte_size(Pixels) =:= erx_draw_image:bytes_per_line(R, Depth) * H
        andalso Ascent >= 0 andalso Ascent =< 255 andalso Height >= 0
        andalso length(Glyphs) >= 1 andalso length(Glyphs) =< erx_draw_core:max_glyphs()
        andalso lists:all(Inside, Glyphs) andalso kerned(Pairs, Glyphs) of
        true -> ok;
        false -> error({breaks_invariant, Bytes, Subfont})
    end.

%% The pairs, 5 bytes each, ascend strictly, name only glyphs of width
%% above 0, and keep every kerned advance in 0 to 255.
kerned(Pairs, Glyphs) ->
    Widths = list_to_tuple([Width || {_, _, _, _, _, Width} <- Glyphs]),
    Drawn = fun(Index) -> Index < tuple_size(Widths) andalso element(Index + 1, Widths) > 0 end,
    Entries = [{A, B, K} || <<A:16/little, B:16/little, K:8/signed>> <= Pairs],
    byte_size(Pairs) =:= 5 * length(Entries)
        andalso lists:all(fun({A, B, K}) -> Drawn(A) andalso Drawn(B) andalso K =/= 0
                                             andalso element(A + 1, Widths) + K >= 0
                                             andalso element(A + 1, Widths) + K =< 255
                          end, Entries)
        andalso ascending([{A, B} || {A, B, _} <- Entries]).

ascending([First, Second | Rest]) -> First < Second andalso ascending([Second | Rest]);
ascending(_) -> true.

%% Every message encodes, and a connection that accepts the image's
%% allocation accepts all the rest.
loads(Subfont, Bytes, Admit) ->
    Connection = erx_draw_core:new(#{r => {0, 0, 64, 64}, chan => ?ARGB32,
                                     quota => #{pixels => 64 * 1024 * 1024, side => 1 bsl 20}}),
    [Alloc | Rest] = Messages = erx_font:load(Subfont, 1),
    lists:foreach(fun(Message) -> encodes(Message, Bytes) end, Messages),
    %% A refusal is a step's one action.
    case {erx_draw_core:step(Connection, Alloc), Admit} of
        {{_, [{error, _}]}, may} ->
            ok;
        {{_, [{error, Errno}]}, must} ->
            error({load_refused, Bytes, Alloc, Errno});
        {{Allocated, _}, _} ->
            lists:foldl(fun(Message, State) ->
                                case erx_draw_core:step(State, Message) of
                                    {_, [{error, Errno}]} -> error({load_refused, Bytes, Message, Errno});
                                    {Next, _} -> Next
                                end
                        end, Allocated, Rest)
    end.

encodes(Message, Bytes) ->
    try erx_draw_codec:encode(Message)
    catch Class:Reason -> error({unencodable, Bytes, Message, Class, Reason})
    end.

%% A well-formed subfont parses to what it was made of.
agrees(#{chan := Text, w := W, pixels := Pixels, height := Height, ascent := Ascent, entries := Entries} = Spec, Parsed,
       File) ->
    {ok, Chan, _} = erx_chan:parse(Text),
    Glyphs = lists:zipwith(fun({X0, Top, Bottom, Left, Width}, {X1, _, _, _, _}) -> {X0, X1, Top, Bottom, Left, Width} end,
                           lists:droplast(Entries), tl(Entries)),
    H = byte_size(Pixels) div erx_draw_image:bytes_per_line({0, 0, W, 1}, depth(Text)),
    Pairs = erx_font_tests:entries(maps:get(pairs, Spec, [])),
    Expected = #{chan => Chan, r => {0, 0, W, H}, pixels => Pixels, height => Height, ascent => Ascent,
                 glyphs => Glyphs, pairs => Pairs},
    case Parsed =:= Expected of
        true -> ok;
        false -> error({misread, File, Parsed, Expected})
    end.

depth(Text) ->
    {ok, _, Depth} = erx_chan:parse(Text),
    Depth.

%% A subfont of a random channel, a random image up to 64 by 8, or one
%% round in 16 up to 10922 wide, past one tile of load/2 at 24 bits a pixel
%% and at 8 when over 8192, glyphs that split its columns at random with
%% random rows, and a random pixel form.
well_formed() ->
    Text = lists:nth(rand:uniform(5), [<<"k1">>, <<"k2">>, <<"k4">>, <<"k8">>, <<"r8g8b8">>]),
    W = case rand:uniform(16) of
            1 -> 2730 + rand:uniform(8192);
            _ -> rand:uniform(64)
        end,
    H = rand:uniform(8),
    Pixels = rand:bytes(erx_draw_image:bytes_per_line({0, 0, W, 1}, depth(Text)) * H),
    Height = H + rand:uniform(4) - 1,
    Ascent = rand:uniform(Height + 1) - 1,
    Cuts = lists:sort([rand:uniform(W + 1) - 1 || _ <- lists:seq(1, rand:uniform(6))]),
    Entries = [entry(X, H) || X <- [0 | Cuts]] ++ [{W, 0, 0, 0, 0}],
    Spec = #{chan => Text, w => W, pixels => Pixels, height => Height, ascent => Ascent, entries => Entries,
             pairs => pairs(Entries)},
    Form = lists:nth(rand:uniform(3), [rows, compressed, per_row]),
    {Spec, erx_font_tests:file(Spec, Form, #{})}.

%% One round in four, random pairs of the glyphs of width above 0, in
%% order, each with an adjustment not 0 that keeps the first glyph's kerned
%% advance in 0 to 255; otherwise none.
pairs(Entries) ->
    Drawn = [{Index, Width} || {Index, {_, _, _, _, Width}} <- lists:enumerate(0, lists:droplast(Entries)), Width > 0],
    case rand:uniform(4) =:= 1 andalso Drawn =/= [] of
        true ->
            Chosen = lists:usort([{lists:nth(rand:uniform(length(Drawn)), Drawn), lists:nth(rand:uniform(length(Drawn)), Drawn)}
                                  || _ <- lists:seq(1, rand:uniform(8))]),
            [{A, B, adjustment(Width)} || {{A, Width}, {B, _}} <- Chosen];
        false ->
            []
    end.

%% An adjustment in a signed byte, not 0, with Width plus it in 0 to 255;
%% Width is at least 1, so Low is below 0.
adjustment(Width) ->
    Low = max(-128, -Width),
    High = min(127, 255 - Width),
    case Low + rand:uniform(High - Low + 1) - 1 of
        0 -> Low;
        Adjustment -> Adjustment
    end.

entry(X, H) ->
    Top = rand:uniform(H + 1) - 1,
    {X, Top, Top + rand:uniform(H - Top + 1) - 1, rand:uniform(256) - 129, rand:uniform(256) - 1}.

mutated(Bytes) ->
    case rand:uniform(3) of
        1 -> changed(Bytes);
        2 -> inserted(Bytes);
        3 -> removed(Bytes)
    end.

changed(Bytes) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Before:At/binary, _, After/binary>> = Bytes,
    <<Before/binary, (rand:uniform(256) - 1), After/binary>>.

inserted(Bytes) ->
    At = rand:uniform(byte_size(Bytes) + 1) - 1,
    <<Before:At/binary, After/binary>> = Bytes,
    <<Before/binary, (rand:uniform(256) - 1), After/binary>>.

removed(Bytes) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Before:At/binary, _, After/binary>> = Bytes,
    <<Before/binary, After/binary>>.
