%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_lvgl_lease_test_app).
-moduledoc """
The test-only application erx_lvgl_lease_test, which only a test image's
domain boot script boots (tools/lib/erx/erlang_apps.rb, TEST_ONLY): the
display suite's lvgl-lease cell (tools/lib/erx/display_domain.rb). Its one
process, erx_lvgl_lease_test:run/0, runs erx-lvgl over lent buffers, logs
its outcome and then waits until the session is ended from outside.
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, spawn_link(erx_lvgl_lease_test, run, [])}.

stop(_State) ->
    ok.
