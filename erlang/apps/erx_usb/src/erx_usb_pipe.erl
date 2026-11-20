%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_pipe).
-moduledoc """
A function's pipes (docs/design-usb.md, "Transfers and pipes"): how a
function process submits transfers through its controller process. A pipe
names its controller, its device's reference and its endpoint's address;
the bus process makes one for each pipe a function claims, with new/3, and
hands the function its own pipes alone at start.

control/3 sends one request on a device's EP0 and waits for its answer,
`{ok, Bytes}` or `{error, Reason}`, `{error, gone}` should the controller
end first. interrupt_in/3 posts one interrupt-IN transfer; its completion arrives as
the message `{usb, Pipe, Tag, Result}`, Result `{ok, Bytes}` or `{error,
Reason}`, so a function keeps its transfers posted and waits in its own
receive. The controller answers a pipe whose device is detached `{error,
gone}`.

Each request reaches the controller as `{erx_usb_pipe, From, Request}`;
this module is the one that spells it.
""".

-export([new/3, endpoint/1, control/3, interrupt_in/3]).

-export_type([pipe/0]).

-opaque pipe() :: {pipe, Controller :: pid(), erx_usb_bus_core:ref(), Address :: byte()}.

-doc "The pipe of endpoint Address of device Ref, served by Controller.".
-spec new(pid(), erx_usb_bus_core:ref(), byte()) -> pipe().
new(Controller, Ref, Address) when is_pid(Controller), is_integer(Address), Address >= 0, Address =< 255 ->
    {pipe, Controller, Ref, Address}.

-doc "The device reference and endpoint address Pipe names, as the controller reads them.".
-spec endpoint(pipe()) -> {erx_usb_bus_core:ref(), byte()}.
endpoint({pipe, _Controller, Ref, Address}) ->
    {Ref, Address}.

-doc """
Sends the control request Setup, with the data stage Data, on Pipe, a
device's EP0, and answers the controller's answer.
""".
-spec control(pipe(), <<_:64>>, none | {in, pos_integer()} | {out, binary()}) -> {ok, binary()} | {error, term()}.
control(Pipe = {pipe, Controller, _Ref, _Address}, Setup, Data) ->
    Monitor = monitor(process, Controller),
    Controller ! {?MODULE, self(), {control, Pipe, Setup, Data, Monitor}},
    receive
        {Monitor, Answer} -> demonitor(Monitor, [flush]), Answer;
        {'DOWN', Monitor, process, Controller, _Reason} -> {error, gone}
    end.

-doc "Posts one interrupt-IN transfer of up to Length bytes on Pipe; its completion is `{usb, Pipe, Tag, Result}`.".
-spec interrupt_in(pipe(), term(), pos_integer()) -> ok.
interrupt_in(Pipe = {pipe, Controller, _Ref, _Address}, Tag, Length) when is_integer(Length), Length > 0 ->
    Controller ! {?MODULE, self(), {interrupt_in, Pipe, Tag, Length}},
    ok.
