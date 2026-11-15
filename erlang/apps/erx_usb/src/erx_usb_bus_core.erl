%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_bus_core).
-moduledoc """
The bus process's pure core: the topology of one controller's bus, its
hubs' ports and the devices on them (docs/design-usb.md, "Ports, hubs and
devices: the bus core" and "Hubs").

step/3 takes one event, the time it is handled at, in milliseconds, and the
state, and answers the actions the bus process performs, in order, and the
next state. Every timer is a deadline in the state; the last action, when
any deadline is pending, is `{deadline, At}`, the earliest of them, and the
process answers it with the event `expired` at or after that time.

**Hubs.** The root hub and every external hub are kept alike: a map of
ports, the set of ports (and `hub`, the hub itself) whose status is still
to be read, the one port operation in flight, the change bits still to be
cleared after a read, and the pid of the hub function whose report is
being handled, to which `{handled, Hub, From}` goes once the set is empty, so a
restarted hub function never takes its predecessor's answer. A hub's port
operations run one at a time, chosen afresh whenever none is in flight:
first the clears of the last read, then powering an `off` port, then
disabling a port given up, then the reset of the port holding the
address-zero turn, then the next status read, which waits until the hub's power-good time has passed. So a hub
has at most one operation and one report in flight however fast it
reports, and nothing is queued but a set of its own ports.

**Ports** are in the states of the design's port table; a state carries
its deadline and, from `enumerating` on, its occupant's reference, so a
port cannot hold a device it is not enumerating or running. A status
read decides by agreement: a connection change, or a status that says
connected on an `empty` port or disconnected on an occupied one, first
detaches the occupant and then moves the port to `settling` or `empty`,
as FreeBSD's `uhub_reattach_port` frees the old child before it reads the
fresh status (sys/dev/usb/usb_hub.c:625-637, release/15.1.0, 95719d8a); a
status that agrees with the state leaves the port as it is.

**Power.** A hub's ports start `off`. The core powers each, one request
at a time, and the hub's power-good time, `bPwrOn2PwrGood` times 2 ms
plus FreeBSD's 20 ms (usb_hub.c:1280-1281, usb.h:124 and 624), runs from
the last one's answer; FreeBSD waits it after each port (usb_hub.c:1512),
and once after the last is enough, since every port's own time started
earlier. The root hub's is FreeBSD's xHCI root hub value, 10 units
(sys/dev/usb/controller/xhci.c:3533).

**The address-zero turn** is not a field: the port that holds it is the
one in `resetting`, `recovering`, `enumerating` before its address is
answered, or `disabling`: a port given up while its device may still be
enabled is disabled at its hub before the turn moves on. The turn goes to the `waiting` port that arrived first only
when no port holds it, so at most one device is in the default state on
the bus, and a port that leaves those states, by any path, a detach of
its hub included, has released it.

**Detach** is one function, detach_device/2: it detaches every device
below a hub first, deepest first, drops each device and hub from the
state and answers `{detach, Ref}` for each, which tells the bus process
to stop the device's functions, free its places and have the controller
drop the reference and tear down its slot. Answers naming a reference or
a hub the state no longer holds are ignored, so a device removed in the
middle of any step leaves nothing behind.

**Enumeration.** At the end of its reset recovery a port's device gets a
reference, `{enable_slot, Ref}` and then `{address, Ref, Params}` with the
route, the root port, the speed and the transaction translator; the
answer to the address releases the turn. The descriptor steps that
follow, 2 to 8 of the design, reach this core as one answer,
`{configured, Ref, Config}` or `{enumeration_failed, Ref, Reason}`; on the
first the port is `running`, `{start, Ref, Functions}` starts the
device's functions, and a hub's configuration adds the hub, its ports
`off`.

Every status word comes from a device and is decoded by erx_usb_hub_core,
which refuses a malformed one; a malformed status, like a failed port
operation, detaches an external hub. The root hub's operations are the
controller process's register accesses and do not fail.
""".

-export([new/1, step/3, ports/1, devices/1]).

-export_type([state/0, event/0, action/0, hub_id/0, ref/0, port_state/0, config/0]).

-include("generated/erx_abi.hrl").

