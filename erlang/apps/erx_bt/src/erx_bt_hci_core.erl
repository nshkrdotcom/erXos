%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_hci_core).
-moduledoc """
The pure core of the controller process, `erx_bt_hci` (docs/design-bluetooth.md, "One
owner, one step", "The bring-up" and "Commands and data credits"). `step/2` takes one
input and the state and returns the actions the process performs and the next state, or
`{stop, Reason}`, after which the process ends and its group's restart resets the line.

**The bring-up** is a line of steps fixed by `new/1`: reset the line, `HCI_Reset`,
identify, the patch where the configuration names one (its own reset and identify after
it), the buffers, the configuration, then `ready`. Each command step waits for its
Command Complete with status success; any other answer, or none within
`bt_command_timeout_ms`, stops with the step and the status. The patched steps are
distinct from the first ones, so the bring-up patches at most once.

**One command in flight**: a command is written only while the slot is empty and the
controller's last `Num_HCI_Command_Packets` is at least one (Part E, 4.4). Command
Complete or Command Status empties the slot; one with opcode 0 only updates the count,
and one naming another opcode stops.

**ACL credits** (Part E, 4.1.1): each live handle counts its packets in flight, and the
free credits are the controller's buffer count less their sum, so a completion can never
grow them: one naming a handle that is not live, or more packets than the handle has in
flight, stops. Disconnection Complete returns all of a handle's (4.2). Each link may hold
at most its share, the buffers divided by the connection limit.

**The writer** is given one item at a time, the next only after `written`, so what waits
for the line is the command slot and the credited packets, whatever the controller does.

**Advertising** is on exactly while connections are below the limit: the controller
stops it when a connection completes, and the core enables it again whenever the slot is
free and connections are below the limit.

Inputs and actions are terms; the process does the I/O and keeps the timers, each
answered by `{timeout, Token}`, a stale token being ignored. The patch arrives as
records already read whole by `erx_bt_patch` (a later slice): this core sends what it is
given.
""".

-include("generated/erx_abi.hrl").

-export([new/1, step/2, facts/1]).
-export_type([config/0, input/0, action/0, core/0]).

-type handle() :: 0..16#FFF.
-type token() :: non_neg_integer().
-type config() :: #{connections := 1..?ERX_BT_CONNECTIONS_MAX, address := <<_:48>>,
                    advertising_data := binary(), scan_response_data := binary(),
                    patch := none | #{manufacturer := 0..16#FFFF, records := [{0..16#FFFF, binary()}]}}.
-type input() :: start | line_ready | written | {timeout, token()}
               | {event, erx_hci:event()}
               | {acl, handle(), 0..3, 0..3, binary()}
               | {send, handle(), 0..3, binary()}
               | {disconnect, handle(), byte()}.
-type action() :: line_reset | {write, binary()} | {timer, token(), pos_integer()}
                | {ready, map()} | {link_up, handle(), map()} | {link_down, handle()}
                | {to_link, handle(), term()} | {busy, handle()}.

%% A bring-up step: reset the line, send a command under a label, or wait.
-type step() :: line_reset | {command, term(), erx_hci:command()} | {wait, pos_integer()}.

