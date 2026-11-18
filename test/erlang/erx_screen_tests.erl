%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_screen over a stand-in driver on stock OTP, with erx_memdraw's NIF built for the
%% host (test/host/erx_screen_test.rb): the start fills the screen image with the
%% background and hands the driver one frame that covers it, no driver is no screen, a
%% driver that cannot flush part of the screen gets the whole of it, and a driver that
%% ends while it holds the frame leaves the screen to its supervisor. This module is
%% also the stand-in driver's callback module, as erx_screen calls one: info/1. Its
%% process answers a frame only as erx_display:flush_request/3 sends it, so a screen that
%% sends the driver a frame of another shape shows nothing.

-module(erx_screen_tests).
-include_lib("eunit/include/eunit.hrl").

-export([info/1]).

%% Plan 9's XRGB32, the virtio-gpu driver's channel: CHAN4(CIgnore, 8, CRed, 8, CGreen, 8,
%% CBlue, 8), CIgnore's type 6.
-define(XRGB32, 16#68081828).
-define(WIDTH, 8).
-define(HEIGHT, 4).
-define(DRIVER, erx_screen_test_driver).

%% The stand-in's info, as erx_display's info/1 callback answers it.
info(Driver) ->
    gen_server:call(Driver, info).

%% A driver registered as ?DRIVER over a screen image of its own, which tells the test
%% each flush it is handed and answers it as Flush says: ok, or by ending.
driver(Partial, Flush) ->
    driver(Partial, Flush, {?WIDTH, ?HEIGHT}).

driver(Partial, Flush, {Width, Height}) ->
    Test = self(),
    {ok, Screen} = erx_memdraw:alloc(?XRGB32, {0, 0, Width, Height}, {0, 0, Width, Height}, false, 16#000000ff),
    Info = #{width => Width, height => Height, chan => <<"x8r8g8b8">>, screen => Screen,
             partial => Partial, direct => false},
    Pid = spawn(fun() -> serve(Test, Info, Flush) end),
    true = register(?DRIVER, Pid),
    {Pid, Screen}.

serve(Test, Info, Flush) ->
    receive
        {'$gen_call', From, info} ->
            gen_server:reply(From, Info),
            serve(Test, Info, Flush);
        {'$gen_call', From, {flush, Rects, Image}} ->
            Test ! {flushed, Rects, Image},
            case Flush of
                ok -> gen_server:reply(From, ok), serve(Test, Info, Flush);
                exit -> exit(device)
            end
    end.

start() ->
    erx_screen:start_link({?MODULE, ?DRIVER}, light).

stop(Pid) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> ok end.

flushed() ->
    receive {flushed, Rects, Image} -> {Rects, Image} after 5000 -> error(no_flush) end.

area({X0, Y0, X1, Y1}) -> (X1 - X0) * (Y1 - Y0).

%% The background as x8r8g8b8 lays a pixel out: blue, green and red, little-endian, then
%% the ignored byte.
background_pixel() ->
    <<R, G, B, _A>> = <<(erx_theme:color(light, desktop)):32>>,
    {B, G, R}.

start_fills_the_screen_with_the_background_and_flushes_it_once_test() ->
    {Driver, Screen} = driver(true, ok),
    {ok, Pid} = start(),
    {Rects, Image} = flushed(),
    ?assertEqual(Screen, Image),
    ?assertEqual(?WIDTH * ?HEIGHT, lists:sum([area(R) || R <- Rects])),
    ?assert(lists:all(fun({X0, Y0, X1, Y1}) -> X0 >= 0 andalso Y0 >= 0 andalso X1 =< ?WIDTH andalso Y1 =< ?HEIGHT end,
                      Rects)),
    {ok, Pixels} = erx_memdraw:read(Screen, {0, 0, ?WIDTH, ?HEIGHT}),
    Expected = background_pixel(),
    ?assertEqual(lists:duplicate(?WIDTH * ?HEIGHT, Expected), [{B, G, R} || <<B, G, R, _>> <= Pixels]),
    receive {flushed, _, _} -> error(second_frame) after 200 -> ok end,
    stop(Pid),
    kill(Driver).

no_driver_is_no_screen_test() ->
    ?assertEqual(ignore, start()).

a_driver_without_partial_flushes_gets_the_whole_screen_test() ->
    {Driver, _Screen} = driver(false, ok),
    {ok, Pid} = start(),
    ?assertMatch({[{0, 0, ?WIDTH, ?HEIGHT}], _}, flushed()),
    stop(Pid),
    kill(Driver).

%% Kills the stand-in driver and waits for its end, so its registered name is free.
kill(Driver) ->
    Ref = monitor(process, Driver),
    exit(Driver, kill),
    receive {'DOWN', Ref, process, Driver, _} -> ok end.

a_driver_ending_with_the_frame_leaves_the_screen_running_test() ->
    {_Driver, _Screen} = driver(true, exit),
    {ok, Pid} = start(),
    _ = flushed(),
    timer:sleep(100),
    ?assert(is_process_alive(Pid)),
    stop(Pid).

%% The splash (docs/design-display.md, "The splash").

pixels(Screen, {W, H}) ->
    {ok, Pixels} = erx_memdraw:read(Screen, {0, 0, W, H}),
    [{B, G, R} || <<B, G, R, _>> <= Pixels].

the_splash_shows_until_a_window_is_shown_and_none_of_it_stays_test() ->
    Size = {640, 400},
    {Driver, Screen} = driver(true, ok, Size),
    {ok, Pid} = start(),
    _ = flushed(),
    Ground = background_pixel(),
    {Marked, _} = lists:partition(fun(P) -> P =/= Ground end, pixels(Screen, Size)),
    %% The mark's ink and the dots: a few thousand pixels, centred, the rest the ground.
    ?assert(length(Marked) > 1000),
    ?assertEqual(Ground, hd(pixels(Screen, Size))),
    %% A layout with no window keeps the splash.
    gen_server:cast(erx_screen, {layout, []}),
    receive {flushed, _, _} -> error(empty_layout_flushed) after 200 -> ok end,
    ?assertEqual(length(Marked), length([P || P <- pixels(Screen, Size), P =/= Ground])),
    %% The first window, small and in a corner, repaints the whole screen.
    gen_server:cast(erx_screen, {layout, [#{id => 1, proc => self(), rect => {0, 0, 16, 16}, decorations => []}]}),
    receive {erx_screen, present_again} -> ok after 5000 -> error(no_present_again) end,
    _ = flushed(),
    ?assertEqual([], [P || P <- pixels(Screen, Size), P =/= Ground]),
    stop(Pid),
    kill(Driver).

the_splash_plan_is_centred_and_within_the_screen_test_() ->
    Mark = {384, 135, binary:copy(<<255>>, 384 * 135)},
    [?_test(begin
                [{{X, Y}, {W, H, _}, Text} | Dots] = erx_splash:plan(Rect, dark, Mark),
                ?assertEqual(erx_theme:color(dark, text), Text),
                ?assertEqual((SX1 - W) div 2, X),
                ?assert(Y > 0 andalso Y + H < SY1 div 2 + H),
                ?assertEqual(3, length(Dots)),
                ?assert(lists:all(fun({{DX, DY}, {DW, DH, _}, C}) ->
                                          C =:= erx_theme:color(dark, secondary) andalso DX >= 0 andalso
                                              DX + DW =< SX1 andalso DY + DH =< SY1 andalso DY > Y + H
                                  end, Dots))
            end) || {_, _, SX1, SY1} = Rect <- [{0, 0, 1920, 1080}, {0, 0, 1280, 800}]].

a_screen_too_small_for_the_splash_shows_the_background_alone_test() ->
    ?assertEqual([], erx_splash:plan({0, 0, 320, 240}, light, {384, 135, binary:copy(<<255>>, 384 * 135)})).