%% FreeBSD's delays (sys/dev/usb/usb.h:117-124): a connected port's power-up
%% delay before its reset, the recovery after a reset, and the time added to a
%% hub's power-good time; the units of bPwrOn2PwrGood (usb.h:624).
-define(POWER_UP_DELAY_MS, 300).
-define(RESET_RECOVERY_MS, 20).
-define(EXTRA_POWER_UP_MS, 20).
-define(POWER_GOOD_UNIT_MS, 2).
%% FreeBSD's xHCI root hub descriptor's bPwrOn2PwrGood (xhci.c:3533).
-define(ROOT_POWER_GOOD_UNITS, 10).
%% The deadline of a port's reset and the interval at which a resetting port's
%% status is read again (docs/design-usb.md, the port-state table; usb_request.c:805-863).
-define(RESET_DEADLINE_MS, 1000).
-define(RESET_POLL_MS, 50).

-doc "A device's reference: fresh for every device the bus ever enumerates.".
-type ref() :: {device, pos_integer()}.

-doc "A hub: the root hub, or an external hub by its device's reference.".
-type hub_id() :: root | ref().

-type port_no() :: 1..255.
-type target() :: port_no() | hub.
-type ms() :: integer().
-type speed() :: erx_usb_claim:speed().

-doc """
A port's state, with its deadline and, while it has one, its occupant. A
resetting port's reset is `to_send` until its hub sends it, `sent` until the
hub answers, then `{poll, At}` until its next status read is due and
`read_queued` until that read is answered; its deadline runs from the send.
`disabling` is a port given up whose hub has yet to answer its disable.
""".
-type port_state() :: off | empty | {settling, ms()} | waiting
                    | {resetting, to_send} | {resetting, ms(), sent | {poll, ms()} | read_queued}
                    | {disabling, term()}
                    | {recovering, ms(), speed()}
                    | {enumerating, ref(), enabling_slot | addressing | configuring}
                    | {running, ref()}
                    | {disabled, term()}.

-type op() :: power_on | get_status | reset | disable | {clear, atom()}.

-doc """
What the descriptor steps answer for a configured device: the functions to
start and, for a hub, its port count, its bPwrOn2PwrGood and whether its
multi-TT interface was selected.
""".
-type config() :: #{functions := [term()],
                    hub := none | #{ports := 1..?ERX_USB_HUB_PORTS_MAX, power_good := byte(),
                                    multi_tt := boolean()}}.

-type event() :: {port_event, port_no()}
               | {changed, hub_id(), erx_usb_hub_core:change_set(), From :: term()}
               | {port_done, hub_id(), target(), ok | {ok, binary()} | {ok, binary(), byte()} | {error, term()}}
               | {slot, ref(), {ok, pos_integer()} | {error, term()}}
               | {addressed, ref(), {ok, pos_integer()} | {error, term()}}
               | {configured, ref(), config()}
               | {enumeration_failed, ref(), term()}
               | expired.

-type address_params() :: #{slot := pos_integer(), root_port := port_no(), route := [port_no()],
                            speed := speed(),
                            tt := none | #{hub_slot := pos_integer(), port := port_no(), multi := boolean()}}.

-type action() :: {port, hub_id(), target(), op()}
                | {handled, hub_id(), From :: term()}
                | {enable_slot, ref()}
                | {address, ref(), address_params()}
                | {start, ref(), [term()]}
                | {detach, ref()}
                | {deadline, ms()}.

-type hub() :: #{parent := root | {hub, full | high}, power_good := ms(),
                 power := powering | {good_at, ms()} | good, multi_tt := boolean(),
                 ports := #{port_no() => port_state()}, pending := ordsets:ordset(target()),
                 op := none | {target(), op()}, clears := [{target(), atom()}], reporter := none | term()}.

-type device() :: #{port := {hub_id(), port_no()}, route := [port_no(), ...], speed := speed(),
                    slot := none | pos_integer(),
                    tt := none | {hub_id(), port_no()}}.

-opaque state() :: #{hubs := #{hub_id() => hub()}, devices := #{ref() => device()},
                     waiting := [{hub_id(), port_no()}], next := ref()}.

-doc "The bus of a controller whose root hub has RootPorts ports, every port `off`.".
-spec new(port_no()) -> state().
new(RootPorts) when is_integer(RootPorts), RootPorts >= 1, RootPorts =< 255 ->
    #{hubs => #{root => hub(root, RootPorts, ?ROOT_POWER_GOOD_UNITS, false)},
      devices => #{}, waiting => [], next => {device, 1}}.

