%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A stand-in for erx_usb_pipe (docs/design-usb.md, "Transfers and pipes") for the HID
%% function's host tests: the calls a function makes, with the answers and completion
%% messages the design states, carried to a model device process of the test. A pipe is
%% {stand_in_pipe, Device, EndpointAddress}. control/3 answers what the device answers,
%% or {error, gone} once the device has ended; interrupt_in/3 answers ok, and the
%% device sends the transfer's completion, {usb, Pipe, Tag, Result}, to the poster.
-module(erx_usb_pipe).

-export([control/3, interrupt_in/3]).

control({stand_in_pipe, Device, _} = Pipe, Setup, Data) ->
    Monitor = erlang:monitor(process, Device),
    Device ! {control, self(), Monitor, Pipe, Setup, Data},
    receive
        {Monitor, Answer} -> erlang:demonitor(Monitor, [flush]), Answer;
        {'DOWN', Monitor, process, Device, _} -> {error, gone}
    end.

interrupt_in({stand_in_pipe, Device, _} = Pipe, Tag, Length) ->
    Device ! {interrupt_in, self(), Pipe, Tag, Length},
    ok.
