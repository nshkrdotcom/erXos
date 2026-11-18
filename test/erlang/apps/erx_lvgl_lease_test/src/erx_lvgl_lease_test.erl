%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_lvgl_lease_test).
-moduledoc """
The display suite's lvgl-lease, lvgl-damage and lvgl-confine cells
(tools/lib/erx/display_domain.rb), one run each. The lease run: in
the session the start row keeps on the display, it runs the LVGL
renderer, erx_ui_lvgl, over the real erx-lvgl started through its handler
with a buffer lent from the pixel area the session shares with the display
(docs/design-display.md, "The widget server"; docs/design-programs.md,
"The handler"). This process plays the widget server and the window: the
renderer's presents come here and are answered with shown/1. So the
program's fstat and mmap of descriptor 3, the driver's map of the lease,
the pipes of a session process's program and the renderer's protocol over
them all run on the target.

run/0 logs `erx_lvgl_lease_test: started`, then the lease run's ?ROUNDS rounds. Each
starts the renderer at ?WIDTH by ?HEIGHT with a buffer of ?BYTES, applies a
tree, a column of a label and a button that takes clicks, waits for the
program's first report after the apply returned, presented at that size,
answers it and stops the renderer. The apply runs in a process of its own
while this one answers any present, a tolerance only: the renderer would
answer an apply that came while a report was open only once the report
is answered (erx_ui_lvgl_core), and the program reports nothing before
its first tree. The first round also clicks the button between the
report and its answer and waits for the click's hit. The rounds lend ?ROUNDS times
?BYTES, more than the session's whole pixel area, so they pass only if a
stopped program's range rejoins the free list once its lease is returned
(docs/design-display.md, "The pixel area"). A start is retried while it is
refused for want of room or of the area (`enomem`, `einval`, `enodev`):
the pixel area and its allocator arrive after the session starts, and a
stopped round's range comes back only after its program's mapping is
gone. Any other refusal fails the round at once.

The damage and confine runs start the renderer the same way over
uiprobe, a stand-in for erx-lvgl that breaks one rule
(test/guest/programs/uiprobe.c) and expect the renderer to stop the
program and end (docs/design-display.md,
Verification, the kiosk's cells). The damage run's first round writes
a second damage report before the first is answered, which must reach
the present callback once and then stop the program as
`report_before_presented`; its second writes a rectangle outside the
size its report names, which the renderer's reader must refuse before
anything is presented; neither is answered. The confine run's program
stores to the last byte of its buffer and reports the whole screen,
which is presented and answered, then stores one page past the buffer,
which must fault in the program, so it ends with SIGSEGV after exactly
that one present: a store within the lease that faults ends it before
its report.

A round that fails with its renderer up kills it; its program, whose
starter the renderer is, stops with it and returns its lease
(erx_prog_handler), so a failed run leaves the later runs the room
they lend.

Each run's outcome is one notice that names it,

    erx_lvgl_lease_test: lease passed

or `erx_lvgl_lease_test: lease {error, Round, Reason}` naming the round
that failed, round 0 for the wait for the display's grant. The process
then waits for ever.
""".

-export([run/0]).

