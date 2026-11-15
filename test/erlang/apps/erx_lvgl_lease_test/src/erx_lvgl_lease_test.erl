%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_lvgl_lease_test).
-moduledoc """
The display suite's lvgl-lease cell (tools/lib/erx/display_domain.rb): in
the session the start row keeps on the display, it runs the LVGL
renderer, erx_ui_lvgl, over the real erx-lvgl started through its handler
with a buffer lent from the pixel area the session shares with the display
(docs/design-display.md, "The widget server"; docs/design-programs.md,
"The handler"). This process plays the widget server and the window: the
renderer's presents come here and are answered with shown/1. So the
program's fstat and mmap of descriptor 3, the driver's map of the lease,
the pipes of a session process's program and the renderer's protocol over
them all run on the target.

run/0 logs `erx_lvgl_lease_test: started`, then runs ?ROUNDS rounds. Each
starts the renderer at ?WIDTH by ?HEIGHT with a buffer of ?BYTES, applies a
tree, a column of a label and a button that takes clicks, waits for the
program's first report after the apply returned, presented at that size,
answers it and stops the renderer. The apply runs in a process of its own
while this one answers every present: the program reports its first
screen as soon as it has read it, and the renderer answers an apply that
comes while a report is open only once the report is answered
(erx_ui_lvgl_core). The first round also clicks the button between the
report and its answer and waits for the click's hit. The rounds lend ?ROUNDS times
?BYTES, more than the session's whole pixel area, so they pass only if a
stopped program's range rejoins the free list once its lease is returned
(docs/design-display.md, "The pixel area"). A start is retried while it is
refused for want of room or of the area (`enomem`, `einval`, `enodev`):
the pixel area and its allocator arrive after the session starts, and a
stopped round's range comes back only after its program's mapping is
gone. Any other refusal fails the round at once. The outcome is one
notice,

    erx_lvgl_lease_test: passed

or `erx_lvgl_lease_test: {error, Round, Reason}` naming the round that
failed, round 0 for the wait for the display's grant. The process then
waits for ever.
""".

-export([run/0]).

-define(DISPLAY, display).
-define(WIDTH, 240).
-define(HEIGHT, 160).
-define(X8R8G8B8, 16#68081828).
-define(BYTES, 1 bsl 20).
-define(ROUNDS, 9).
-define(BUTTON, 3).
-define(BUTTON_Y, 5 + 30 + 40 div 2).
-define(POLLS, 120).
-define(POLL_MS, 500).
-define(WAIT_MS, 30000).
%% The process ids of the rounds' programs, one each, so no round's id is
%% one a handler of an earlier round still speaks for.
-define(FIRST_PID, 900).

-spec run() -> no_return().
run() ->
    process_flag(trap_exit, true),
    logger:notice("erx_lvgl_lease_test: started"),
    Outcome = try
                  Peer = peer(?POLLS),
                  lists:foreach(fun(Round) -> lend_round(Peer, Round) end, lists:seq(1, ?ROUNDS))
              catch
                  throw:{failed, Round, Reason} -> {error, Round, Reason};
                  Class:Reason -> {error, unknown, {Class, Reason}}
              end,
    case Outcome of
        ok -> logger:notice("erx_lvgl_lease_test: passed");
        Failed -> logger:notice("erx_lvgl_lease_test: ~0p", [Failed])
    end,
    %% A trapping process would never take the application's shutdown.
    process_flag(trap_exit, false),
    receive after infinity -> ok end.

%% The display domain whose area the session shares: the owner of the
%% display's grant, which arrives after the session starts.
peer(0) ->
    throw({failed, 0, no_display});
peer(N) ->
    case erx:cap(?DISPLAY) of
        undefined -> timer:sleep(?POLL_MS), peer(N - 1);
        Grant -> erx:owner(Grant)
    end.

lend_round(Peer, Round) ->
    Shell = started(Peer, Round, ?POLLS),
    expect(Round, {ok, Shell}, applied(Round, Shell)),
    expect(Round, {?WIDTH, ?HEIGHT}, first_present(Round, Shell)),
    clicked(Round, Shell),
    ok = erx_ui_lvgl:stop(Shell),
    receive
        {'EXIT', Shell, normal} -> ok;
        {'EXIT', Shell, Why} -> throw({failed, Round, {stopped, Why}})
    after ?WAIT_MS -> throw({failed, Round, stop_hung})
    end.

%% A started renderer; a start refused for want of room or of the area
%% is retried, any other refusal fails the round with its reason.
started(Peer, Round, Polls) ->
    try erx_ui_lvgl:start({window, lease}, self(), opts(Peer, Round)) of
        {ok, Shell} -> Shell
    catch
        error:{badmatch, {error, {shutdown, {renderer_down, {start, Errno}}}}}
          when Polls > 1, (Errno =:= enomem orelse Errno =:= einval orelse Errno =:= enodev) ->
            timer:sleep(?POLL_MS),
            started(Peer, Round, Polls - 1);
        error:{badmatch, {error, Refused}} ->
            throw({failed, Round, {start, Refused}})
    end.

opts(Peer, Round) ->
    Pid = ?FIRST_PID + Round,
    Spec = #{image => <<"bin/erx-lvgl">>, pid => Pid, ppid => 1, pgid => Pid, argv => [<<"erx-lvgl">>],
             env => [], cwd => <<"/">>, spawn => false, sigmask => [], sigignore => [], umask => 8#022},
    Test = self(),
    #{width => ?WIDTH, height => ?HEIGHT, chan => ?X8R8G8B8,
      program => {handler, Spec, Peer, ?BYTES},
      present => fun(_Offset, W, H, Rects) -> Test ! {present, self(), W, H, Rects}, ok end,
      present_text => fun(_Type, _Value) -> error(no_presentations) end}.

