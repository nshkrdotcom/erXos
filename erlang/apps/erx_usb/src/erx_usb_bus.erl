%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_bus).
-moduledoc """
The bus process (docs/design-usb.md, "The process tree" and "Ports, hubs
and devices: the bus core"): the effects around erx_usb_bus_core for one
controller's bus. It feeds the core one event at a time and performs the
actions it answers, in order; it decides nothing the core can.

**Its siblings.** It runs under erx_usb_bus_sup beside the controller
process and the function supervisor, and finds both among its
supervisor's children once it has started. It attaches to the controller
(erx_usb_bus_link) and holds no core until the controller answers its
root hub's port count; then the core's first step powers the root ports.

**What it performs.** Root-hub operations, enumeration requests, pipe
resets and detaches go to the controller as the core makes them; an
external hub's port operation goes as a control request on that hub's EP0,
spelled by erx_usb_bus_core:hub_request/2, whose answer comes back as the
operation's by hub_answer/2. `{handled, Hub, From}` goes to the hub
function From alone as `{handled, Hub}`. The core's one deadline is one
timer, replaced at every step, and its expiry is taken only from the
timer last set. A port given up, or an over-current change, is logged.

**Function instances.** `{start, Ref, Functions}` starts each function
under the function supervisor, its driver's start_link/1 given the bus,
the device's reference, its claimed function, its run number and a pipe
for each of its claimed pipes alone (erx_usb_pipe), and for a hub its
port count. Each instance is monitored and kept by its pid with its
device, interface and run number, so the run number goes back to the core
with the instance that has it, never with whatever instance runs when the
message is read: a hub function's report, `{changed, Hub, Set, Pid}`, is
taken only from a live instance of hub Hub, and passed on with that
instance's run number, and the core takes every other as stale.
An instance's end reaches the core at least once: from its monitor when
its process ends, however it ends, and at once when its start fails.

**Detach.** `{detach, Ref}` stops every instance of device Ref, dropping
its monitor first, so a detached device's functions send no end, and then
tells the controller, which drops the reference and tears its slot down;
the core gives a hub's detaches deepest first, so the devices below a hub
lose their functions before it does.
""".
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

-type instance() :: {erx_usb_bus_core:ref(), Interface :: byte(), erx_usb_bus_core:run_no(), reference()}.