-define(DISPLAY, display).
-define(WIDTH, 240).
-define(HEIGHT, 160).
-define(X8R8G8B8, 16#68081828).
-define(BYTES, 1 bsl 20).
-define(ROUNDS, 9).
-define(LVGL, <<"erx-lvgl">>).
-define(PROBE, <<"uiprobe">>).
-define(BUTTON, 3).
-define(BUTTON_Y, 5 + 30 + 40 div 2).
-define(POLLS, 120).
-define(POLL_MS, 500).
-define(WAIT_MS, 30000).

-spec run() -> no_return().
run() ->
    process_flag(trap_exit, true),
    logger:notice("erx_lvgl_lease_test: started"),
    Found = try {ok, peer(?POLLS)} catch throw:{failed, 0, Reason} -> {error, 0, Reason} end,
    lists:foreach(fun(Run) -> report(Run, Found) end, [lease, damage, confine]),
    %% A trapping process would never take the application's shutdown.
    process_flag(trap_exit, false),
    receive after infinity -> ok end.

%% Run's outcome line: its rounds' outcome, or the wait for the display's
%% grant's failure.
report(Run, Found) ->
    Outcome = case Found of
                  {ok, Peer} -> attempt(fun() -> rounds(Run, Peer) end);
                  {error, _Round, _Reason} = Failed -> Failed
              end,
    case Outcome of
        ok -> logger:notice("erx_lvgl_lease_test: ~s passed", [Run]);
        _ -> logger:notice("erx_lvgl_lease_test: ~s ~0p", [Run, Outcome])
    end.

attempt(Rounds) ->
    try Rounds() of
        _ -> ok
    catch
        throw:{failed, Round, Reason} -> {error, Round, Reason};
        Class:Reason -> {error, unknown, {Class, Reason}}
    end.

rounds(lease, Peer) ->
    lists:foreach(fun(Round) -> lend_round(Peer, Round) end, lists:seq(1, ?ROUNDS));
rounds(damage, Peer) ->
    probe_round(Peer, ?ROUNDS + 1, [<<"twice">>], unanswered, 1, report_before_presented),
    probe_round(Peer, ?ROUNDS + 2, [<<"rect">>], unanswered, 0, {refused, bad_body});
rounds(confine, Peer) ->
    probe_round(Peer, ?ROUNDS + 3, [<<"past">>, integer_to_binary(?BYTES)], shown, 1, {exit, {signaled, sigsegv}}).

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
    with_renderer(Round, opts(Peer, ?LVGL, []), fun(Shell) ->
        expect(Round, {ok, Shell}, applied(Round, Shell)),
        expect(Round, {?WIDTH, ?HEIGHT}, first_present(Round, Shell)),
        clicked(Round, Shell),
        ok = erx_ui_lvgl:stop(Shell),
        receive
            {'EXIT', Shell, normal} -> ok;
            {'EXIT', Shell, Why} -> throw({failed, Round, {stopped, Why}})
        after ?WAIT_MS -> throw({failed, Round, stop_hung})
        end
    end).

%% The stand-in renderer started with Args: its renderer must stop it for
%% Reason after exactly Presents presents, each answered when Answer is
%% `shown` and none when it is `unanswered`.
probe_round(Peer, Round, Args, Answer, Presents, Reason) ->
    with_renderer(Round, opts(Peer, ?PROBE, Args), fun(Shell) ->
        expect(Round, {Presents, {shutdown, {renderer_down, Reason}}}, presents_until_down(Shell, Answer, 0))
    end).

presents_until_down(Shell, Answer, Count) ->
    receive
        {present, Shell, _, _, _} ->
            answer(Answer, Shell),
            presents_until_down(Shell, Answer, Count + 1);
        {'EXIT', Shell, Why} -> {Count, Why}
    after ?WAIT_MS -> {Count, not_down}
    end.

answer(shown, Shell) -> erx_ui_lvgl:shown(Shell);
answer(unanswered, _Shell) -> ok.

%% Body run over a renderer started with Opts. The renderer is down when
%% this returns or throws: a round that failed with it up kills it.
with_renderer(Round, Opts, Body) ->
    Shell = started(Round, Opts, ?POLLS),
    try Body(Shell) after ended(Shell) end.

ended(Shell) ->
    Monitor = monitor(process, Shell),
    exit(Shell, kill),
    receive {'DOWN', Monitor, process, Shell, _} -> ok end,
    receive {'EXIT', Shell, _} -> ok after 0 -> ok end.

%% A started renderer; a start refused for want of room or of the area
%% is retried, any other refusal fails the round with its reason.
started(Round, Opts, Polls) ->
    try erx_ui_lvgl:start({window, lease}, self(), Opts) of
        {ok, Shell} -> Shell
    catch
        error:{badmatch, {error, {shutdown, {renderer_down, {start, Errno}}}}}
          when Polls > 1, (Errno =:= enomem orelse Errno =:= einval orelse Errno =:= enodev) ->
            timer:sleep(?POLL_MS),
            started(Round, Opts, Polls - 1);
        error:{badmatch, {error, Refused}} ->
            throw({failed, Round, {start, Refused}})
    end.

%% The renderer's options, its program the release's bin/Name run with Args.
opts(Peer, Name, Args) ->
    Spec = #{image => <<"bin/", Name/binary>>, argv => [Name | Args],
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
