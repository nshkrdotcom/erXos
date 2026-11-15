%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_kiosk_wait).
-moduledoc """
The display suite's two session clients in order, on the host
(test/host/erx_kiosk_wait_test.rb): erx_kiosk_test opens its UI only
after erx_pattern_test's window has ended, so that the session's only
window is the kiosk's (tools/lib/erx/display_domain.rb). The kiosk client
looks for that end once every half second, and the pattern window may be
presented and end between two looks; the kiosk must still see the end.

run/0 starts the kiosk client, lets it take its first look (?SETTLE_MS),
then runs the pattern client over the test's stand-in erx_win, whose
window is presented, reads its key and its pointer and ends at once, well
within one of the kiosk's polls. It answers `early` when the kiosk called
erx_ui:open/1 before the pattern client ran, `opened` when it calls it
within ?WAIT_MS after, or `missed` when it never does.
""".

-export([run/0]).

-include("generated/erx_abi.hrl").

-define(SETTLE_MS, 100).
-define(WAIT_MS, 3000).

-spec run() -> early | opened | missed.
run() ->
    process_flag(trap_exit, true),
    true = os:putenv(binary_to_list(?ERX_DISPLAY_KEY_BYTES), "display"),
    {module, erx_ui} = code:ensure_loaded(erx_ui),
    1 = erlang:trace_pattern({erx_ui, open, 1}, true, [local]),
    {ok, Kiosk} = erx_kiosk_test:start_link(),
    1 = erlang:trace(Kiosk, true, [call]),
    timer:sleep(?SETTLE_MS),
    Outcome = receive
                  {trace, Kiosk, call, {erx_ui, open, _Early}} -> early
              after 0 -> after_pattern(Kiosk)
              end,
    unlink(Kiosk),
    exit(Kiosk, kill),
    Outcome.

%% The pattern client run to its window's end, and the kiosk's open after it.
after_pattern(Kiosk) ->
    Pattern = spawn_link(fun erx_pattern_test:show/0),
    Outcome = receive
                  {trace, Kiosk, call, {erx_ui, open, _Args}} -> opened
              after ?WAIT_MS -> missed
              end,
    unlink(Pattern),
    exit(Pattern, kill),
    Outcome.