%% The tree applied from a process of its own, with every present
%% answered until the apply returns.
applied(Round, Shell) ->
    Test = self(),
    Applier = spawn_link(fun() -> Test ! {applied, self(), erx_ui_lvgl:apply(tree(), Shell)} end),
    answer_until_applied(Round, Shell, Applier).

answer_until_applied(Round, Shell, Applier) ->
    receive
        {present, Shell, _, _, _} ->
            erx_ui_lvgl:shown(Shell),
            answer_until_applied(Round, Shell, Applier);
        {applied, Applier, Answer} ->
            receive {'EXIT', Applier, normal} -> Answer end;
        {'EXIT', Shell, Why} ->
            throw({failed, Round, {down, Why}})
    after ?WAIT_MS -> throw({failed, Round, apply_hung})
    end.

%% The size of the program's first report.
first_present(Round, Shell) ->
    receive
        {present, Shell, W, H, _Rects} -> {W, H};
        {'EXIT', Shell, Why} -> throw({failed, Round, {down, Why}})
    after ?WAIT_MS -> throw({failed, Round, no_present})
    end.

%% In the first round, a click while the first report is open, then every
%% report answered until its hit; in the others, the first report answered.
clicked(1, Shell) ->
    erx_ui_lvgl:window(Shell, {input, {pointer, ?WIDTH div 2, ?BUTTON_Y, 1}}),
    erx_ui_lvgl:window(Shell, {input, {pointer, ?WIDTH div 2, ?BUTTON_Y, 0}}),
    erx_ui_lvgl:shown(Shell),
    expect(1, {ui_hit, ?BUTTON, on_click, none}, answer_until_hit(Shell));
clicked(_Round, Shell) ->
    erx_ui_lvgl:shown(Shell).

answer_until_hit(Shell) ->
    receive
        {present, Shell, _, _, _} -> erx_ui_lvgl:shown(Shell), answer_until_hit(Shell);
        {ui_hit, _, _, _} = Hit -> Hit;
        {'EXIT', Shell, Why} -> {down, Why}
    after ?WAIT_MS -> no_hit
    end.

expect(_Round, Value, Value) -> ok;
expect(Round, _Wanted, Got) -> throw({failed, Round, Got}).

%% The tree of test/erlang/erx_ui_lvgl_shell.erl: a column of a label and a
%% button that takes clicks.
tree() ->
    Tree = [{insert, 1, 0, 0, column, #{pad => 5}},
            {insert, 2, 1, 0, label, #{height => 30, text => <<"erXos kiosk">>}},
            {insert, ?BUTTON, 1, 1, button, #{height => 40, text => <<"Press">>, on_click => pressed}},
            commit],
    {ok, Realised} = erx_ui_model:apply_ops(Tree, erx_ui_model:empty()),
    erx_ui_model:delta(erx_ui_model:empty(), Realised).
