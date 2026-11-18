%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(erx_ui_host_check).
-moduledoc """
An app's host test through erx_ui_host (docs/design-packaging.md, "The
SDK"), as an app written against the SDK would write one: it starts the
stand-in display, opens its UI with erx_ui:open/1, hands it a tree and
reads the frames the renderer presents. It checks:

* frame/1 answers `none` before anything is presented;
* while the host runs, erx_ui:open/1 still refuses a display named
  outright that the domain does not hold, and the Erlang renderer;
* the frame of the first tree, once settled, is written to `first.xrgb`
  in the directory run/1 is given, for test/host/erx_ui_host_test.rb to
  compare with its reference picture;
* a press and release on the button, delivered by input/2, reaches the
  app as the button's `on_click` term, and the tree the app hands in
  answer settles to a frame whose label differs from the first's,
  written to `pressed.xrgb`.

A frame is settled once it shows what the step waits for, judged by the
label's band of rows, and frame/1 has answered it unchanged for QUIET_MS:
the program may present the press's own feedback before the tree that
answers it. run/1 raises at the first check that fails and otherwise
returns a summary.
""".

-export([run/1]).

-define(WIDTH, 240).
-define(HEIGHT, 160).
-define(PAD, 5).
-define(LABEL_HEIGHT, 30).
-define(BUTTON_HEIGHT, 40).
-define(BUTTON_Y, ?PAD + ?LABEL_HEIGHT + ?BUTTON_HEIGHT div 2).
%% A sanitized erx-lvgl on a loaded host is slow to show a change, so the
%% wait for one is long and only the silence after it is a fixed window.
-define(QUIET_MS, 500).
-define(POLL_MS, 50).
-define(SETTLE_MS, 60000).

-doc "Runs the app against the stand-in display; frames go to `Dir`.".
-spec run(file:filename()) -> map().
run(Dir) ->
    {ok, Host} = erx_ui_host:start(#{width => ?WIDTH, height => ?HEIGHT, renderer => lvgl}),
    Before = erx_ui_host:frame(Host),
    none = Before,
    %% A display named outright is not the host, and the Erlang renderer is
    %% not built.
    {error, no_display} = erx_ui:open(#{display => nowhere}),
    {error, enotsup} = erx_ui:open(#{renderer => erlang}),
    {ok, Window} = erx_ui:open(#{}),
    ok = erx_ui:tree(Window, tree(<<"erXos on the host">>)),
    {ok, ?WIDTH, ?HEIGHT, First} = settled(Host, fun(Pixels) -> label(Pixels) =/= blank(Pixels) end),
    ok = file:write_file(filename:join(Dir, "first.xrgb"), First),
    ok = erx_ui_host:input(Host, {pointer, ?WIDTH div 2, ?BUTTON_Y, 1}),
    ok = erx_ui_host:input(Host, {pointer, ?WIDTH div 2, ?BUTTON_Y, 0}),
    Clicked = receive {ui, Window, Term, _Detail} -> Term after ?SETTLE_MS -> error(no_click) end,
    ok = erx_ui:tree(Window, tree(<<"pressed">>)),
    {ok, ?WIDTH, ?HEIGHT, Pressed} = settled(Host, fun(Pixels) -> label(Pixels) =/= label(First) end),
    ok = file:write_file(filename:join(Dir, "pressed.xrgb"), Pressed),
    ok = erx_ui:close(Window),
    ok = erx_ui_host:stop(Host),
    #{before => Before, clicked => Clicked}.

tree(Text) ->
    {column, #{pad => ?PAD},
     [{label, #{height => ?LABEL_HEIGHT, text => Text}, []},
      {button, #{height => ?BUTTON_HEIGHT, text => <<"Press">>, on_click => pressed}, []}]}.

%% The label's band of rows of a frame, and of an empty screen: the
%% background, the colour of the frame's last pixel, which nothing covers.
label(Pixels) -> binary:part(Pixels, 4 * ?WIDTH * ?PAD, 4 * ?WIDTH * ?LABEL_HEIGHT).

blank(Pixels) -> binary:copy(binary:part(Pixels, 4 * (?WIDTH * ?HEIGHT - 1), 4), ?WIDTH * ?LABEL_HEIGHT).

%% The first frame whose pixels Ready accepts that frame/1 then answers
%% unchanged for QUIET_MS.
settled(Host, Ready) ->
    settled(Host, Ready, none, 0, erlang:monotonic_time(millisecond) + ?SETTLE_MS).

settled(Host, Ready, Last, Quiet, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    Now < Deadline orelse error(never_settled),
    timer:sleep(?POLL_MS),
    case erx_ui_host:frame(Host) of
        Frame when Frame =:= Last, Quiet + ?POLL_MS >= ?QUIET_MS, Frame =/= none ->
            {ok, _W, _H, Pixels} = Frame,
            case Ready(Pixels) of
                true -> Frame;
                false -> settled(Host, Ready, Last, Quiet + ?POLL_MS, Deadline)
            end;
        Frame when Frame =:= Last ->
            settled(Host, Ready, Last, Quiet + ?POLL_MS, Deadline);
        Frame ->
            settled(Host, Ready, Frame, 0, Deadline)
    end.
