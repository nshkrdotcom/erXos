%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_draw and its draw connection, erx_draw_conn, on a window of the window system on
%% stock OTP (test/host/erx_win_test.rb), over erx_win_tests' fixture: an 8 by 4 screen
%% whose driver model tells this process each rectangle it flushes. The live images
%% erx_memdraw:test_images/0 counts stand in for the session's budget.
%%
%% Cases: seventeen one-pixel draws present their bounding box, and a draw into an image
%% that is not the window's presents nothing; a write refused at its third message applies
%% none of the two before it; the pixel quota refuses an image past it, a freed image
%% makes room again, and the default quota is 64 MiB; a freed image is gone before the
%% next write is answered and a connection's end frees every image it held; an r's bytes
%% come at most 64 KiB to a read; a load larger than one write goes in bands of rows; a
%% present that fails answers incomplete, applies the rest of the write and keeps the
%% dirty list; a connection that has ended answers ebadf; a resize makes image 0 anew and
%% keeps the others; and a connection whose window's holder ends mid-write never draws
%% into the next window, whose buffer is another range until the connection has ended.

-module(erx_draw_tests).
-include_lib("eunit/include/eunit.hrl").

-define(XRGB32, 16#68081828).
-define(RED, 16#FF0000FF).
-define(WIDTH, 8).
-define(HEIGHT, 4).
-define(PAGE, 4096).
-define(WAIT, 5000).

%% Fixtures ------------------------------------------------------------------

%% EUnit runs the cases in one process, so an earlier case's flushes are dropped first;
%% the fixture's stop kills the screen, after which no more arrive.
with(Case) ->
    drop_flushes(),
    erx_win_tests:with(Case).

drop_flushes() ->
    receive {flushed, _} -> drop_flushes() after 0 -> ok end.

%% A window as large as the screen and a draw connection on it, both the caller's, once
%% the screen has flushed the layouts that show the window.
opened() ->
    opened(#{}).

opened(Options) ->
    Draw = draw_on_window(Options),
    settled(),
    Draw.

draw_on_window(Options) ->
    {ok, Window} = erx_win:open(screen, #{}),
    {ok, Draw} = erx_draw:open(Window, Options),
    Draw.

settled() ->
    receive {flushed, _} -> settled() after 200 -> ok end.

%% Image 1, a replicated opaque red, to draw from and through.
red(Draw) ->
    {ok, 1, Next} = erx_draw:alloc(Draw, {0, 0, 1, 1}, ?XRGB32, #{color => ?RED, repl => true}),
    Next.

ok({ok, Draw}) -> Draw.

%% The one connection the fixture's erx_win_sup holds.
conn() ->
    [Conn] = [Pid || {_, Pid, _, [erx_draw_conn]} <- supervisor:which_children(erx_win_sup)],
    Conn.

no_flush() ->
    receive {flushed, Rects} -> error({flushed, Rects}) after 200 -> ok end.

%% The images alive once every process is collected, so no image a process dropped,
%% such as the display side's image over a window's buffer, lingers as its garbage.
live_images() ->
    _ = [erlang:garbage_collect(Pid) || Pid <- processes()],
    erx_memdraw:test_images().

%% Waits for the live images to come to Count, as an ended process's images are
%% destroyed.
images_come_to(Count) ->
    images_come_to(Count, 200).

images_come_to(Count, 0) ->
    ?assertEqual(Count, live_images());
images_come_to(Count, Tries) ->
    case live_images() of
        Count -> ok;
        _ -> receive after 10 -> images_come_to(Count, Tries - 1) end
    end.

%% The colour bytes of x8r8g8b8 pixels, whose x byte a fill leaves undefined.
rgb(Pixels) ->
    << <<B, G, R>> || <<B, G, R, _X>> <= Pixels >>.

%% Cases ---------------------------------------------------------------------

seventeen_draws_present_their_bounding_box_test() ->
    with(fun(_) ->
        Draw = red(opened()),
        Pixels = [{X, Y} || Y <- [0, 1], X <- lists:seq(0, ?WIDTH - 1)] ++ [{0, 2}],
        Drawn = lists:foldl(fun({X, Y}, D) -> ok(erx_draw:draw(D, 0, {X, Y, X + 1, Y + 1}, 1, 1, {0, 0})) end,
                            Draw, Pixels),
        _ = ok(erx_draw:flush(Drawn)),
        ?assertEqual([{0, 0, ?WIDTH, 3}], erx_win_tests:flushed())
    end).

sixteen_draws_present_as_they_are_test() ->
    with(fun(_) ->
        Draw = red(opened()),
        Pixels = [{X, Y} || Y <- [0, 1], X <- lists:seq(0, ?WIDTH - 1)],
        Drawn = lists:foldl(fun({X, Y}, D) -> ok(erx_draw:draw(D, 0, {X, Y, X + 1, Y + 1}, 1, 1, {0, 0})) end,
                            Draw, Pixels),
        _ = ok(erx_draw:flush(Drawn)),
        ?assertEqual(lists:sort([{X, Y, X + 1, Y + 1} || {X, Y} <- Pixels]), lists:sort(erx_win_tests:flushed()))
    end).

an_offscreen_draw_presents_nothing_test() ->
    with(fun(_) ->
        Draw = red(opened()),
        {ok, Image, Allocated} = erx_draw:alloc(Draw, {0, 0, 4, 4}, ?XRGB32, #{}),
        _ = ok(erx_draw:flush(ok(erx_draw:draw(Allocated, Image, {0, 0, 4, 4}, 1, 1, {0, 0})))),
        no_flush()
    end).

a_refused_write_applies_nothing_test() ->
    with(fun(_) ->
        Draw = opened(),
        Before = live_images(),
        Alloc = {alloc, 1, 0, 0, ?XRGB32, 1, {0, 0, 1, 1}, erx_draw_core:plane(), ?RED},
        %% Red, a red pixel of the window, then red again: the third fails with eexist.
        Batch = lists:foldl(fun(Msg, D) -> ok(erx_draw:message(D, Msg)) end, Draw,
                            [Alloc, {draw, 0, 1, 1, {2, 1, 3, 2}, {0, 0}, {0, 0}}, Alloc]),
        {error, eexist, Refused} = erx_draw:flush(Batch),
        no_flush(),
        ?assertEqual(Before, live_images()),
        {ok, Pixel, Read} = erx_draw:read(Refused, 0, {2, 1, 3, 2}),
        ?assertEqual(<<0, 0, 0>>, rgb(Pixel)),
        %% Red was never made, so a message naming it fails as one naming nothing.
        ?assertMatch({error, enoent, _}, erx_draw:flush(ok(erx_draw:free(Read, 1))))
    end).

the_quota_refuses_an_image_past_it_test() ->
    with(fun(_) ->
        %% A 32 by 32 image of 32 bits is one page; the quota holds two.
        Draw = opened(#{quota => 2 * ?PAGE}),
        Page = {0, 0, 32, 32},
        {ok, First, D1} = erx_draw:alloc(Draw, Page, ?XRGB32, #{}),
        {ok, _Second, D2} = erx_draw:alloc(D1, Page, ?XRGB32, #{}),
        Full = ok(erx_draw:flush(D2)),
        {ok, _Third, D3} = erx_draw:alloc(Full, Page, ?XRGB32, #{}),
        {error, enomem, Refused} = erx_draw:flush(D3),
        {ok, _Again, D4} = erx_draw:alloc(ok(erx_draw:free(Refused, First)), Page, ?XRGB32, #{}),
        ?assertMatch({ok, _}, erx_draw:flush(D4))
    end).

the_default_quota_is_64_mib_test() ->
    with(fun(_) ->
        Draw = opened(),
        Before = live_images(),
        %% 4096 by 4096 pixels of 32 bits fill the quota; one more page passes it. The
        %% write is refused whole, so neither is allocated.
        {ok, _, D1} = erx_draw:alloc(Draw, {0, 0, 4096, 4096}, ?XRGB32, #{}),
        {ok, _, D2} = erx_draw:alloc(D1, {0, 0, 1, 1}, ?XRGB32, #{}),
        ?assertMatch({error, enomem, _}, erx_draw:flush(D2)),
        ?assertEqual(Before, live_images())
    end).

a_freed_image_goes_before_the_next_answer_test() ->
    with(fun(_) ->
        Draw = ok(erx_draw:flush(opened())),
        Base = erx_memdraw:test_images(),
        {ok, First, D1} = erx_draw:alloc(Draw, {0, 0, 8, 8}, ?XRGB32, #{}),
        {ok, _Second, D2} = erx_draw:alloc(D1, {0, 0, 8, 8}, ?XRGB32, #{}),
        Held = ok(erx_draw:flush(D2)),
        ?assertEqual(Base + 2, erx_memdraw:test_images()),
        Freed = ok(erx_draw:flush(ok(erx_draw:free(Held, First)))),
        %% The connection answers this write only after it collected the last one's garbage.
        _ = ok(erx_draw:flush(Freed)),
        ?assertEqual(Base + 1, erx_memdraw:test_images())
    end).

a_connection_frees_its_images_when_its_window_ends_test() ->
    with(fun(_) ->
        Before = live_images(),
        Test = self(),
        Opener = spawn(fun() ->
                               Draw = red(draw_on_window(#{})),
                               {ok, _, D1} = erx_draw:alloc(Draw, {0, 0, 8, 8}, ?XRGB32, #{}),
                               {ok, _, D2} = erx_draw:alloc(D1, {0, 0, 16, 16}, ?XRGB32, #{}),
                               _ = ok(erx_draw:flush(D2)),
                               Test ! {drew, self()},
                               receive stop -> ok end
                       end),
        receive {drew, Opener} -> ok after ?WAIT -> error(opener_silent) end,
        Conn = conn(),
        ?assert(erx_memdraw:test_images() >= Before + 3),
        Monitor = monitor(process, Conn),
        Opener ! stop,
        receive {'DOWN', Monitor, process, Conn, normal} -> ok after ?WAIT -> error(connection_stays) end,
        images_come_to(Before)
    end).

an_r_reads_at_most_64_kib_at_a_time_test() ->
    with(fun(_) ->
        %% 129 rows of 128 pixels of 32 bits: 66,048 bytes.
        R = {0, 0, 128, 129},
        {ok, Image, Draw} = erx_draw:alloc(opened(), R, ?XRGB32, #{color => ?RED}),
        {ok, Pixels, Read} = erx_draw:read(Draw, Image, R),
        ?assertEqual(binary:copy(<<0, 0, 16#FF>>, 128 * 129), rgb(Pixels)),
        _ = ok(erx_draw:flush(ok(erx_draw:message(Read, {read, Image, R})))),
        Conn = conn(),
        {ok, First} = erx_draw_conn:read(Conn, 1 bsl 20),
        ?assertEqual(65536, byte_size(First)),
        ?assertEqual({ok, binary:part(Pixels, 65536, 512)}, erx_draw_conn:read(Conn, 1 bsl 20)),
        ?assertEqual({ok, <<>>}, erx_draw_conn:read(Conn, 1 bsl 20))
    end).

a_load_past_one_write_goes_in_bands_test() ->
    with(fun(_) ->
        %% 129 rows of 128 pixels of 32 bits: 66,048 bytes, more than one write holds.
        R = {0, 0, 128, 129},
        {ok, Image, Draw} = erx_draw:alloc(opened(), R, ?XRGB32, #{}),
        Pixels = << <<X, Y, 16#FF, 0>> || Y <- lists:seq(0, 128), X <- lists:seq(0, 127) >>,
        Loaded = ok(erx_draw:load(Draw, Image, R, Pixels)),
        {ok, Read, _} = erx_draw:read(Loaded, Image, R),
        ?assertEqual(rgb(Pixels), rgb(Read))
    end).

%% Without its registered screen the display answers a present eio, as when the screen
%% has ended.
without_screen(Fun) ->
    Screen = whereis(erx_screen),
    true = unregister(erx_screen),
    try Fun() after true = register(erx_screen, Screen) end.

a_failed_present_keeps_the_dirty_list_test() ->
    with(fun(_) ->
        Draw = ok(erx_draw:draw(red(opened()), 0, {2, 1, 3, 2}, 1, 1, {0, 0})),
        {incomplete, eio, Failed} = without_screen(fun() -> erx_draw:flush(Draw) end),
        no_flush(),
        _ = ok(erx_draw:flush(Failed)),
        ?assertEqual([{2, 1, 3, 2}], erx_win_tests:flushed())
    end).

a_failure_after_the_plan_applies_the_rest_test() ->
    with(fun(_) ->
        Red = ok(erx_draw:flush(red(opened()))),
        Batch = lists:foldl(fun(Msg, D) -> ok(erx_draw:message(D, Msg)) end, Red,
                            [{draw, 0, 1, 1, {0, 0, 1, 1}, {0, 0}, {0, 0}}, flush,
                             {draw, 0, 1, 1, {3, 2, 4, 3}, {0, 0}, {0, 0}}]),
        {incomplete, eio, Failed} = without_screen(fun() -> erx_draw:flush(Batch) end),
        %% The draw after the failed present was applied: the pixel is no longer black.
        {ok, Pixel, _} = erx_draw:read(Failed, 0, {3, 2, 4, 3}),
        ?assertNotEqual(<<0, 0, 0>>, rgb(Pixel))
    end).

%% A connection starts only on a window its starter holds, and a window has one at a time.
an_open_is_refused_for_a_window_not_held_or_already_drawn_test() ->
    with(fun(_) ->
        {ok, Window} = erx_win:open(screen, #{}),
        Test = self(),
        spawn(fun() -> Test ! {stranger, erx_draw:open(Window)} end),
        ?assertEqual({error, einval}, receive {stranger, Answer} -> Answer after ?WAIT -> error(silent) end),
        {ok, Draw} = erx_draw:open(Window),
        ?assertEqual({error, ebusy}, erx_draw:open(Window)),
        ?assertMatch({ok, _}, erx_draw:flush(Draw))
    end).

an_ended_connection_answers_ebadf_test() ->
    with(fun(_) ->
        Draw = opened(),
        Conn = conn(),
        Monitor = monitor(process, Conn),
        exit(Conn, kill),
        receive {'DOWN', Monitor, process, Conn, killed} -> ok end,
        ?assertMatch({error, ebadf, _}, erx_draw:flush(ok(erx_draw:free(Draw, 0)))),
        ?assertMatch({error, ebadf, _}, erx_draw:read(Draw, 0, {0, 0, 1, 1})),
        ?assertMatch({error, ebadf, _}, erx_draw:resized(Draw))
    end).

a_resize_makes_image_0_anew_and_keeps_the_others_test() ->
    with(fun(_) ->
        {ok, Window} = erx_win:open(screen, #{}),
        {ok, Draw} = erx_draw:open(Window),
        settled(),
        {ok, Image, Allocated} = erx_draw:alloc(Draw, {0, 0, 2, 2}, ?XRGB32, #{color => ?RED}),
        Held = ok(erx_draw:flush(Allocated)),
        %% The screen shrinks: the window's size changes and its next mouse read is r.
        _ = erx_winfs:attach({0, 0, 6, 3}, <<"x8r8g8b8">>),
        ?assertMatch({ok, {resized, _, _, _, _}}, erx_win:mouse(Window)),
        Resized = ok(erx_draw:resized(Held)),
        ?assertMatch({ok, <<0:(6 * 32)>>, _}, erx_draw:read(Resized, 0, {0, 0, 6, 1})),
        ?assertMatch({error, einval, _}, erx_draw:read(Resized, 0, {0, 0, 7, 1})),
        {ok, Kept, _} = erx_draw:read(Resized, Image, {1, 1, 2, 2}),
        ?assertEqual(<<0, 0, 16#FF>>, rgb(Kept))
    end).

the_connection_never_draws_into_the_next_window_test() ->
    with(fun(_) ->
        Test = self(),
        Opener = spawn(fun() ->
                               {ok, Window} = erx_win:open(screen, #{}),
                               {ok, Draw} = erx_draw:open(Window),
                               Test ! {opened, self(), maps:get(conn, Draw), offset(Window)},
                               receive stop -> ok end
                       end),
        {Conn, Kept} = receive {opened, Opener, C, O} -> {C, O} after ?WAIT -> error(opener_silent) end,
        settled(),
        %% The connection is held in the middle of a write that fills its window red when its
        %% opener, the holder of the window and the owner of its buffer, ends.
        Fill = iolist_to_binary([erx_draw_codec:encode(Msg)
                                 || Msg <- [{alloc, 1, 0, 0, ?XRGB32, 1, {0, 0, 1, 1}, erx_draw_core:plane(), ?RED},
                                            {draw, 0, 1, 1, {0, 0, ?WIDTH, ?HEIGHT}, {0, 0}, {0, 0}}]]),
        ok = sys:suspend(Conn),
        spawn(fun() -> Test ! {written, erx_draw_conn:write(Conn, Fill)} end),
        queued(Conn),
        Ended = monitor(process, Opener),
        exit(Opener, kill),
        receive {'DOWN', Ended, process, Opener, _} -> ok end,
        allocator_saw_end(Opener),
        %% The range the connection draws into stays out of the free list, so the next
        %% window's buffer is another. (On the host, whose pages are 16 KiB, only the
        %% area's first range can be wrapped, so the case compares ranges, not pixels.)
        ?assertMatch([{Kept, _, Opener, orphaned}], owned_by(Opener)),
        {ok, Next} = erx_win:open(screen, #{}),
        ?assertNotEqual(Kept, offset(Next)),
        Gone = monitor(process, Conn),
        ok = sys:resume(Conn),
        receive {written, ok} -> ok after ?WAIT -> error(write_unanswered) end,
        receive {'DOWN', Gone, process, Conn, _} -> ok after ?WAIT -> error(connection_stays) end,
        %% Once the connection has ended, its range goes back to the free list.
        range_freed(Opener, 200)
    end).

%% The offset of a window's buffer in the area.
offset(Window) ->
    #{own := #{buffer := #{offset := Offset}}} = Window,
    Offset.

%% Waits until Conn has a message queued.
queued(Conn) ->
    case process_info(Conn, message_queue_len) of
        {message_queue_len, 0} -> receive after 1 -> queued(Conn) end;
        {message_queue_len, _} -> ok
    end.

%% Waits until erx_pixels has handled Owner's end: it no longer monitors Owner.
allocator_saw_end(Owner) ->
    case is_map_key(Owner, owners()) of
        true -> receive after 1 -> allocator_saw_end(Owner) end;
        false -> ok
    end.

%% Waits until no live range of erx_pixels belongs to Owner.
range_freed(Owner, 0) ->
    ?assertEqual([], owned_by(Owner));
range_freed(Owner, Tries) ->
    case owned_by(Owner) of
        [] -> ok;
        _ -> receive after 10 -> range_freed(Owner, Tries - 1) end
    end.

owned_by(Owner) ->
    [Range || {_, _, O, _} = Range <- ranges(), O =:= Owner].

%% erx_pixels' state, #state{areas, leases, owners}, read as the tuple it is.
owners() ->
    element(4, sys:get_state(erx_pixels)).

ranges() ->
    lists:append([erx_pixels_core:ranges(Core) || {_Area, Core} <- maps:values(element(2, sys:get_state(erx_pixels)))]).
