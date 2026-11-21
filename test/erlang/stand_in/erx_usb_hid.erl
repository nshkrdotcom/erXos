%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A HID function as the bus process's host tests need one: a process that does
%% nothing but run until it is stopped or killed, so the tests can end an instance
%% at will. The mode in the persistent term erx_usb_hid_stand_in, `run`, `fail`,
%% `{unusable_start, Interface}` (that interface's start fails unusable) or
%% `{unusable, Interface}`, says whether a start succeeds, and whether the instance on
%% Interface ends finding its interface unusable as soon as the bus tells it to go;
%% each start is told to the process registered as erx_usb_bus_tests, with the
%% instance's pid and arguments.

-module(erx_usb_hid).

-export([start_link/1]).

start_link(Args) ->
    Interface = maps:get(interface, maps:get(function, Args)),
    case persistent_term:get(erx_usb_hid_stand_in, run) of
        {unusable, Interface} ->
            Pid = proc_lib:spawn_link(fun() -> receive {erx_usb_bus, go} -> exit(erx_usb_bus_core:unusable(stand_in)) end end),
            tell({hid_unusable, Pid, Args}),
            {ok, Pid};
        {unusable_start, Interface} ->
            tell({hid_refused, Args}),
            {error, erx_usb_bus_core:unusable(stand_in)};
        fail ->
            tell({hid_refused, Args}),
            {error, stand_in_refused};
        _RunOrUnusableElsewhere ->
            Pid = proc_lib:spawn_link(fun() -> receive stop -> ok end end),
            tell({hid_started, Pid, Args}),
            {ok, Pid}
    end.

tell(Message) ->
    case whereis(erx_usb_bus_tests) of
        undefined -> ok;
        Tests -> Tests ! Message
    end.
