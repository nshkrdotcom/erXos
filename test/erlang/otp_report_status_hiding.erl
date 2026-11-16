%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% otp_report_status_tests' plain server with a format_status/1 that hides every term
%% it is handed: state, message, log and reason alike, and proc_lib's reason too.
-module(otp_report_status_hiding).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

init(Secret) -> otp_report_status_tests:init(Secret).

handle_call(Request, From, State) -> otp_report_status_tests:handle_call(Request, From, State).

handle_cast(Message, State) -> otp_report_status_tests:handle_cast(Message, State).

handle_info(Message, State) -> otp_report_status_tests:handle_info(Message, State).

format_status(Status) -> maps:map(fun(_Key, _Value) -> hidden end, Status).
