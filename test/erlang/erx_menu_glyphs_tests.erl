%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% The window menu's glyph module (docs/design-desktop-programs.md, "Windows
%% and the window manager"), run by test/host/glyphs_test.rb on stock's
%% emulator with erx_memdraw's NIF built for the host, in a directory that
%% holds the erx_menu_glyphs module and the body.subfont Erx::Glyphs wrote
%% beside it: the pixels load into a k8 image with erx_memdraw:load/3 and
%% read back unchanged, and the module's image and glyphs are the subfont's.
-module(erx_menu_glyphs_tests).
-include_lib("eunit/include/eunit.hrl").

-define(K8, 16#38).
%% Every character a theme range may hold lies below this.
-define(CHARACTERS, 16#110000).

loads_with_erx_memdraw_test() ->
    {W, H} = erx_menu_glyphs:size(),
    R = {0, 0, W, H},
    {ok, Image} = erx_memdraw:alloc(?K8, R, R, false, 0),
    Pixels = erx_menu_glyphs:pixels(),
    ?assertEqual(W * H, byte_size(Pixels)),
    ?assertMatch({ok, _}, erx_memdraw:load(Image, R, Pixels)),
    ?assertEqual({ok, Pixels}, erx_memdraw:read(Image, R)).

is_the_subfont_test() ->
    {ok, Bytes} = file:read_file("body.subfont"),
    {ok, #{chan := ?K8, r := {0, 0, W, H}, pixels := Pixels, ascent := Ascent, glyphs := Glyphs}} =
        erx_font:parse(Bytes),
    ?assertEqual({W, H}, erx_menu_glyphs:size()),
    ?assertEqual(Ascent, erx_menu_glyphs:ascent()),
    ?assertEqual(Pixels, erx_menu_glyphs:pixels()),
    %% The subfont's glyphs a font reader takes, in column order, are the
    %% module's glyphs in column order.
    Present = [{MinX, MinY, MaxX, MaxY, Left, Width}
               || {MinX, MaxX, MinY, MaxY, Left, Width} <- Glyphs, Width > 0],
    Menu = lists:sort([{X0, Y0, X1, Y1, Left, Advance}
                       || C <- lists:seq(0, ?CHARACTERS - 1),
                          #{r := {X0, Y0, X1, Y1}, left := Left, advance := Advance} <- [erx_menu_glyphs:glyph(C)]]),
    ?assertNotEqual([], Menu),
    ?assertEqual(lists:sort(Present), Menu).
