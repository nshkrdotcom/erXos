%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% otp_report_status_tests' plain server with a format_status/1 that crashes.
-module(otp_report_status_crashing_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

init(Secret) -> otp_report_status_tests:init(Secret).

handle_call(Request, From, State) -> otp_report_status_tests:handle_call(Request, From, State).

handle_cast(Message, State) -> otp_report_status_tests:handle_cast(Message, State).

handle_info(Message, State) -> otp_report_status_tests:handle_info(Message, State).

format_status(_Status) -> error(format_status_crashed).
