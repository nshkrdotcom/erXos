%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_hub).
-moduledoc """
A hub function (docs/design-usb.md, "Hubs"): the process over
erx_usb_hub_core that watches one external hub's status-change pipe.

It performs what the core decides: a report goes to the bus process as
`{changed, Hub, Set, Pid}`, `Pid` its own; a post is one interrupt-IN
transfer on the hub's one pipe, tagged afresh, so only the completion of
the transfer it posted last is taken; and the core's stop ends the
process with the failed transfer as its reason, which the bus process sees
as the function's end; the core ends it only on a failed transfer, and a
crash ends it too. It begins, with its first report, only when the bus
process tells it to go (erx_usb_bus:go/1). The bus process answers a
report with `{handled, Hub}`. Only the bus process knows the state of the hub's ports: this
process holds nothing but the core's phase and its one posted transfer.
""".
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(hub, {bus :: pid(), device :: erx_usb_bus_core:ref(), pipe :: erx_usb_pipe:pipe(),
              core :: erx_usb_hub_core:state(), posted = none :: none | reference()}).

-doc "Starts the hub function of the hub Args names, linked to the caller.".
-spec start_link(erx_usb_bus:start()) -> {ok, pid()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-doc false.
init(#{bus := Bus, device := Device, ports := Ports, pipes := [Pipe | _]}) ->
    {ok, #hub{bus = Bus, device = Device, pipe = Pipe, core = erx_usb_hub_core:new(Ports)}}.

-doc false.
handle_call(_Request, _From, Hub) ->
    {reply, {error, unsupported}, Hub}.

-doc false.
handle_cast(_Request, Hub) ->
    {noreply, Hub}.

-doc false.
handle_info({erx_usb_bus, go}, Hub = #hub{core = Core}) ->
    noreply(perform(erx_usb_hub_core:step(start, Core), Hub));
handle_info({handled, Device}, Hub = #hub{device = Device, core = Core}) ->
    noreply(perform(erx_usb_hub_core:step(handled, Core), Hub));
handle_info({usb, Pipe, Tag, Result}, Hub = #hub{pipe = Pipe, posted = Tag, core = Core}) when Tag =/= none ->
    noreply(perform(erx_usb_hub_core:step({transfer, Result}, Core), Hub#hub{posted = none}));
handle_info(_Stale, Hub) ->
    {noreply, Hub}.

noreply({ok, Hub}) -> {noreply, Hub};
noreply(Stop = {stop, _Reason, _Hub}) -> Stop.

%% The core's actions, in order, answering `{ok, Hub}`, or `{stop, Reason, Hub}`
%% when the last of them is the core's stop.
perform({Core, Actions}, Hub0) ->
    lists:foldl(fun(Action, {ok, Hub}) -> act(Action, Hub) end, {ok, Hub0#hub{core = Core}}, Actions).

act({changed, Set}, Hub = #hub{bus = Bus, device = Device}) ->
    Bus ! {changed, Device, Set, self()},
    {ok, Hub};
act({post, Length}, Hub = #hub{pipe = Pipe}) ->
    Tag = make_ref(),
    ok = erx_usb_pipe:interrupt_in(Pipe, Tag, Length),
    {ok, Hub#hub{posted = Tag}};
act({stop, Reason}, Hub) ->
    {stop, Reason, Hub}.
