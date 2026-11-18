%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dashboard_start_tests).
-moduledoc """
The dashboard's start on the SDK's stand-in display (erx_ui_host): its
window is drawn, the ground and dial included, whatever its quotes source
is doing. Here the source never gets going: public_key's `cacerts_path`
names `roots.fifo` in the working directory, a FIFO the test's caller
made and no one writes, so reading the trust store never returns and
holds the node's file server with it, which the stand-in display does
not use for its frames (seeded failure: a dashboard that waits for its
source's start shows nothing).

The ground is drawn once the window's top-left pixel is the ground's own
there, read from erx_dashboard_pictures:ground/1's PNG: the renderer
centres the 1920x1080 ground in the window and clips it, and no other
part of the screen reaches that corner.
""".

-include_lib("eunit/include/eunit.hrl").

-define(WIDTH, 1280).
-define(HEIGHT, 800).
-define(POLL_MS, 20).
-define(DEADLINE_MS, 60000).

start_test_() ->
    {timeout, 90, fun start/0}.

start() ->
    ok = application:set_env(public_key, cacerts_path, filename:absname("roots.fifo")),
    {ok, Host} = erx_ui_host:start(#{width => ?WIDTH, height => ?HEIGHT, renderer => lvgl}),
    Deadline = erlang:monotonic_time(millisecond) + ?DEADLINE_MS,
    Started = self(),
    %% The start is asked from a process of its own, so a start that never
    %% returns fails the deadline below rather than the test's timeout.
    spawn(fun() -> Started ! {started, erx_dashboard:start_link()}, receive after infinity -> ok end end),
    Corner = ground_corner(),
    {ok, ?WIDTH, ?HEIGHT, _Ground} = frame(Host, fun(Pixels) -> corner(Pixels) =:= Corner end, Deadline),
    receive {started, Result} -> ?assertMatch({ok, _}, Result) after 0 -> error(not_started) end.

%% The first frame `Wanted` takes, polled until `Deadline`.
frame(Host, Wanted, Deadline) ->
    Frame = erx_ui_host:frame(Host),
    case Frame of
        {ok, _W, _H, Pixels} ->
            case Wanted(Pixels) of
                true -> Frame;
                false -> again(Host, Wanted, Deadline)
            end;
        none ->
            again(Host, Wanted, Deadline)
    end.

again(Host, Wanted, Deadline) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        true ->
            timer:sleep(?POLL_MS),
            frame(Host, Wanted, Deadline);
        false ->
            error(no_frame)
    end.

%% A frame's top-left pixel as {R, G, B}; the frame is x8r8g8b8, each
%% pixel a little-endian word.
corner(<<B, G, R, _X, _/binary>>) -> {R, G, B}.

%% The ground's pixel at the window's top-left corner: the ground is an
%% indexed PNG of a byte a pixel, each row led by its filter type, none.
ground_corner() ->
    <<_Signature:8/binary, Chunks/binary>> = erx_dashboard_pictures:ground(erx_dashboard_view:clock_offset()),
    #{<<"IHDR">> := <<Width:32, Height:32, _/binary>>, <<"PLTE">> := Palette, <<"IDAT">> := Deflated} = chunks(Chunks, #{}),
    X = (Width - ?WIDTH) div 2,
    Y = (Height - ?HEIGHT) div 2,
    <<_:(Y * (Width + 1) + 1 + X)/binary, Index, _/binary>> = zlib:uncompress(Deflated),
    <<_:(3 * Index)/binary, R, G, B, _/binary>> = Palette,
    {R, G, B}.

chunks(<<>>, Chunks) -> Chunks;
chunks(<<Length:32, Type:4/binary, Data:Length/binary, _Crc:32, Rest/binary>>, Chunks) ->
    chunks(Rest, Chunks#{Type => Data}).
