%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A HID function as the bus process's host tests need one: a process that does
%% nothing but run until it is stopped or killed, so the tests can end an instance
%% at will. The mode in the persistent term erx_usb_hid_stand_in, `run` or `fail`,
%% says whether a start succeeds; each start is told to the process registered as
%% erx_usb_bus_tests, with the instance's pid and arguments.

-module(erx_usb_hid).

-export([start_link/1]).

start_link(Args) ->
    case persistent_term:get(erx_usb_hid_stand_in, run) of
        run ->
            Pid = proc_lib:spawn_link(fun() -> receive stop -> ok end end),
            tell({hid_started, Pid, Args}),
            {ok, Pid};
        fail ->
            tell({hid_refused, Args}),
            {error, stand_in_refused}
    end.

tell(Message) ->
    case whereis(erx_usb_bus_tests) of
        undefined -> ok;
        Tests -> Tests ! Message
    end.
