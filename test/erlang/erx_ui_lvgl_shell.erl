%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_lvgl_shell).
-moduledoc """
The LVGL renderer's shell, erx_ui_lvgl, driving the real erx-lvgl on the
host (docs/design-display.md, "The widget server"). The program runs
through test/fixtures/erx_lvgl_buffer.rb with the file `buffer` in the
current directory as descriptor 3, and the window is played by this
process: the shell's presents come here, and are answered with shown/1
when the case says.

run/1 returns what test/host/erx_ui_lvgl_test.rb checks:

* `first`: the first present's size, after apply/2 returned. The apply
  runs in a process of its own while this one answers any present, a
  tolerance only: an apply that came while a report was open would
  return only once the report is answered (erx_ui_lvgl_core), and the
  program reports nothing before its first tree.
* `held`: the hits that came while that present was unanswered and a
  click was sent, none, since the shell takes the window's input only
  while no report is open; `hit`, the click's hit once it is answered.
* `grown`: a resize past the buffer: the shell writes the screen record
  clipped to the buffer's size, so the program keeps running and its
  reports keep the buffer's size, and stop/1 then ends the shell
  normally. A shell that writes the window's unclipped size makes the
  program refuse it, and the UI end as `renderer_down`.
* `closed`: stop/1 after the first frame: the shell ends normally and the
  widget server hears nothing.
* `first_frame`: a window's first frame is its first tree: the presents
  made in the ?SILENT_MS before the tree is applied, none; the presents
  made after, until the program is silent, one, of the whole window; and
  whether the buffer then shows the tree, a row through the button that
  is not all the window's ground. A program that renders before its first
  `commit` presents its empty screen within ?SILENT_MS of its start, on a
  host where it starts within that time, and fails the first count.
""".

-export([run/1]).