-record(bus, {sup :: pid(),
              controller = none :: none | pid(),
              functions = none :: none | pid(),
              core = none :: none | erx_usb_bus_core:state(),
              timer = none :: none | reference(),
              instances = #{} :: #{pid() => instance()}}).

-doc "Starts the bus process of the bus group Sup, linked to the caller.".
-spec start_link(pid()) -> {ok, pid()}.
start_link(Sup) ->
    gen_server:start_link(?MODULE, Sup, []).

-doc false.
init(Sup) ->
    {ok, #bus{sup = Sup}, {continue, siblings}}.

%% The supervisor answers only once it has started every child, so its children
%% are read after init/1 has returned, never from inside it.
-doc false.
handle_continue(siblings, Bus = #bus{sup = Sup}) ->
    Children = supervisor:which_children(Sup),
    {controller, Controller, _, _} = lists:keyfind(controller, 1, Children),
    {functions, Functions, _, _} = lists:keyfind(functions, 1, Children),
    ok = erx_usb_bus_link:attach(Controller),
    {noreply, Bus#bus{controller = Controller, functions = Functions}}.

-doc false.
handle_call(_Request, _From, Bus) ->
    {reply, {error, unsupported}, Bus}.

-doc false.
handle_cast(_Request, Bus) ->
    {noreply, Bus}.

-doc false.
handle_info({changed, Hub, Set, Pid}, Bus = #bus{instances = Instances}) when is_pid(Pid) ->
    case Instances of
        #{Pid := {Hub, _Interface, Run, _Monitor}} -> {noreply, handle({changed, Hub, Set, Run, Pid}, Bus)};
        #{} -> {noreply, Bus}
    end;
handle_info({'DOWN', Monitor, process, Pid, _Reason}, Bus = #bus{instances = Instances}) ->
    case Instances of
        #{Pid := {Ref, Interface, Run, Monitor}} ->
            {noreply, handle({function_ended, Ref, Interface, Run}, Bus#bus{instances = maps:remove(Pid, Instances)})};
        #{} ->
            {noreply, Bus}
    end;
handle_info({timeout, Timer, expired}, Bus = #bus{timer = Timer}) when Timer =/= none ->
    {noreply, handle(expired, Bus#bus{timer = none})};
handle_info(Message, Bus) ->
    {noreply, from_controller(erx_usb_bus_link:from_controller(Message), Bus)}.

%% The controller's messages: its root hub's port count, once, starts the core;
%% an external hub's port operation answers as a control request tagged with it.
from_controller({ok, {root_ports, Ports}}, Bus = #bus{core = none}) ->
    handle(expired, Bus#bus{core = erx_usb_bus_core:new(Ports)});
from_controller({ok, {control_done, Hub, {port, Target, Op}, Result}}, Bus = #bus{core = Core}) when Core =/= none ->
    handle({port_done, Hub, Target, erx_usb_bus_core:hub_answer(Op, Result)}, Bus);
from_controller({ok, {root_ports, _Ports}}, Bus) ->
    Bus;
from_controller({ok, Event}, Bus = #bus{core = Core}) when Core =/= none ->
    handle(Event, Bus);
from_controller(_NotOurs, Bus) ->
    Bus.

%% One event through the core, its actions performed in order; an instance whose
%% start failed ends after them, each end through the core in turn.
handle(Event, Bus0 = #bus{core = Core0}) ->
    {Core, Actions} = erx_usb_bus_core:step(Event, erlang:monotonic_time(millisecond), Core0),
    {Bus, Ended} = lists:foldl(fun perform/2, {cancel_timer(Bus0#bus{core = Core}), []}, Actions),
    lists:foldl(fun handle/2, Bus, lists:reverse(Ended)).

cancel_timer(Bus = #bus{timer = none}) ->
    Bus;
cancel_timer(Bus = #bus{timer = Timer}) ->
    _ = erlang:cancel_timer(Timer),
    Bus#bus{timer = none}.

perform(Action = {port, root, _Target, _Op}, Acc) ->
    request(Action, Acc);
perform({port, Hub, Target, Op}, Acc) ->
    {Setup, Data} = erx_usb_bus_core:hub_request(Target, Op),
    request({control, Hub, {port, Target, Op}, Setup, Data}, Acc);
perform(Action = {enable_slot, _Ref, _Step}, Acc) ->
    request(Action, Acc);
perform(Action = {address, _Ref, _Step, _Params}, Acc) ->
    request(Action, Acc);
perform(Action = {control, _Ref, _Step, _Setup, _Data}, Acc) ->
    request(Action, Acc);
perform(Action = {evaluate_context, _Ref, _Step, _Context}, Acc) ->
    request(Action, Acc);
perform(Action = {configure_endpoints, _Ref, _Step, _Endpoints}, Acc) ->
    request(Action, Acc);
perform(Action = {reset_pipe, _Ref, _Interface, _Address}, Acc) ->
    request(Action, Acc);
perform({handled, Hub, From}, Acc) ->
    From ! {handled, Hub},
    Acc;
perform({start, Ref, Functions}, Acc) ->
    lists:foldl(fun({Function, Run}, A) -> start(Ref, Function, Run, A) end, Acc, Functions);
perform({detach, Ref}, {Bus, Ended}) ->
    request({detach, Ref}, {stop_instances(Ref, Bus), Ended});
perform({log, Hub, Port, What}, Acc) ->
    logger:notice(#{usb => port, hub => Hub, port => Port, what => What}),
    Acc;
perform({deadline, At}, {Bus, Ended}) ->
    {Bus#bus{timer = erlang:start_timer(At, self(), expired, [{abs, true}])}, Ended}.

request(Request, Acc = {#bus{controller = Controller}, _Ended}) ->
    ok = erx_usb_bus_link:request(Controller, Request),
    Acc.

%% Instance Run of Function on device Ref, monitored and kept by its pid, or its
%% end, to follow the step's actions, when its start fails.
start(Ref, Function = #{driver := Driver, interface := Interface}, Run, {Bus, Ended}) ->
    #bus{functions = Functions, instances = Instances} = Bus,
    case supervisor:start_child(Functions, [Driver, args(Ref, Function, Run, Bus)]) of
        {ok, Pid} when is_pid(Pid) ->
            Instance = {Ref, Interface, Run, monitor(process, Pid)},
            {Bus#bus{instances = Instances#{Pid => Instance}}, Ended};
        _Failed ->
            {Bus, [{function_ended, Ref, Interface, Run} | Ended]}
    end.

%% A function's start arguments: its own pipes alone, and for a hub its port count.
args(Ref, Function = #{pipes := Pipes}, Run, #bus{controller = Controller, core = Core}) ->
    Args = #{bus => self(), device => Ref, function => Function, run => Run,
             pipes => [erx_usb_pipe:new(Controller, Ref, Address) || #{address := Address} <- Pipes]},
    case erx_usb_bus_core:devices(Core) of
        #{Ref := #{hub := #{ports := Ports}}} -> Args#{ports => Ports};
        #{Ref := #{hub := none}} -> Args
    end.

stop_instances(Ref, Bus = #bus{functions = Functions, instances = Instances}) ->
    Stopped = maps:filter(fun(_Pid, {R, _Interface, _Run, _Monitor}) -> R =:= Ref end, Instances),
    maps:foreach(fun(Pid, {_Ref, _Interface, _Run, Monitor}) ->
                         demonitor(Monitor, [flush]),
                         _ = supervisor:terminate_child(Functions, Pid)
                 end, Stopped),
    Bus#bus{instances = maps:without(maps:keys(Stopped), Instances)}.
