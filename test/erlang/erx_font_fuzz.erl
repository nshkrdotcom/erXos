%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random files through erx_font:parse/1, the reader of Plan 9 subfont
%% files, which are untrusted. Whatever arrives, it returns `{ok, Subfont}`
%% or `{error, Reason}` for a reason of its closed set and never raises. A
%% file it accepts holds what the design says a subfont holds (pixels of
%% exactly its rectangle, glyphs inside the image, an ascent that fits a
%% byte) and loads whole: every message load/2 makes encodes, and once a
%% connection whose quota holds it accepts the image's `b`, which it must
%% for a well-formed file, erx_draw_core accepts every message after it. A
%% byte added after an accepted file is refused, as is a random prefix of
%% it. The
%% inputs are random bytes, well-formed subfonts of random channels, sizes,
%% glyphs and pixel forms, which must parse to the subfont they were made
%% from, those with a byte changed, inserted or removed, and the shipped
%% subfonts in the current directory with a byte changed. The seed comes
%% from make check-fuzz.

-module(erx_font_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(REASONS, [header, pixels, glyphs, trailing]).
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
            {error, trailing} = erx_font:parse(<<Bytes/binary, (rand:uniform(256) - 1)>>),
            {error, _} = erx_font:parse(binary:part(Bytes, 0, rand:uniform(byte_size(Bytes)) - 1));
        {error, Why} ->
            true = lists:member(Why, ?REASONS) orelse error({unknown_reason, Bytes, Why})
    end,
    Said.

holds(#{chan := Chan, r := {0, 0, W, H} = R, pixels := Pixels, height := Height, ascent := Ascent,
        glyphs := Glyphs} = Subfont, Bytes) ->
    {ok, Depth} = erx_chan:depth(Chan),
    Inside = fun({X0, X1, Top, Bottom, _, _}) -> X0 =< X1 andalso X1 =< W andalso Top =< Bottom andalso Bottom =< H end,
    case W >= 1 andalso W =< 16#ffff andalso H >= 1 andalso H =< 255 andalso byte_size(Pixels) =:= erx_draw_image:bytes_per_line(R, Depth) * H
        andalso Ascent >= 0 andalso Ascent =< 255 andalso Height >= 0
        andalso length(Glyphs) >= 1 andalso length(Glyphs) =< erx_draw_core:max_glyphs()
        andalso lists:all(Inside, Glyphs) of
        true -> ok;
        false -> error({breaks_invariant, Bytes, Subfont})
    end.

%% Every message encodes, and a connection that accepts the image's
%% allocation accepts all the rest.
loads(Subfont, Bytes, Admit) ->
    Connection = erx_draw_core:new(#{r => {0, 0, 64, 64}, chan => ?ARGB32,
                                     quota => #{pixels => 64 * 1024 * 1024, side => 1 bsl 20}}),
    [Alloc | Rest] = Messages = erx_font:load(Subfont, 1),
    lists:foreach(fun(Message) -> encodes(Message, Bytes) end, Messages),
    case {erx_draw_core:step(Connection, Alloc), Admit} of
        {{ok, Allocated, _}, _} ->
            lists:foldl(fun(Message, State) ->
                                case erx_draw_core:step(State, Message) of
                                    {ok, Next, _} -> Next;
                                    {error, Errno} -> error({load_refused, Bytes, Message, Errno})
                                end
                        end, Allocated, Rest);
        {{error, _}, may} ->
            ok;
        {{error, Errno}, must} ->
            error({load_refused, Bytes, Alloc, Errno})
    end.

encodes(Message, Bytes) ->
    try erx_draw_codec:encode(Message)
    catch Class:Reason -> error({unencodable, Bytes, Message, Class, Reason})
    end.

%% A well-formed subfont parses to what it was made of.
agrees(#{chan := Text, w := W, pixels := Pixels, height := Height, ascent := Ascent, entries := Entries}, Parsed,
       File) ->
    {ok, Chan, _} = erx_chan:parse(Text),
    Glyphs = lists:zipwith(fun({X0, Top, Bottom, Left, Width}, {X1, _, _, _, _}) -> {X0, X1, Top, Bottom, Left, Width} end,
                           lists:droplast(Entries), tl(Entries)),
    H = byte_size(Pixels) div erx_draw_image:bytes_per_line({0, 0, W, 1}, depth(Text)),
    Expected = #{chan => Chan, r => {0, 0, W, H}, pixels => Pixels, height => Height, ascent => Ascent,
                 glyphs => Glyphs},
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
    Spec = #{chan => Text, w => W, pixels => Pixels, height => Height, ascent => Ascent, entries => Entries},
    Form = lists:nth(rand:uniform(3), [rows, compressed, per_row]),
    {Spec, erx_font_tests:file(Spec, Form, #{})}.

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
