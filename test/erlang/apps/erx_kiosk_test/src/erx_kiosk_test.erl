%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(erx_kiosk_test).
-moduledoc """
The display suite's lvgl cell client (tools/lib/erx/display_domain.rb): an
application of the display's session that opens its UI with
`erx_ui:open(#{renderer => lvgl})`, so erx-lvgl, a native program of the
session, draws tree/0 into the window's buffer (docs/design-display.md,
"Kiosks and glasses"). The harness compares the screen with the reference
picture the host's erx-lvgl draws of the same tree at the same size
(test/host/erx_lvgl_test.rb), then clicks the button and waits for the
event this client logs.

start_link/0 starts the client's process under the application's
supervisor. The process registers itself as erx_kiosk_test, the name the
lvgl-restart cell kills it by from the system's Erlang shell, logs
`erx_kiosk_test: started`, then waits for the
pattern client's window to end, polling erx_pattern_test:closed/0, which
stays true once the window has ended, so a window that lived between two
polls is not missed. Then the session's only window is this one, which
the single policy shows. It opens the UI, retrying every refusal for a
while: the session's pixel area may have no room for the program's buffer
while the lvgl-lease cell's rounds hold it, and the widget server answers
that, as any renderer that did not start, with `renderer_down`. It hands
the UI tree/0 and logs

    erx_kiosk_test: shown

or `erx_kiosk_test: {error, Step, Reason}` naming the step that failed
(`pattern` with `not_closed` when the pattern window had not ended by
the last poll, `open` with the last refusal, `tree`), and ends. Once
shown, it logs each event of the UI,

    erx_kiosk_test: event pressed

and ends with the UI's `{ui_down, Window, Reason}`, or its server's
`'DOWN'`, logged.
""".

-export([start_link/0, tree/0]).

-define(POLLS, 240).
-define(POLL_MS, 500).

-doc """
The tree: a column of a title and a button that covers the screen's middle,
x 16 to 1263 and y 96 to 655 on the display suite's 1280 by 800 screen
(test/display/reference/display-lvgl.ppm.gz), where the harness clicks.
""".
-spec tree() -> erx_ui_model:tree().
tree() ->
    {column, #{pad => 16},
     [{label, #{height => 80, text => <<"erXos kiosk">>}, []},
      {button, #{height => 560, text => <<"Press">>, on_click => pressed}, []}]}.

-doc "Starts the client's process, linked to the caller.".
-spec start_link() -> {ok, pid()}.
start_link() ->
    {ok, proc_lib:spawn_link(fun show/0)}.

show() ->
    true = register(?MODULE, self()),
    logger:notice("erx_kiosk_test: started"),
    case shown() of
        {ok, Window} ->
            logger:notice("erx_kiosk_test: shown"),
            events(Window);
        Failed ->
            logger:notice("erx_kiosk_test: ~0p", [Failed])
    end.

shown() ->
    maybe
        ok ?= step(pattern, pattern_closed(?POLLS)),
        {ok, Window} ?= step(open, opened(?POLLS)),
        ok ?= step(tree, erx_ui:tree(Window, tree())),
        {ok, Window}
    end.

events(Window) ->
    receive
        {ui, Window, Term, _Detail} ->
            logger:notice("erx_kiosk_test: event ~0p", [Term]),
            events(Window);
        {ui_down, Window, Reason} ->
            logger:notice("erx_kiosk_test: ~0p", [{ui_down, Reason}]);
        {'DOWN', Window, process, _Server, Reason} ->
            logger:notice("erx_kiosk_test: ~0p", [{server_down, Reason}])
    end.

%% Waits for the pattern window's end. Each poll lowers the finite count;
%% the window ends once the harness's input has reached it.
pattern_closed(0) ->
    {error, not_closed};
pattern_closed(N) ->
    case erx_pattern_test:closed() of
        true ->
            ok;
        false ->
            timer:sleep(?POLL_MS),
            pattern_closed(N - 1)
    end.

%% Ends: each retry lowers the finite count, and the last answers. Each
%% refusal unlike the one before is logged, `erx_kiosk_test: refused Reason`,
%% so a cell that never sees the UI says why.
opened(N) ->
    opened(N, none).

opened(N, Last) ->
    case erx_ui:open(#{renderer => lvgl, label => <<"kiosk">>}) of
        {error, Reason} when N > 1 ->
            _ = [logger:notice("erx_kiosk_test: refused ~0p", [Reason]) || Reason =/= Last],
            timer:sleep(?POLL_MS),
            opened(N - 1, Reason);
        Answer ->
            Answer
    end.

step(_Step, {ok, _} = Done) -> Done;
step(_Step, ok) -> ok;
step(Step, {error, Reason}) -> {error, Step, Reason}.
