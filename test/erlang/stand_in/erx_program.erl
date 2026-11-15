%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_program).
-moduledoc """
A stand-in for the program driver's module in erx_prog_handler's tests:
each call goes to erx_prog_handler_fakes, which reports it to the test
and answers what the test set.
""".

-export([start/1, send/2, install/2, stop/3, slots/1, data_read/3, data_write/3]).

start(Spec) -> erx_prog_handler_fakes:start(Spec).
send(Port, Frame) -> erx_prog_handler_fakes:send(Port, Frame).
install(Port, Hand) -> erx_prog_handler_fakes:install(Port, Hand).
stop(Port, Anchor, Status) -> erx_prog_handler_fakes:stop(Port, Anchor, Status).
slots(Spec) -> maps:get(slots, Spec, 4).
data_read(_Port, _Slot, _Count) -> {error, enosys}.
data_write(_Port, _Slot, _Bytes) -> ok.