-define(WIDTH, 240).
-define(HEIGHT, 160).
-define(X8R8G8B8, 16#68081828).
-define(BUTTON, 3).
-define(BUTTON_Y, 5 + 30 + 40 div 2).
-define(WAIT_MS, 60000).
-define(HOLD_MS, 300).
-define(SILENT_MS, 1000).

-spec run(#{program := file:filename(), ruby := file:filename(), launcher := file:filename()}) -> map().
run(Paths) ->
    process_flag(trap_exit, true),
    Buffer = filename:absname("buffer"),
    ok = file:write_file(Buffer, binary:copy(<<0>>, 4 * ?WIDTH * ?HEIGHT)),
    Shell = start(Paths, Buffer),
    {ok, Shell} = applied(Shell),
    {present, Shell, W, H, _Rects} = next_present(),
    click(Shell),
    Held = hits(?HOLD_MS),
    erx_ui_lvgl:shown(Shell),
    Hit = answer_until_hit(Shell),
    erx_ui_lvgl:resize(Shell, 2 * ?WIDTH, 2 * ?HEIGHT),
    Grown = grown(Shell, none),
    Shell2 = start(Paths, Buffer),
    {ok, Shell2} = applied(Shell2),
    {present, Shell2, _, _, _} = next_present(),
    erx_ui_lvgl:shown(Shell2),
    ok = erx_ui_lvgl:stop(Shell2),
    Closed = receive {'EXIT', Shell2, Why} -> Why after ?WAIT_MS -> error(close_hung) end,
    Heard = hits(?HOLD_MS),
    #{first => {W, H}, held => Held, hit => Hit, grown => Grown, closed => {Closed, Heard},
      killed => killed(Paths, Buffer), first_frame => first_frame(Paths, Buffer)}.

%% A window's first frame: the presents in the ?SILENT_MS before the tree
%% is applied, and those after it: the first, waited for as long as the
%% program takes, and any until it is silent for ?SILENT_MS.
first_frame(Paths, Buffer) ->
    ok = file:write_file(Buffer, binary:copy(<<0>>, 4 * ?WIDTH * ?HEIGHT)),
    Shell = start(Paths, Buffer),
    Before = presents(Shell, ?SILENT_MS),
    {ok, Shell} = applied(Shell),
    {present, Shell, _, _, First} = next_present(),
    erx_ui_lvgl:shown(Shell),
    After = [First | presents(Shell, ?SILENT_MS)],
    ok = erx_ui_lvgl:stop(Shell),
    receive {'EXIT', Shell, normal} -> ok after ?WAIT_MS -> error(close_hung) end,
    {length(Before), length(After), After =:= [[{0, 0, ?WIDTH, ?HEIGHT}]], button_drawn(Buffer)}.

%% The rectangles of each present until Ms pass without one, each answered.
presents(Shell, Ms) ->
    receive
        {present, Shell, _, _, Rects} -> erx_ui_lvgl:shown(Shell), [Rects | presents(Shell, Ms)];
        {'EXIT', Shell, Why} -> error({down, Why})
    after Ms -> []
    end.

%% Whether the row through the button holds a pixel other than the window's
%% ground, the pixel at the window's corner.
button_drawn(Buffer) ->
    {ok, Pixels} = file:read_file(Buffer),
    <<Ground:4/binary, _/binary>> = Pixels,
    Row = binary:part(Pixels, 4 * ?WIDTH * ?BUTTON_Y, 4 * ?WIDTH),
    [Pixel || <<Pixel:4/binary>> <= Row, Pixel =/= Ground] =/= [].

%% Input queued ahead of the program's end: the shell is suspended, sent a
%% click, and the program killed, so the shell writes to a port that has
%% already closed. The UI still ends as renderer_down, by the exit status.
killed(Paths, Buffer) ->
    Shell = start(Paths, Buffer),
    {ok, Shell} = applied(Shell),
    {present, Shell, _, _, _} = next_present(),
    erx_ui_lvgl:shown(Shell),
    {_State, #{program := {port, Port}}} = sys:get_state(Shell),
    {os_pid, Pid} = erlang:port_info(Port, os_pid),
    ok = sys:suspend(Shell),
    click(Shell),
    _ = os:cmd("kill -9 " ++ integer_to_list(Pid)),
    timer:sleep(?HOLD_MS),
    ok = sys:resume(Shell),
    until_down(Shell).

start(#{program := Program, ruby := Ruby, launcher := Launcher}, Buffer) ->
    Test = self(),
    Open = fun() ->
                   open_port({spawn_executable, Ruby},
                             [binary, stream, use_stdio, exit_status, {args, [Launcher, Buffer, Program]}])
           end,
    Present = fun(0, W, H, Rects) -> Test ! {present, self(), W, H, Rects}, ok end,
    {ok, Shell} = erx_ui_lvgl:start({window, test}, Test,
                                    #{width => ?WIDTH, height => ?HEIGHT, chan => ?X8R8G8B8,
                                      program => {port, Open}, present => Present,
                                      present_text => fun(_Type, _Value) -> error(no_presentations) end}),
    Shell.

%% The tree of the model screen, test/erlang/erx_lvgl_screen.erl, in short:
%% a column of a label and a button that takes clicks.
tree() ->
    Tree = [{insert, 1, 0, 0, column, #{pad => 5}},
            {insert, 2, 1, 0, label, #{height => 30, text => <<"erXos kiosk">>}},
            {insert, ?BUTTON, 1, 1, button, #{height => 40, text => <<"Press">>, on_click => pressed}},
            commit],
    {ok, Realised} = erx_ui_model:apply_ops(Tree, erx_ui_model:empty()),
    erx_ui_model:delta(erx_ui_model:empty(), Realised).

click(Shell) ->
    erx_ui_lvgl:window(Shell, {input, {pointer, ?WIDTH div 2, ?BUTTON_Y, 1}}),
    erx_ui_lvgl:window(Shell, {input, {pointer, ?WIDTH div 2, ?BUTTON_Y, 0}}).

%% The tree applied from a process of its own, with every present
%% answered until the apply returns.
applied(Shell) ->
    Test = self(),
    Applier = spawn_link(fun() -> Test ! {applied, self(), erx_ui_lvgl:apply(tree(), Shell)} end),
    answer_until_applied(Shell, Applier).

answer_until_applied(Shell, Applier) ->
    receive
        {present, Shell, _, _, _} -> erx_ui_lvgl:shown(Shell), answer_until_applied(Shell, Applier);
        {applied, Applier, Answer} -> receive {'EXIT', Applier, normal} -> Answer end;
        {'EXIT', Shell, Why} -> error({down, Why})
    after ?WAIT_MS -> error(apply_hung)
    end.

next_present() ->
    receive {present, _, _, _, _} = Present -> Present after ?WAIT_MS -> error(no_present) end.

hits(Ms) ->
    receive {ui_hit, _, _, _} = Hit -> [Hit | hits(Ms)] after Ms -> [] end.

%% Answers every present until the click's hit comes.
answer_until_hit(Shell) ->
    receive
        {present, Shell, _, _, _} -> erx_ui_lvgl:shown(Shell), answer_until_hit(Shell);
        {ui_hit, _, _, _} = Hit -> Hit
    after ?WAIT_MS -> error(no_hit)
    end.

%% Answers every present until ?HOLD_MS pass without one, then stops the
%% shell: the last present's size and the shell's exit, or the UI's end.
grown(Shell, Size) ->
    receive
        {present, Shell, W, H, _} -> erx_ui_lvgl:shown(Shell), grown(Shell, {W, H});
        {'EXIT', Shell, Exit} -> {renderer_down, Exit}
    after ?HOLD_MS ->
        ok = erx_ui_lvgl:stop(Shell),
        receive {'EXIT', Shell, Why} -> {Size, Why} after ?WAIT_MS -> error(close_hung) end
    end.

%% Answers presents until the UI ends: the shell's abnormal exit, which the
%% widget server takes as renderer_down.
until_down(Shell) ->
    receive
        {present, Shell, _, _, _} -> erx_ui_lvgl:shown(Shell), until_down(Shell);
        {'EXIT', Shell, Exit} when Exit =/= normal -> {renderer_down, Exit}
    after ?WAIT_MS -> error(not_down)
    end.