-doc "The actions the bus process performs on Event, handled at Now, and the next state.".
-spec step(event(), ms(), state()) -> {[action()], state()}.
step(Event, Now, State0) ->
    {Actions, State} = event(Event, Now, State0),
    settle(Now, Actions, State).

-doc "Every port's state, by its hub and number, for inspection.".
-spec ports(state()) -> #{{hub_id(), port_no()} => port_state()}.
ports(#{hubs := Hubs}) ->
    maps:from_list([{{Id, N}, Port} || Id := #{ports := Ports} <- Hubs, N := Port <- Ports]).

-doc "Every device the bus holds, by its reference, for inspection.".
-spec devices(state()) -> #{ref() => device()}.
devices(#{devices := Devices}) -> Devices.

%% Events.

event({port_event, N}, _Now, State) ->
    {[], with_hub(root, fun(Hub = #{ports := Ports, pending := P}) when is_map_key(N, Ports) ->
                                Hub#{pending := ordsets:add_element(N, P)};
                           (Hub) ->
                                Hub
                        end, State)};
event({changed, Id, Set, From}, _Now, State) ->
    {[], with_hub(Id, fun(Hub = #{pending := P}) ->
                              Hub#{pending := ordsets:union(P, Set), reporter := From}
                      end, State)};
event({port_done, Id, Target, Result}, Now, State = #{hubs := Hubs}) ->
    case Hubs of
        #{Id := Hub = #{op := {Target, Op}}} ->
            answered(Id, Target, Op, Result, Now, State#{hubs := Hubs#{Id := Hub#{op := none}}});
        #{} ->
            {[], State}
    end;
event({slot, Ref, Result}, _Now, State) ->
    at_step(Ref, enabling_slot, State, fun(Device) -> slot(Ref, Device, Result, State) end);
event({addressed, Ref, Result}, _Now, State) ->
    at_step(Ref, addressing, State, fun(_Device) -> addressed(Ref, Result, State) end);
event({configured, Ref, Config}, _Now, State) ->
    at_step(Ref, configuring, State, fun(Device) -> configured(Ref, Device, Config, State) end);
event({enumeration_failed, Ref, Reason}, _Now, State) ->
    at_step(Ref, configuring, State, fun(_Device) -> fail_device(Ref, Reason, State) end);
event(expired, Now, State = #{hubs := Hubs}) ->
    lists:foldl(fun(Id, Acc) -> expire_hub(Id, Now, Acc) end, {[], State}, lists:sort(maps:keys(Hubs))).

%% Runs Fun on the device Ref when its port is at enumeration Step; an answer for
%% a device gone or at another step is stale and ignored.
at_step(Ref, Step, State = #{devices := Devices}, Fun) ->
    case Devices of
        #{Ref := Device = #{port := {Id, N}}} ->
            case port(Id, N, State) of
                {enumerating, Ref, Step} -> Fun(Device);
                _ -> {[], State}
            end;
        #{} ->
            {[], State}
    end.

slot(Ref, Device0, {ok, Slot}, State = #{devices := Devices}) ->
    Device = Device0#{slot := Slot},
    {[{address, Ref, address_params(Device, State)}],
     set_step(Ref, addressing, State#{devices := Devices#{Ref := Device}})};
slot(Ref, _Device, {error, Reason}, State) ->
    fail_device(Ref, {enable_slot, Reason}, State).

addressed(Ref, {ok, _Address}, State) ->
    {[], set_step(Ref, configuring, State)};
addressed(Ref, {error, Reason}, State) ->
    fail_device(Ref, {address, Reason}, State).

configured(Ref, #{port := {Id, N}, speed := Speed}, Config = #{functions := Functions}, State0) ->
    case {Config, Speed} of
        {#{hub := #{}}, super} ->
            fail_device(Ref, superspeed_hub, State0);
        {#{hub := none}, _} ->
            {[{start, Ref, Functions}], set_port(Id, N, {running, Ref}, State0)};
        {#{hub := #{ports := Ports, power_good := Units, multi_tt := MultiTT}}, _} ->
            State = #{hubs := Hubs} = set_port(Id, N, {running, Ref}, State0),
            Hub = hub({hub, hub_speed(Speed)}, Ports, Units, MultiTT),
            {[{start, Ref, Functions}], State#{hubs := Hubs#{Ref => Hub}}}
    end.

hub_speed(high) -> high;
hub_speed(_LowOrFull) -> full.

hub(Parent, Ports, PowerGoodUnits, MultiTT) ->
    #{parent => Parent, power_good => PowerGoodUnits * ?POWER_GOOD_UNIT_MS + ?EXTRA_POWER_UP_MS,
      power => powering, multi_tt => MultiTT,
      ports => maps:from_keys(lists:seq(1, Ports), off), pending => lists:seq(1, Ports),
      op => none, clears => [], reporter => none}.

%% The answer to a hub's port operation. A port that has moved on since the
%% operation was issued keeps its state.

answered(Id, N, power_on, ok, _Now, State) ->
    {[], update_port(Id, N, fun(off) -> empty; (Other) -> Other end, State)};
answered(Id, N, reset, ok, Now, State) ->
    {[], update_port(Id, N, fun({resetting, At, sent}) -> {resetting, At, {poll, Now + ?RESET_POLL_MS}};
                               (Other) -> Other
                            end, State)};
answered(Id, N, disable, ok, _Now, State) ->
    {[], update_port(Id, N, fun({disabling, Reason}) -> {disabled, Reason}; (Other) -> Other end, State)};
answered(Id, Target, {clear, Change}, ok, _Now, State) ->
    {[], with_hub(Id, fun(Hub = #{clears := [{T, C} | Rest]}) when T =:= Target, C =:= Change ->
                              Hub#{clears := Rest}
                      end, State)};
answered(Id, Target, get_status, Result, Now, State) ->
    case decode(Id, Target, Result, State) of
        {ok, Status = #{changes := Changes}} ->
            Read = with_hub(Id, fun(Hub = #{pending := P}) ->
                                        Hub#{pending := ordsets:del_element(Target, P),
                                             clears := [{Target, C} || C <- Changes]}
                                end, State),
            read(Id, Target, Status, Now, Read);
        {error, Reason} ->
            fail_hub(Id, Target, Reason, State)
    end;
answered(Id, Target, _Op, {error, Reason}, _Now, State) ->
    fail_hub(Id, Target, Reason, State).

decode(_Id, hub, {ok, Words}, _State) ->
    erx_usb_hub_core:hub_status(Words);
decode(root, _N, {ok, Words, SpeedId}, _State) ->
    erx_usb_hub_core:port_status(Words, {root, SpeedId});
decode(Id, _N, {ok, Words}, #{hubs := Hubs}) when Id =/= root ->
    #{Id := #{parent := Parent}} = Hubs,
    erx_usb_hub_core:port_status(Words, Parent);
decode(_Id, _Target, {error, Reason}, _State) ->
    {error, Reason};
decode(_Id, _Target, _Malformed, _State) ->
    {error, malformed_status}.

%% A hub's own status needs nothing beyond clearing its changes; a port's status
%% moves the port as the port table says.
read(_Id, hub, _HubStatus, _Now, State) ->
    {[], State};
read(Id, N, Status = #{connected := Connected}, Now, State) ->
    Port = port(Id, N, State),
    case connection_changed(Status, Port) of
        true ->
            {Detached, Vacated} = vacate(Id, N, State),
            Arrival = case Connected of
                          true -> {settling, Now + ?POWER_UP_DELAY_MS};
                          false -> empty
                      end,
            {Detached, set_port(Id, N, Arrival, Vacated)};
        false ->
            follow(Id, N, Port, Status, Now, State)
    end.

%% A connection change, or a status that disagrees with whether the port holds
%% something: nothing on an `empty` port, something on every other read port.
connection_changed(#{changes := Changes, connected := Connected}, Port) ->
    lists:member(connection, Changes) orelse Connected =/= (Port =/= empty).

%% A running port its hub disabled is given up; a resetting port's read after its
%% reset was answered decides the reset, as usbd_req_reset_port does
%% (usb_request.c:832-844): still resetting, read again in 50 ms; done with the
%% port disabled, given up; done at a speed the controller cannot run, disabled at
%% the hub; otherwise its 20 ms recovery.
follow(Id, N, {running, _Ref}, #{enabled := false}, _Now, State) ->
    disable(Id, N, port_disabled, State);
follow(Id, N, {resetting, At, Phase}, Status, Now, State) when Phase =/= sent ->
    case Status of
        #{reset := true, changes := Changes} ->
            case lists:member(reset, Changes) of
                true -> reset_done(Id, N, Status, Now, State);
                false -> {[], set_port(Id, N, {resetting, At, {poll, Now + ?RESET_POLL_MS}}, State)}
            end;
        #{} ->
            reset_done(Id, N, Status, Now, State)
    end;
follow(_Id, _N, _Port, _Status, _Now, State) ->
    {[], State}.

reset_done(Id, N, #{enabled := false}, _Now, State) ->
    disable(Id, N, reset_disabled, State);
reset_done(Id, N, #{speed := unsupported}, _Now, State) ->
    give_up(Id, N, unsupported_speed, State);
reset_done(Id, N, #{speed := Speed}, Now, State) ->
    {[], set_port(Id, N, {recovering, Now + ?RESET_RECOVERY_MS, Speed}, State)}.

%% Deadlines.

expire_hub(Id, Now, {Actions, State = #{hubs := Hubs}}) ->
    case Hubs of
        #{Id := Hub = #{ports := Ports, power := Power}} ->
            Powered = case Power of
                          {good_at, At} when At =< Now -> Hub#{power := good};
                          _ -> Hub
                      end,
            lists:foldl(fun(N, Acc) -> expire_port(Id, N, maps:get(N, Ports), Now, Acc) end,
                        {Actions, State#{hubs := Hubs#{Id := Powered}}}, lists:sort(maps:keys(Ports)));
        #{} ->
            {Actions, State}
    end.

expire_port(Id, N, {settling, At}, Now, {Actions, State = #{waiting := Waiting}}) when At =< Now ->
    {Actions, set_port(Id, N, waiting, State#{waiting := Waiting ++ [{Id, N}]})};
expire_port(Id, N, {resetting, At, _Phase}, Now, {Actions, State}) when At =< Now ->
    {GivenUp, Next} = give_up(Id, N, reset_timeout, State),
    {Actions ++ GivenUp, Next};
expire_port(Id, N, {resetting, At, {poll, Poll}}, Now, {Actions, State}) when Poll =< Now ->
    Polled = with_hub(Id, fun(Hub = #{pending := P}) -> Hub#{pending := ordsets:add_element(N, P)} end, State),
    {Actions, set_port(Id, N, {resetting, At, read_queued}, Polled)};
expire_port(Id, N, {recovering, At, Speed}, Now, {Actions, State}) when At =< Now ->
    {Enabling, Next} = enumerate(Id, N, Speed, State),
    {Actions ++ Enabling, Next};
expire_port(_Id, _N, _Port, _Now, Acc) ->
    Acc.

%% A device for the port at the end of its reset recovery.
enumerate(Id, N, Speed, State = #{devices := Devices, next := Ref = {device, Next}}) ->
    Device = #{port => {Id, N}, route => route(Id, State) ++ [N], speed => Speed, slot => none,
               tt => translator(Id, N, Speed, State)},
    {[{enable_slot, Ref}],
     set_port(Id, N, {enumerating, Ref, enabling_slot},
              State#{devices := Devices#{Ref => Device}, next := {device, Next + 1}})}.

route(root, _State) -> [];
route(Ref, #{devices := Devices}) -> maps:get(route, maps:get(Ref, Devices)).

%% The high-speed hub port whose transaction translator serves a low- or
%% full-speed device on port N of hub Id: the nearest high-speed hub above it.
translator(_Id, _N, Speed, _State) when Speed =:= high; Speed =:= super ->
    none;
translator(root, _N, _Speed, _State) ->
    none;
translator(Id, N, Speed, State = #{devices := Devices}) ->
    case Devices of
        #{Id := #{speed := high}} -> {Id, N};
        #{Id := #{port := {Above, AboveN}}} -> translator(Above, AboveN, Speed, State)
    end.

address_params(#{route := [RootPort | Tiers], speed := Speed, slot := Slot, tt := TT},
               #{devices := Devices, hubs := Hubs}) ->
    Translator = case TT of
                     none ->
                         none;
                     {HubRef, Port} ->
                         #{slot := HubSlot} = maps:get(HubRef, Devices),
                         #{multi_tt := Multi} = maps:get(HubRef, Hubs),
                         #{hub_slot => HubSlot, port => Port, multi => Multi}
                 end,
    #{slot => Slot, root_port => RootPort, route => Tiers, speed => Speed, tt => Translator}.

%% Failure and detach.

%% A failed or malformed answer on a hub's port: an external hub's control pipe
%% failed, so the hub is detached. The root hub's operations are the controller
%% process's own register accesses, which do not fail; one that does ends the bus
%% process, and its supervisor restarts it with the controller.
fail_hub(root, Target, Reason, _State) ->
    error({root_port_operation_failed, Target, Reason});
fail_hub(Ref, _Target, Reason, State) ->
    fail_device(Ref, {hub, Reason}, State).

fail_device(Ref, Reason, State = #{devices := Devices}) ->
    #{port := {Id, N}} = maps:get(Ref, Devices),
    give_up(Id, N, Reason, State).

%% Port N of hub Id given up while a device on it may still be enabled: its
%% occupant detached, and the port disabled at its hub before it is `disabled`,
%% holding the turn until then, as FreeBSD clears the port's enable on its error
%% path (usb_hub.c:827-832), so a device left in the default state never meets
%% the next port's reset.
give_up(Id, N, Reason, State) ->
    {Detached, Vacated} = vacate(Id, N, State),
    {Detached, set_port(Id, N, {disabling, Reason}, Vacated)}.

%% Port N of hub Id recorded `disabled`: its hub already reports it disabled, or
%% cannot be asked; its occupant detached, the reason kept.
disable(Id, N, Reason, State) ->
    {Detached, Vacated} = vacate(Id, N, State),
    {Detached, set_port(Id, N, {disabled, Reason}, Vacated)}.

vacate(Id, N, State) ->
    case occupant(port(Id, N, State)) of
        [Ref] -> detach_device(Ref, State);
        [] -> {[], State}
    end.

%% Detaches Ref and, when it is a hub, every device below it first, deepest
%% first. The port Ref occupied is left to the caller.
detach_device(Ref, State = #{hubs := Hubs}) ->
    Below = case Hubs of
                #{Ref := #{ports := Ports}} -> [Child || {_N, Port} <- lists:sort(maps:to_list(Ports)),
                                                         Child <- occupant(Port)];
                #{} -> []
            end,
    {Actions, Detached = #{hubs := Left, devices := Devices}} =
        lists:foldl(fun(Child, {Acc, S}) ->
                            {More, Next} = detach_device(Child, S),
                            {Acc ++ More, Next}
                    end, {[], State}, Below),
    {Actions ++ [{detach, Ref}],
     Detached#{hubs := maps:remove(Ref, Left), devices := maps:remove(Ref, Devices)}}.

occupant({enumerating, Ref, _Step}) -> [Ref];
occupant({running, Ref}) -> [Ref];
occupant(_Unoccupied) -> [].

%% After every event: the turn, each hub's next operation and answer, and the
%% earliest deadline.

settle(Now, Actions, State0) ->
    State1 = grant_turn(prune_waiting(State0)),
    {Operations, State} = run_hubs(Now, State1),
    {Actions ++ Operations ++ deadline(State), State}.

%% The arrival order keeps only ports still `waiting`.
prune_waiting(State = #{waiting := Waiting}) ->
    State#{waiting := [{Id, N} || {Id, N} <- Waiting, find_port(Id, N, State) =:= waiting]}.

%% The first waiting port takes the turn when no port holds it; its reset's
%% deadline starts when its hub sends the reset.
grant_turn(State = #{waiting := [{Id, N} | Rest]}) ->
    case lists:any(fun holds_turn/1, maps:values(ports(State))) of
        true -> State;
        false -> set_port(Id, N, {resetting, to_send}, State#{waiting := Rest})
    end;
grant_turn(State) ->
    State.

holds_turn({resetting, to_send}) -> true;
holds_turn({resetting, _At, _Phase}) -> true;
holds_turn({recovering, _At, _Speed}) -> true;
holds_turn({enumerating, _Ref, Step}) -> Step =/= configuring;
holds_turn({disabling, _Reason}) -> true;
holds_turn(_Port) -> false.

run_hubs(Now, State = #{hubs := Hubs}) ->
    lists:foldl(fun(Id, {Acc, S = #{hubs := H}}) ->
                        {More, Hub} = run_hub(Id, maps:get(Id, H), Now),
                        {Acc ++ More, S#{hubs := H#{Id := Hub}}}
                end, {[], State}, lists:sort(maps:keys(Hubs))).

%% A hub with nothing in flight takes its next operation; one whose report has
%% been read and cleared whole answers its reporter.
run_hub(Id, Hub0, Now) ->
    {Operation, Hub1} = case Hub0 of
                            #{op := none} -> next_op(Id, Hub0, Now);
                            #{} -> {[], Hub0}
                        end,
    case Hub1 of
        #{pending := [], clears := [], reporter := From} when From =/= none ->
            {Operation ++ [{handled, Id, From}], Hub1#{reporter := none}};
        #{} ->
            {Operation, Hub1}
    end.

%% A hub's next port operation: the clears of the last read, powering, disabling
%% a port given up, the turn holder's reset, then a status read once powered.
%% A resetting port's reads are queued in `pending` with the hub's other reads,
%% so a report is answered only once they are done as well.
next_op(Id, Hub = #{clears := [{Target, Change} | _]}, _Now) ->
    issue(Id, Target, {clear, Change}, Hub);
next_op(Id, Hub = #{power := powering, ports := Ports, power_good := PowerGood}, Now) ->
    case [N || {N, off} <- lists:sort(maps:to_list(Ports))] of
        [N | _] -> issue(Id, N, power_on, Hub);
        [] -> next_op(Id, Hub#{power := {good_at, Now + PowerGood}}, Now)
    end;
next_op(Id, Hub = #{ports := Ports, pending := Pending, power := Power}, Now) ->
    Sorted = lists:sort(maps:to_list(Ports)),
    case {[N || {N, {disabling, _}} <- Sorted], [N || {N, {resetting, to_send}} <- Sorted], Pending, Power} of
        {[N | _], _, _, _} ->
            issue(Id, N, disable, Hub);
        {[], [N | _], _, _} ->
            issue(Id, N, reset, Hub#{ports := Ports#{N := {resetting, Now + ?RESET_DEADLINE_MS, sent}}});
        {[], [], [Target | _], good} ->
            issue(Id, Target, get_status, Hub);
        {[], [], _, _} ->
            {[], Hub}
    end.

issue(Id, Target, Op, Hub) ->
    {[{port, Id, Target, Op}], Hub#{op := {Target, Op}}}.

deadline(#{hubs := Hubs}) ->
    case [At || #{ports := Ports, power := Power} <- maps:values(Hubs),
                At <- [A || {good_at, A} <- [Power]] ++ lists:flatmap(fun port_deadlines/1, maps:values(Ports))] of
        [] -> [];
        Deadlines -> [{deadline, lists:min(Deadlines)}]
    end.

port_deadlines({settling, At}) -> [At];
port_deadlines({resetting, At, {poll, Poll}}) -> [At, Poll];
port_deadlines({resetting, At, _Phase}) -> [At];
port_deadlines({recovering, At, _Speed}) -> [At];
port_deadlines(_Port) -> [].

%% State access.

port(Id, N, #{hubs := Hubs}) -> maps:get(N, maps:get(ports, maps:get(Id, Hubs))).

find_port(Id, N, #{hubs := Hubs}) ->
    case Hubs of
        #{Id := #{ports := #{N := Port}}} -> Port;
        #{} -> none
    end.

set_port(Id, N, Port, State) ->
    update_port(Id, N, fun(_Old) -> Port end, State).

update_port(Id, N, Fun, State) ->
    with_hub(Id, fun(Hub = #{ports := Ports = #{N := Old}}) -> Hub#{ports := Ports#{N := Fun(Old)}} end, State).

set_step(Ref, Step, State = #{devices := Devices}) ->
    #{port := {Id, N}} = maps:get(Ref, Devices),
    set_port(Id, N, {enumerating, Ref, Step}, State).

%% Applies Fun to hub Id; a hub the state no longer holds is left alone, since
%% what names it is stale.
with_hub(Id, Fun, State = #{hubs := Hubs}) ->
    case Hubs of
        #{Id := Hub} -> State#{hubs := Hubs#{Id := Fun(Hub)}};
        #{} -> State
    end.