-record(core, {
    limit :: 1..?ERX_BT_CONNECTIONS_MAX,
    manufacturer :: none | 0..16#FFFF,
    plan :: [step()],                          % the bring-up steps left; [] once ready
    stage = bringup :: bringup | ready,
    waiting = none :: none | line | {timer, token()},
    slot = idle :: idle | {Label :: term(), erx_hci:command(), Opcode :: 0..16#FFFF, token()},
    allowed = 1 :: byte(),                     % Num_HCI_Command_Packets
    writer = idle :: idle | busy,
    out = [] :: [{command | handle(), binary()}],  % items for the writer, in order, each with its owner
    credits = 0 :: 0..?ERX_BT_ACL_CREDITS_MAX,
    acl_tx_max = 0 :: 0..16#FFFF,
    links = #{} :: #{handle() => non_neg_integer()},  % packets in flight per live handle
    advertising = false :: boolean(),
    disconnects = [] :: [{handle(), byte()}],
    token = 0 :: token(),
    facts = #{} :: map(),
    dropped = 0 :: non_neg_integer()
}).
-opaque core() :: #core{}.

-doc "The state before `start`, with the bring-up's steps fixed from the configuration.".
-spec new(config()) -> core().
new(#{connections := Limit, patch := Patch} = Config) when Limit >= 1, Limit =< ?ERX_BT_CONNECTIONS_MAX ->
    Manufacturer = case Patch of none -> none; #{manufacturer := M} -> M end,
    #core{limit = Limit, manufacturer = Manufacturer, plan = plan(Config)}.

plan(#{address := Address, advertising_data := AdvertisingData, scan_response_data := ScanData,
       patch := Patch}) ->
    Interval = ?ERX_BT_ADVERTISING_INTERVAL_US div ?ERX_HCI_ADVERTISING_INTERVAL_UNIT_US,
    [line_reset, {command, reset, reset} | identify(first)] ++ patch(Patch) ++
        [{command, buffers, le_read_buffer_size},
         {command, host_buffer_size, {host_buffer_size, ?ERX_BT_ACL_RX_MAX, ?ERX_BT_HOST_ACL_PACKETS}},
         {command, event_mask, {set_event_mask, mask(?ERX_HCI_EVENT_MASK_BIT_MEMBERS)}},
         {command, le_event_mask, {le_set_event_mask, mask(?ERX_HCI_LE_EVENT_MASK_BIT_MEMBERS)}},
         {command, random_address, {le_set_random_address, Address}},
         {command, advertising_parameters, {le_set_advertising_parameters, Interval}},
         {command, advertising_data, {le_set_advertising_data, AdvertisingData}},
         {command, scan_response_data, {le_set_scan_response_data, ScanData}}].

%% Identify (design step 3); the second run, after the patch, has labels of its own.
identify(Run) ->
    [{command, {Run, Name}, Name} || Name <- [read_local_version, read_local_commands, le_read_features, read_bd_addr]].

%% The patch (design step 4): the download command and its wait, each record, the launch
%% wait, then HCI_Reset and identify again.
patch(none) -> [];
patch(#{records := Records}) ->
    [{command, minidriver, {vendor, ?ERX_BT_PATCH_DOWNLOAD_MINIDRIVER, <<>>}}, {wait, ?ERX_BT_PATCH_MINIDRIVER_MS}] ++
        [{command, {patch_record, N}, {vendor, Opcode, Parameters}}
         || {N, {Opcode, Parameters}} <- lists:enumerate(Records)] ++
        [{wait, ?ERX_BT_PATCH_LAUNCH_MS}, {command, patched_reset, reset} | identify(patched)].

mask(Members) -> lists:foldl(fun({_Event, Bit}, Mask) -> Mask bor (1 bsl Bit) end, 0, Members).

-doc """
For `/proc/bt`: what the bring-up read from the controller, the events dropped, each
live handle's packets in flight, the free credits and whether advertising is on.
""".
-spec facts(core()) -> map().
facts(#core{facts = Facts, dropped = Dropped, links = Links, advertising = Advertising} = Core) ->
    Facts#{dropped => Dropped, links => Links, free => free(Core), advertising => Advertising}.

-doc "One input: the actions to perform, in order, and the next state; or the reason to stop.".
-spec step(input(), core()) -> {ok, [action()], core()} | {stop, term()}.
step(Input, Core) ->
    try
        {Actions, Next} = input(Input, Core),
        {More, Pumped} = pump(Next),
        {ok, Actions ++ More, Pumped}
    catch
        throw:{stop, Reason} -> {stop, Reason}
    end.

stop(Reason) -> throw({stop, Reason}).

input(start, #core{plan = [line_reset | Plan]} = Core) ->
    {[line_reset], Core#core{plan = Plan, waiting = line}};
input(line_ready, #core{waiting = line} = Core) ->
    {[], Core#core{waiting = none}};
input(written, #core{writer = busy} = Core) ->
    {[], Core#core{writer = idle}};
input({timeout, Token}, #core{slot = {Label, _, _, Token}}) ->
    stop({command_timeout, Label});
input({timeout, Token}, #core{waiting = {timer, Token}} = Core) ->
    {[], Core#core{waiting = none}};
input({timeout, _Stale}, Core) ->
    {[], Core};
input({event, Event}, Core) ->
    event(Event, Core);
input({acl, Handle, Boundary, _Broadcast, Data}, #core{links = Links} = Core) ->
    case is_map_key(Handle, Links) of
        true -> {[{to_link, Handle, {acl, Boundary, Data}}], Core};
        false -> {[], dropped(Core)}
    end;
input({send, Handle, Boundary, Data}, #core{links = Links} = Core) ->
    case Links of
        #{Handle := InFlight} ->
            case InFlight < share(Core) andalso free(Core) > 0 of
                true -> {[], Core#core{out = Core#core.out ++ [{Handle, erx_h4:acl(Handle, Boundary, Data)}],
                                       links = Links#{Handle := InFlight + 1}}};
                false -> {[{busy, Handle}], Core}
            end;
        #{} -> {[], Core}
    end;
input({disconnect, Handle, Reason}, #core{links = Links, disconnects = Pending} = Core) ->
    case is_map_key(Handle, Links) andalso not lists:keymember(Handle, 1, Pending) of
        true -> {[], Core#core{disconnects = Pending ++ [{Handle, Reason}]}};
        false -> {[], Core}
    end;
input(Input, _Core) ->
    stop({unexpected_input, Input}).

%% The credits no live handle holds, and a link's share of all of them.
free(#core{credits = Credits, links = Links}) -> Credits - lists:sum(maps:values(Links)).

share(#core{credits = Credits, limit = Limit}) -> max(1, Credits div Limit).

dropped(#core{dropped = Dropped} = Core) -> Core#core{dropped = Dropped + 1}.

%% The events of Part E, 7.7, as erx_hci decodes them.
event({command_complete, Allowed, Opcode, Return}, Core) ->
    answer(Opcode, {complete, Return}, Core#core{allowed = Allowed});
event({command_status, Status, Allowed, Opcode}, Core) ->
    answer(Opcode, {status, Status}, Core#core{allowed = Allowed});
event({hardware_error, Code}, _Core) ->
    stop({hardware_error, Code});
event({number_of_completed_packets, Pairs}, #core{links = Links} = Core) ->
    {[], Core#core{links = lists:foldl(fun complete/2, Links, Pairs)}};
event({le_connection_complete, ?ERX_HCI_STATUS_SUCCESS, Handle, Info}, Core) ->
    connected(Handle, Info, Core);
event({le_connection_complete, _Failed, _Handle, _Info}, Core) ->
    {[], Core};
event({disconnection_complete, ?ERX_HCI_STATUS_SUCCESS, Handle, _Reason}, #core{links = Links} = Core) ->
    case is_map_key(Handle, Links) of
        true ->
            %% A packet still waiting for the writer is dropped with its handle, which the
            %% controller may give the next peer.
            {[{link_down, Handle}], Core#core{links = maps:remove(Handle, Links),
                                              out = [Item || {Owner, _} = Item <- Core#core.out, Owner =/= Handle],
                                              disconnects = lists:keydelete(Handle, 1, Core#core.disconnects)}};
        false ->
            {[], dropped(Core)}
    end;
event({Kind, _Status, Handle} = Event, Core) when Kind =:= encryption_key_refresh_complete;
                                                   Kind =:= le_connection_update_complete ->
    to_link(Handle, Event, Core);
event({encryption_change, _Status, Handle, _Enabled} = Event, Core) ->
    to_link(Handle, Event, Core);
event({le_long_term_key_request, Handle, _Random, _Ediv} = Event, Core) ->
    to_link(Handle, Event, Core);
event({disconnection_complete, _Failed, _Handle, _Reason}, Core) ->
    {[], Core};
event({unknown, _Code}, Core) ->
    {[], dropped(Core)};
event(malformed, _Core) ->
    stop(malformed_event).

to_link(Handle, Event, #core{links = Links} = Core) ->
    case is_map_key(Handle, Links) of
        true -> {[{to_link, Handle, Event}], Core};
        false -> {[], dropped(Core)}
    end.

%% A completion returns a live handle's packets, never more than it has in flight.
complete({Handle, Count}, Links) ->
    case Links of
        #{Handle := InFlight} when Count =< InFlight -> Links#{Handle := InFlight - Count};
        #{Handle := _} -> stop({completion_beyond_in_flight, Handle, Count});
        #{} -> stop({completion_for_dead_handle, Handle})
    end.

%% A connection, which ends the controller's advertising (Part E, 7.8.9).
connected(Handle, _Info, #core{stage = bringup}) ->
    stop({connection_during_bringup, Handle});
connected(Handle, _Info, #core{links = Links}) when is_map_key(Handle, Links) ->
    stop({duplicate_handle, Handle});
connected(Handle, _Info, #core{links = Links, limit = Limit}) when map_size(Links) >= Limit ->
    stop({connection_beyond_limit, Handle});
connected(Handle, Info, #core{links = Links, acl_tx_max = TxMax} = Core) ->
    {[{link_up, Handle, Info#{acl_tx_max => TxMax, share => share(Core)}}],
     Core#core{links = Links#{Handle => 0}, advertising = false}}.

%% Command Complete or Status for the command in the slot; opcode 0 only updates the
%% count (Part E, 4.4).
answer(0, _Answer, Core) ->
    {[], Core};
answer(Opcode, Answer, #core{slot = {Label, Command, Opcode, _}} = Core) ->
    answered(Label, Command, Answer, Core#core{slot = idle});
answer(Opcode, _Answer, _Core) ->
    stop({answer_to_other_command, Opcode}).

%% A ready link's disconnect is answered by Command Status; a failure means the
%% handle has already gone, which Disconnection Complete reports or has reported.
answered({disconnect, _Handle}, _Command, {status, _}, Core) ->
    {[], Core};
answered(advertise, _Command, {complete, <<?ERX_HCI_STATUS_SUCCESS>>}, Core) ->
    {[], Core#core{advertising = true}};
answered(Label, _Command, {status, Status}, _Core) ->
    stop({step_failed, Label, {command_status, Status}});
answered(Label, Command, {complete, Return}, Core) ->
    case erx_hci:return(name(Command), Return) of
        {ok, Value} -> bringup(Label, Value, Core);
        {failed, Status} -> stop({step_failed, Label, Status});
        malformed -> stop({step_failed, Label, malformed})
    end.

name({vendor, _, _}) -> vendor;
name(Command) when is_atom(Command) -> Command;
name(Command) -> element(1, Command).

%% What a bring-up step's answer decides.
bringup({first, read_local_version}, #{company := Company}, #core{manufacturer = Manufacturer})
  when Manufacturer =/= none, Company =/= Manufacturer ->
    stop({patch_for_other_controller, Company});
bringup({_Run, Name}, Value, #core{facts = Facts} = Core) when Name =:= read_local_version;
                                                               Name =:= read_local_commands;
                                                               Name =:= le_read_features;
                                                               Name =:= read_bd_addr ->
    {[], Core#core{facts = Facts#{Name => Value}}};
%% LE Read Buffer Size: a count of 0 means LE shares the BR/EDR buffers, which Read
%% Buffer Size gives (Part E, 4.1.1, 7.8.2).
bringup(buffers, {_Length, 0}, #core{plan = Plan} = Core) ->
    {[], Core#core{plan = [{command, shared_buffers, read_buffer_size} | Plan]}};
bringup(Label, {Length, Packets}, Core) when Label =:= buffers; Label =:= shared_buffers ->
    case Length >= ?ERX_HCI_LE_ACL_LENGTH_MIN andalso Packets > 0 of
        true -> {[], Core#core{credits = min(Packets, ?ERX_BT_ACL_CREDITS_MAX), acl_tx_max = Length}};
        false -> stop({step_failed, Label, {buffers, Length, Packets}})
    end;
bringup(_Label, _Value, Core) ->
    {[], Core}.

%% After every input: the next bring-up step or ready-state command, then the writer's
%% next item.
pump(Core) ->
    {Commands, Next} = next_command(Core),
    {Writes, Written} = feed(Next),
    {Commands ++ Writes, Written}.

next_command(#core{stage = bringup, slot = idle, waiting = none} = Core) ->
    case Core#core.plan of
        [{command, Label, Command} | Plan] when Core#core.allowed > 0 -> issue(Label, Command, Core#core{plan = Plan});
        [{command, _, _} | _] -> {[], Core};
        [{wait, Milliseconds} | Plan] ->
            Token = Core#core.token + 1,
            {[{timer, Token, Milliseconds}], Core#core{plan = Plan, waiting = {timer, Token}, token = Token}};
        [] ->
            {More, Ready} = next_command(Core#core{stage = ready}),
            {[{ready, facts(Core)} | More], Ready}
    end;
next_command(#core{stage = ready, slot = idle, allowed = Allowed} = Core) when Allowed > 0 ->
    case Core#core.disconnects of
        [{Handle, Reason} | Rest] ->
            issue({disconnect, Handle}, {disconnect, Handle, Reason}, Core#core{disconnects = Rest});
        [] when not Core#core.advertising, map_size(Core#core.links) < Core#core.limit ->
            issue(advertise, {le_set_advertising_enable, true}, Core);
        [] ->
            {[], Core}
    end;
next_command(Core) ->
    {[], Core}.

%% A command into the slot and onto the writer's list, with its deadline.
issue(Label, Command, #core{token = Token0, allowed = Allowed, out = Out} = Core) ->
    {Opcode, Parameters} = erx_hci:command(Command),
    Token = Token0 + 1,
    {[{timer, Token, ?ERX_BT_COMMAND_TIMEOUT_MS}],
     Core#core{slot = {Label, Command, Opcode, Token}, token = Token, allowed = Allowed - 1,
               out = Out ++ [{command, erx_h4:command(Opcode, Parameters)}]}}.

feed(#core{writer = idle, out = [{_Owner, Item} | Out]} = Core) ->
    {[{write, Item}], Core#core{writer = busy, out = Out}};
feed(Core) ->
    {[], Core}.
