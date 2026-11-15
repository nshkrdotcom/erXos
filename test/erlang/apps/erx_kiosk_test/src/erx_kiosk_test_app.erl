%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_kiosk_test_app).
-moduledoc """
The test-only application erx_kiosk_test, which only a test image's domain
boot script boots (tools/lib/erx/erlang_apps.rb, TEST_ONLY): the lvgl cell's
client of the display suite (tools/lib/erx/display_domain.rb). Its
supervisor holds one process, erx_kiosk_test:start_link/0, which opens the
UI and logs its events. The process is `transient`: killed, it is started
again and opens the UI again, which is the lvgl-restart cell (the restart
of a kiosk's window by its supervisor, docs/design-display.md,
Verification); one that ends normally, after it logged a failed step or
the UI's end, is not.
""".
-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1, init/1]).

start(_Type, _Args) ->
    supervisor:start_link(?MODULE, []).

stop(_State) ->
    ok.

init([]) ->
    Client = #{id => erx_kiosk_test, start => {erx_kiosk_test, start_link, []}, restart => transient},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 60}, [Client]}}.
