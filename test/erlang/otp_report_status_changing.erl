%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A gen_statem for otp_report_status_tests with no format_status/1 that, at the event
%% {hold, Secret}, changes its callback module to otp_report_status_hiding, which has
%% one, and then fails there as the other servers fail.
-module(otp_report_status_changing).

-export([init/1, callback_mode/0, handle_event/4]).

init(Secret) ->
    put(held, Secret),
    {ok, idle, {held, Secret}}.

callback_mode() -> handle_event_function.

handle_event(cast, {hold, _Secret}, _State, _Data) ->
    {keep_state_and_data, [{change_callback_module, otp_report_status_hiding}]}.
