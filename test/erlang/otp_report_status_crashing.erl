%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A gen_statem for otp_report_status_tests whose format_status/1 crashes. It holds the
%% secret in its data and its dictionary, postpones the event {hold, Secret}, and fails a
%% clause on the secret at the event {fail, Secret} with {held, Secret} in its mailbox.
-module(otp_report_status_crashing).

-export([init/1, callback_mode/0, handle_event/4, format_status/1]).

init(Secret) ->
    put(held, Secret),
    {ok, idle, {held, Secret}}.

callback_mode() -> handle_event_function.

handle_event(cast, {hold, _Secret}, _State, _Data) ->
    {keep_state_and_data, [postpone]};
handle_event(cast, {fail, Secret}, _State, _Data) ->
    self() ! {held, Secret},
    otp_report_status_tests:fails(Secret),
    keep_state_and_data.

format_status(_Status) -> error(format_status_crashed).
