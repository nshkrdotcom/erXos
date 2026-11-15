%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% The glyph step's role subfonts (docs/design-desktop-programs.md, "Type"),
%% run by test/host/glyphs_test.rb on stock's emulator in a directory that
%% holds the ROLE.subfont files Erx::Glyphs wrote: each parses with
%% erx_font as an 8-bit grey subfont and loads into a new draw connection,
%% message by message.
-module(erx_glyph_subfonts_tests).
-include_lib("eunit/include/eunit.hrl").

-define(K8, 16#38).
-define(ARGB32, 16#48081828).

subfonts_test_() ->
    Names = filelib:wildcard("*.subfont"),
    [?_assertNotEqual([], Names) | [{Name, ?_test(loads(Name))} || Name <- Names]].

loads(Name) ->
    {ok, Bytes} = file:read_file(Name),
    {ok, #{chan := ?K8} = Subfont} = erx_font:parse(Bytes),
    Connection = erx_draw_core:new(#{r => {0, 0, 640, 480}, chan => ?ARGB32,
                                     quota => #{pixels => 4096 * 1024, side => 16384}}),
    lists:foldl(fun(Message, State) ->
                        {ok, Next, _} = erx_draw_core:step(State, Message),
                        Next
                end, Connection, erx_font:load(Subfont, 1)).
