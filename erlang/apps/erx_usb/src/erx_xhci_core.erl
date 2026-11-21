%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_xhci_core).
-moduledoc """
The controller process's pure core (docs/design-usb.md, "The controller
process" and "Transfers and pipes"): the commands it runs, every pipe's
lifecycle and the transfers in flight with their requesters.

step/3 takes one event, the time it is handled at, in milliseconds, and the
state, and answers the next state and the actions the controller process
performs, in order: `{command, Tag, Command}` and `{transfer, Pipe, Tag,
Transfer}` post to the device NIF, `{reply, From, Answer}` answers a caller,
and `{fail, Reason}` ends the process, whose restart resets the controller;
a step that fails answers that action alone, so nothing after it is posted
and a held interrupt is not acknowledged.
The process feeds back every completion the NIF returns, `{complete, Tag,
Code, Extra}`, and every post the NIF refuses, `{refused, Tag, Reason}`.
Tags are the core's: the lowest number no post in flight holds.

**Registers.** The core reads and writes the controller's registers only
through actions: `{read, Registers}`, which the process answers with the
event `{read, Words}`, a map of each register named to the word it read,
and `{write, Register, Word}`. A register is named abstractly, register/0,
and the process maps each name to the device NIF's. A write that sets a
write-one-to-clear or write-one-to-act bit beside bits the write must keep
is always modify/4 of the word just read, the read's preserved bits kept,
the field written cleared and the bits meant set, with the preserve mask
generated from hw/svd/xhci/xhci.svd, so no change bit is cleared and no
port disabled by writing back what was read.

**Start**, in the design's order, one phase at a time: `{start, Bound}`,
Bound saying which extended capabilities the NIF bound at open, reads the
capability registers and the supported-protocol capabilities, and
capabilities/2 decodes them; a controller without 4 KiB pages fails, as
FreeBSD refuses it (xhci.c:546-549). With a legacy support capability the
core then writes its OS-owned semaphore and polls the BIOS-owned one every
`xhci_poll_ms` until it reads clear, going on after `xhci_bios_handoff_ms`
as FreeBSD does (xhci_pci.c:529-557), with `{log, bios_handoff_timeout}`.
Then `negotiate`, which the process answers with `{negotiated, Result}`;
`{error, ebusy}` calls it again `xhci_poll_ms` later, and an install still
busy `xhci_install_deadline_ms` after its first call fails the controller
without being called again. Its `ok` starts the bus with the root hub's port count,
`{start_bus, Ports}`, and the controller runs.

**Root ports.** The bus process's root-hub operation `{port, From, Port,
Op}` reads the port's PORTSC and answers from it: `get_status` with the
USB 2 status and change words and the PORTSC speed ID; `power_on`, `reset`,
`disable` and `{clear, Change}` by writing PORTSC's port power, port reset,
port enable (whose 1 disables) or the change bits behind Change, each with
modify/4. A clear writes only those of Change's bits that the port's last
`get_status` reported, so a change that set after that read, which the bus
core has not seen, stays set for its next read. A port outside the
controller's port count is answered `{error, badarg}`, and a port event
that names one fails the controller as a malformed event, since the
controller wrote it. Every PORTSC change bit stands behind one USB 2 change name, so a
port's changes can all be cleared and it raises its next event (xHCI
4.19.2, p. 322): the link state change behind `suspend`, as FreeBSD's
C_PORT_SUSPEND clears it (xhci.c:3461-3463); the warm reset change behind
`reset`, both a reset's end (FreeBSD's usb_hub.c:1091-1103); and the
configuration error change behind `enabled`, a link that failed to come
up. No PORTSC is written before the controller runs (5.4.8, p. 405): an
operation before then is answered `{error, halted}`.

**Events.** An `interrupt` before the controller runs, whose install has
not yet opened its interrupt, is held unacknowledged: a line the firmware
left asserted, as the VL805's INTx may be, stays masked until the
install has reset the controller, and the one `ack` it is owed goes out
with `{start_bus, Ports}`. A controller that fails first does not
acknowledge it: the process's exit unbinds the line, which masks it. Events
are never polled, but a running controller's status is: USBSTS is read on
every interrupt and, at `expired`, every `xhci_status_interval_ms` whether
interrupts come or not, and a host system error (4.10.2.6, pp. 200-201), a
host controller error (4.24.1, p. 358) or a halt fails the controller
(5.4.2, pp. 397-399); an all-ones read, from a function that left the bus,
shows a host system error, and a word that is not an integer fails it as
an unexpected read. USBCMD.HSEE stays clear, since it signals only on the
bus, through SERR#, which the PCIe domain owns. An interrupt of a running
controller reads USBSTS and IMAN, and when neither error nor halt shows,
the core clears USBSTS's event interrupt and IMAN's interrupt pending,
both write-one-to-clear (5.4.2, pp. 397-399; 5.5.2.1, pp.
425-426), and asks to `complete`. The process answers each call of
complete/2 with `{completed, Result}`: each transfer's or command's
completion is handled as `{complete, Tag, Code, Extra}` and each port's
event goes to the bus process as `{port_event, Port}`; a non-empty batch
asks to `complete` again, and an empty one to `ack` the line, so a
level-triggered line is left deasserted (4.17.2, p. 296). A pass stops
once it has read `xhci_events_per_interrupt` events, two wraps of the
event ring, where FreeBSD's poll stops too (xhci.c:1138, :1167-1176), and
acknowledges the line; what is left waits for the next pass. The process
feeds the core no `interrupt` between a `complete` and its `{completed,
Result}`, so passes never overlap.

**Decoders.** completion/1 names a completion code from
abi/formats/xhci.txt; command_answer/3 and transfer_result/2 turn a
completion into the answer its caller is given. The code and the slot or
address a command completion carries are what the controller wrote, so
they are bounded here: a success that names a slot or an address out of
range is `malformed`, and the controller fails, as it does for an event
naming a tag the core never gave.

**Commands** run one at a time: each waits in order and is posted when the
one before it completes. One not answered within `xhci_command_deadline_ms`
fails the controller at the next `expired`. The bus process's commands,
`{command, From, Command}`, are answered with their decoded completion;
Address Device's success adds the slot and its EP0 pipe, and Configure
Endpoint's success adds and drops the pipes it names.

**Pipes** are in one of the design's states: `open`, which accepts posts;
`halted`, which answers them `{error, halted}`; `{resetting, Reset}`,
which answers them `{error, resetting}`; a pipe the core does not hold
answers `{error, gone}`. set_pipe/3 is the one writer of a pipe's state,
so a pipe that leaves `open` answers its waiting requests as it would a
post, and one that returns to it posts the next. A control pipe, EP0,
carries one request at a time, so its posts wait in order. A transfer that
completes with a code that halts the endpoint (every code but success,
short packet and the stop codes) halts its pipe; EP0 is never left
halted: the core resets it as `reset_pipe` would before it answers the
request that halted it.

**reset_pipe** chooses its steps from the queue's state as the NIF reports
it, `idle`, `busy`, `stopped` or `halted`, by plan/3, the design's table:
a halted queue takes Reset Endpoint, then CLEAR_TT_BUFFER for a control or
bulk endpoint of a low- or full-speed device behind a translator, then
CLEAR_FEATURE(ENDPOINT_HALT) for any endpoint but a control one, then Set
TR Dequeue Pointer; a busy queue takes Stop Endpoint and is planned again
as stopped, or as halted when the stop answers a context state error; a
stopped EP0 takes Set TR Dequeue Pointer and an idle one nothing; any
other stopped or idle queue is dropped and added by Configure Endpoint,
then CLEAR_FEATURE(ENDPOINT_HALT). The steps run one at a time, each on
the previous one's success. A request step is a transfer whose requester
is the reset, so answering that transfer continues the reset, and an
answer for a pipe no longer resetting is stale and changes nothing. A
transfer that halts while the reset's Stop
Endpoint still waits to be posted plans the reset again as halted, since
the NIF accepts only Reset Endpoint on a halted queue. The last step's
success opens the pipe and answers `ok`; a failed step halts it and
answers the step's error.
""".

-export([new/0, step/3, next_deadline/1, capabilities/1]).
-export([completion/1, command_answer/3, transfer_result/2, decode_capabilities/2, port_operation/3, modify/4]).

-export_type([state/0, event/0, action/0, pipe/0, command/0, completion/0, register/0, capabilities/0]).

-include("generated/erx_abi.hrl").
-include("generated/erx_hw_xhci.hrl").

-type ms() :: integer().
-type slot() :: 1..?ERX_USB_DEVICES_MAX.
-doc "An endpoint's device context index, EP0's 1.".
-type dci() :: 1..(?ERX_XHCI_DEVICE_CONTEXTS - 1).
-type pipe() :: {slot(), dci()}.
-type tag() :: non_neg_integer().
-type address() :: 1..?ERX_USB_ADDRESS_MAX.

-doc "A completion code by its name in abi/formats/xhci.txt, or a code that file does not name.".
-type completion() :: atom() | {unknown, integer()}.

-doc "A queue's state as the NIF reports it: open with nothing posted, open with transfers posted, stopped, halted.".
-type queue_report() :: idle | busy | stopped | halted.

-type tt() :: #{hub_slot := slot(), port := 1..?ERX_USB_HUB_PORTS_MAX, multi := boolean()}.
-doc "The device an Address Device addresses; the core reads its speed and translator.".
-type device() :: #{speed := low | full | high | super, tt := none | tt(), atom() => term()}.
-doc "An endpoint Configure Endpoint adds; the core reads its address and type, and keeps the rest to add it again.".
-type endpoint() :: #{address := byte(), type := bulk | interrupt, atom() => term()}.
-type config() :: #{add := [endpoint()], drop := [dci()], hub := term()}.

-doc "A command the bus process asks for.".
-type bus_command() :: enable_slot
                     | {address_device, slot(), device()}
                     | {evaluate_context, slot(), #{ep0_packet := pos_integer()}}
                     | {configure_endpoints, slot(), config()}.
-doc "A command as the core posts it; the controller process gives it to the NIF in the NIF's form.".
-type command() :: bus_command() | {stop_endpoint | reset_endpoint | set_tr_dequeue, slot(), dci()}.

-type transfer() :: {control, Setup :: <<_:64>>, none | {in, pos_integer()} | {out, binary()}}
                  | {normal, {in, pos_integer()} | {out, binary()}}.

-type port_no() :: 1..255.

-doc """
A register by the name the core gives it, which the controller process maps
to the device NIF's: a capability or operational register by its name in
hw/svd/xhci/xhci.svd; port n's PORTSC; the legacy support capability's
semaphore bytes, its cluster LEGACY's BIOS_OWNED and OS_OWNED there; and the
I-th supported-protocol capability's REVISION and PORTS, of the I-th instance
of its cluster PROTOCOL.
""".
-type register() :: hcsparams1 | hcsparams2 | hccparams1 | pagesize | usbsts | iman
                  | {portsc, port_no()}
                  | {legacy, bios_owned | os_owned}
                  | {protocol, pos_integer(), revision | ports}.

-doc "The extended capabilities the device NIF bound at open: whether a legacy support one, and how many supported-protocol ones.".
-type bound() :: #{legacy := boolean(), protocols := non_neg_integer()}.

-doc """
What the capability registers say (5.3.3, 5.3.4 and 5.3.6, pp. 382-387): the
slot, interrupter and port counts, the scratchpad buffers the controller
asks for, whether it reaches 64-bit addresses, its context size in bytes,
and the USB major revision of each port a supported-protocol capability
names.
""".
-type capabilities() :: #{slots := byte(), interrupters := 0..2047, ports := byte(), scratchpads := 0..1023,
                          ac64 := boolean(), context_bytes := 32 | 64, protocols := #{port_no() => byte()}}.

-type port_op() :: get_status | power_on | reset | disable | {clear, atom()}.

-doc "An entry complete/2 returns: a transfer's or a command's completion, or a port's event.".
-type nif_event() :: {tag(), Code :: integer(), Extra :: term()} | {port, port_no()}.

-type event() :: {command, From :: term(), bus_command()}
               | {post, From :: term(), pipe(), transfer()}
               | {reset_pipe, From :: term(), pipe(), queue_report()}
               | {complete, tag(), Code :: integer(), Extra :: term()}
               | {refused, tag(), Reason :: term()}
               | {start, bound()}
               | {read, #{register() => non_neg_integer()}}
               | {negotiated, ok | {error, term()}}
               | interrupt
               | {completed, {ok, [nif_event()]} | {error, term()}}
               | {port, From :: term(), port_no(), port_op()}
               | expired.

-type action() :: {command, tag(), command()}
               | {transfer, pipe(), tag(), transfer()}
               | {reply, From :: term(), Answer :: term()}
               | {read, [register()]}
               | {write, register(), non_neg_integer()}
               | negotiate
               | {start_bus, Ports :: byte()}
               | complete
               | ack
               | {port_event, port_no()}
               | {log, bios_handoff_timeout}
               | {fail, Reason :: term()}.

-doc """
Where the start has got to: not started; the capability registers asked
for; the BIOS's semaphore being read, or polled again at a time, until the
handoff gives up; the install called, or called again at a time, until its
deadline; running, with the time USBSTS is next read.
""".
-type phase() :: stopped
               | {capabilities, bound()}
               | {bios_handoff, GiveUp :: ms(), reading | {poll, ms()}}
               | {installing, Deadline :: ms(), calling | {retry, ms()}}
               | {running, NextRead :: ms()}.

-type result() :: {ok, binary()} | {error, term()}.
-doc "Who a transfer's result goes to: a caller, or the reset of a pipe whose step it is.".
-type requester() :: {reply, From :: term()} | {step, pipe()}.

-type step() :: stop_endpoint | reset_endpoint | set_tr_dequeue | drop_add | clear_tt | clear_halt.
-doc """
A reset in progress: who asked, or the request whose halt began it with
that request's result, and the steps still to run, the first in flight or
waiting its turn.
""".
-type reset() :: #{requester := requester() | {halt, requester(), result()}, steps := [step()]}.

-type pipe_state() :: open | halted | {resetting, reset()}.
-type pipe_record() :: #{endpoint := #{address := byte(), type := control | bulk | interrupt, atom() => term()},
                         state := pipe_state(),
                         waiting := [{requester(), transfer()}]}.
-type slot_record() :: #{address := address(), speed := low | full | high | super, tt := none | tt(),
                         hub := term()}.

-doc "Who a command is for: the bus process, or the reset of a pipe whose step it is.".
-type owner() :: {bus, From :: term(), bus_command()} | {reset, pipe()}.

-doc """
`inflight` holds every transfer posted and not yet completed, by tag;
`command` the one command in flight, with its deadline; `commands` the
commands waiting, oldest first; `port_ops` the root-port operations whose
PORTSC read is awaited, oldest first; `line` the interrupt line: `idle`,
`held` by an interrupt before the controller runs and owed its `ack`, or
`{draining, Events}` while a pass reads the event ring; `reported` the
PORTSC change bits each root port's last `get_status` reported and no
clear has written since.
""".
-opaque state() :: #{phase := phase(),
                     line := idle | held | {draining, Events :: non_neg_integer()},
                     capabilities := none | capabilities(),
                     port_ops := [{port_no(), port_op(), From :: term()}],
reported := #{port_no() => non_neg_integer()},
                     slots := #{slot() => slot_record()},
                     pipes := #{pipe() => pipe_record()},
                     inflight := #{tag() => {pipe(), requester()}},
                     command := none | {tag(), owner(), command(), Deadline :: ms()},
                     commands := [owner()]}.

-define(EP0, 1).
-define(IS_BUS_COMMAND(C), (C =:= enable_slot orelse element(1, C) =:= address_device
                            orelse element(1, C) =:= evaluate_context orelse element(1, C) =:= configure_endpoints)).

-doc "A controller not yet started, with no slots and nothing in flight.".
-spec new() -> state().
new() ->
    #{phase => stopped, line => idle, capabilities => none, port_ops => [], reported => #{},
      slots => #{}, pipes => #{}, inflight => #{}, command => none, commands => []}.

-doc "What the controller's capability registers said, for its inspection record, or `none` before they are read.".
-spec capabilities(state()) -> capabilities() | none.
capabilities(#{capabilities := Capabilities}) -> Capabilities.

-doc "The next state on Event, handled at Now, and the actions the controller process performs.".
-spec step(event(), ms(), state()) -> {state(), [action()]}.
step(Event, Now, State) ->
    {Next, Reversed} = start_command(Now, event(Event, Now, {State, []})),
    case [Fail || Fail = {fail, _} <- Reversed] of
        [] -> {Next, lists:reverse(Reversed)};
        Fails -> {Next, [lists:last(Fails)]}
    end.

%% An interrupt held before the controller ran is owed one ack once the bus starts:
%% given here, and the line left idle; a line not held is left as it is.
release_line({S = #{line := held}, A}) -> emit(ack, {S#{line := idle}, A});
release_line(Acc) -> Acc.

-doc "The earliest of the command's deadline and the phase's, the start's next poll or the next status read, or `none`.".
-spec next_deadline(state()) -> ms() | none.
next_deadline(#{command := Command, phase := Phase}) ->
    case [At || At <- [command_deadline(Command), phase_deadline(Phase)], At =/= none] of
        [] -> none;
        Ats -> lists:min(Ats)
    end.

command_deadline(none) -> none;
command_deadline({_Tag, _Owner, _Command, At}) -> At.

phase_deadline({bios_handoff, _GiveUp, {poll, At}}) -> At;
phase_deadline({installing, _Deadline, {retry, At}}) -> At;
phase_deadline({running, At}) -> At;
phase_deadline(_Phase) -> none.

%% Events

event({command, From, Command}, _Now, {S = #{commands := Commands}, A}) when ?IS_BUS_COMMAND(Command) ->
    {S#{commands := Commands ++ [{bus, From, Command}]}, A};
event({post, From, Pipe, Transfer}, _Now, Acc) ->
    post(Pipe, {reply, From}, Transfer, Acc);
event({reset_pipe, From, Pipe, Queue}, _Now, Acc = {#{pipes := Pipes}, _}) ->
    case Pipes of
        #{Pipe := #{state := {resetting, _}}} -> answer({reply, From}, {error, resetting}, Acc);
        #{Pipe := _} -> begin_reset(Pipe, {reply, From}, Queue, Acc);
        #{} -> answer({reply, From}, {error, gone}, Acc)
    end;
event({complete, Tag, Code, Extra}, _Now, {S = #{command := {Tag, Owner, Command, _}}, A}) ->
    commanded(Owner, Command, command_answer(kind(Command), Code, Extra), {S#{command := none}, A});
event({complete, Tag, Code, Extra}, _Now, {S = #{inflight := Inflight}, A}) ->
    case maps:take(Tag, Inflight) of
        {{Pipe, Requester}, Rest} -> transferred(Pipe, Requester, transfer_result(Code, Extra), {S#{inflight := Rest}, A});
        error -> emit({fail, {unknown_tag, Tag}}, {S, A})
    end;
event({refused, Tag, Reason}, _Now, Acc = {#{command := {Tag, _, Command, _}}, _}) ->
    emit({fail, {refused, Command, Reason}}, Acc);
event({refused, Tag, Reason}, _Now, {S = #{inflight := Inflight}, A}) ->
    case maps:take(Tag, Inflight) of
        {{Pipe, Requester}, Rest} -> answer(Requester, {error, Reason}, post_waiting(Pipe, {S#{inflight := Rest}, A}));
        error -> emit({fail, {unknown_tag, Tag}}, {S, A})
    end;
event({start, Bound}, _Now, {S = #{phase := stopped}, A}) ->
    emit({read, [hcsparams1, hcsparams2, hccparams1, pagesize | protocol_registers(Bound)]},
         {S#{phase := {capabilities, Bound}}, A});
event({read, Words}, Now, Acc = {#{phase := {capabilities, Bound}}, _}) when is_map_key(hcsparams1, Words) ->
    capabilities_read(decode_capabilities(Words, Bound), Bound, Now, Acc);
event({read, Words}, Now, Acc) ->
    read(lists:sort(maps:to_list(Words)), Now, Acc);
event({negotiated, Result}, Now, Acc = {#{phase := {installing, _, calling}}, _}) ->
    negotiated(Result, Now, Acc);
event(interrupt, _Now, Acc = {#{phase := {running, _}}, _}) ->
    emit({read, [usbsts, iman]}, Acc);
event(interrupt, _Now, {S, A}) ->
    {S#{line := held}, A};
event({completed, {ok, Events}}, Now, Acc = {#{line := {draining, _}}, _}) ->
    drained(length(Events), lists:foldl(fun(Event, In) -> nif_event(Event, Now, In) end, Acc, Events));
event({completed, {error, Reason}}, _Now, Acc) ->
    emit({fail, {complete, Reason}}, Acc);
event({completed, _Batch}, _Now, Acc) ->
    emit({fail, {unexpected, completed}}, Acc);
event({port, From, Port, Op}, _Now, Acc = {#{phase := {running, _}}, _}) ->
    case root_port(Port, Acc) of
        true ->
            {S = #{port_ops := Ops}, A} = Acc,
            emit({read, [{portsc, Port}]}, {S#{port_ops := Ops ++ [{Port, Op, From}]}, A});
        false ->
            answer({reply, From}, {error, badarg}, Acc)
    end;
event({port, From, _Port, _Op}, _Now, Acc) ->
    answer({reply, From}, {error, halted}, Acc);
event(expired, Now, Acc) ->
    command_expired(Now, phase_expired(Now, Acc));
event(Event, _Now, Acc) ->
    emit({fail, {unexpected, Event}}, Acc).

command_expired(Now, Acc = {#{command := {_Tag, _Owner, Command, At}}, _}) when At =< Now ->
    emit({fail, {command_timeout, Command}}, Acc);
command_expired(_Now, Acc) ->
    Acc.

%% Start

protocol_registers(#{protocols := Count}) ->
    [{protocol, I, Word} || I <- lists:seq(1, Count), Word <- [revision, ports]].

%% The capability registers decoded: a legacy support capability begins the
%% BIOS's handoff, and without one the install follows at once.
capabilities_read({ok, Capabilities}, Bound, Now, {S, A}) ->
    Read = {S#{capabilities := Capabilities}, A},
    case Bound of
        #{legacy := true} ->
            emit({read, [{legacy, bios_owned}]},
                 emit({write, {legacy, os_owned}, ?ERX_HW_XHCI_OS_OWNED_OWNED_MASK},
                      set_phase({bios_handoff, Now + ?ERX_XHCI_BIOS_HANDOFF_MS, reading}, Read)));
        #{legacy := false} ->
            install(Now, Read)
    end;
capabilities_read({error, Reason}, _Bound, _Now, Acc) ->
    emit({fail, {capabilities, Reason}}, Acc).

%% The BIOS's semaphore read: clear ends the handoff, and so does the time
%% FreeBSD gives the BIOS (xhci_pci.c:546-555); otherwise it is read again.
bios_owned(Byte, Now, Acc = {#{phase := {bios_handoff, GiveUp, reading}}, _}) ->
    if
        ?ERX_HW_XHCI_BIOS_OWNED_OWNED_GET(Byte) =:= 0 -> install(Now, Acc);
        Now >= GiveUp -> install(Now, emit({log, bios_handoff_timeout}, Acc));
        true -> set_phase({bios_handoff, GiveUp, {poll, Now + ?ERX_XHCI_POLL_MS}}, Acc)
    end.

install(Now, Acc) ->
    emit(negotiate, set_phase({installing, Now + ?ERX_XHCI_INSTALL_DEADLINE_MS, calling}, Acc)).

negotiated(ok, Now, Acc = {#{capabilities := #{ports := Ports}}, _}) ->
    release_line(emit({start_bus, Ports}, set_phase({running, Now + ?ERX_XHCI_STATUS_INTERVAL_MS}, Acc)));
negotiated({error, ebusy}, Now, Acc = {#{phase := {installing, Deadline, calling}}, _}) when Now < Deadline ->
    set_phase({installing, Deadline, {retry, min(Now + ?ERX_XHCI_POLL_MS, Deadline)}}, Acc);
negotiated({error, ebusy}, _Now, Acc) ->
    emit({fail, install_timeout}, Acc);
negotiated({error, Reason}, _Now, Acc) ->
    emit({fail, {install, Reason}}, Acc).

phase_expired(Now, Acc = {#{phase := {bios_handoff, GiveUp, {poll, At}}}, _}) when At =< Now ->
    emit({read, [{legacy, bios_owned}]}, set_phase({bios_handoff, GiveUp, reading}, Acc));
phase_expired(Now, Acc = {#{phase := {installing, Deadline, {retry, _}}}, _}) when Deadline =< Now ->
    emit({fail, install_timeout}, Acc);
phase_expired(Now, Acc = {#{phase := {installing, Deadline, {retry, At}}}, _}) when At =< Now ->
    emit(negotiate, set_phase({installing, Deadline, calling}, Acc));
phase_expired(Now, Acc = {#{phase := {running, At}}, _}) when At =< Now ->
    emit({read, [usbsts]}, set_phase({running, Now + ?ERX_XHCI_STATUS_INTERVAL_MS}, Acc));
phase_expired(_Now, Acc) ->
    Acc.

set_phase(Phase, {S, A}) -> {S#{phase := Phase}, A}.

set_line(Line, {S, A}) -> {S#{line := Line}, A}.

%% Reads, by the registers answered

read([{{legacy, bios_owned}, Byte}], Now, Acc = {#{phase := {bios_handoff, _, reading}}, _}) ->
    bios_owned(Byte, Now, Acc);
read([{{portsc, Port}, Word}], _Now, {S = #{port_ops := Ops, reported := Reported}, A}) ->
    case lists:keytake(Port, 1, Ops) of
        {value, {Port, Op, From}, Rest} ->
            {Writes, Answer, Left} = port_operation(Op, Word, maps:get(Port, Reported, 0)),
            Written = lists:foldl(fun(Write, In) -> emit({write, {portsc, Port}, Write}, In) end,
                                  {S#{port_ops := Rest, reported := Reported#{Port => Left}}, A}, Writes),
            answer({reply, From}, Answer, Written);
        false ->
            emit({fail, {unexpected_read, {portsc, Port}}}, {S, A})
    end;
read([{iman, Iman}, {usbsts, Status}], _Now, Acc = {#{phase := {running, _}}, _})
  when is_integer(Iman), is_integer(Status) ->
    serviced(Status, Iman, Acc);
read([{usbsts, Status}], _Now, Acc = {#{phase := {running, _}}, _}) when is_integer(Status) ->
    case status_fault(Status) of
        none -> Acc;
        Fault -> emit({fail, Fault}, Acc)
    end;
read(Words, _Now, Acc) ->
    emit({fail, {unexpected_read, [Register || {Register, _} <- Words]}}, Acc).

%% Events

%% An interrupt's status: a controller that has stopped fails; otherwise the
%% event interrupt and the interrupter's pending bit are cleared before the
%% event ring is read.
serviced(Status, Iman, Acc) ->
    case status_fault(Status) of
        none ->
            Eint = ?ERX_HW_XHCI_USBSTS_EINT_MASK,
            Ip = ?ERX_HW_XHCI_IMAN_IP_MASK,
            Cleared = emit({write, iman, modify(Iman, ?ERX_HW_XHCI_IMAN_PRESERVE, Ip, Ip)},
                           emit({write, usbsts, modify(Status, ?ERX_HW_XHCI_USBSTS_PRESERVE, Eint, Eint)}, Acc)),
            emit(complete, set_line({draining, 0}, Cleared));
        Fault ->
            emit({fail, Fault}, Acc)
    end.

%% What stopped a controller that should be running, whose USBSTS reads Status,
%% or `none`: a host system error, which an all-ones read from a function that
%% left the bus shows too; a host controller error, which only a reset clears
%% (4.24.1, p. 358); or halted with neither.
status_fault(Status) ->
    if
        ?ERX_HW_XHCI_USBSTS_HSE_GET(Status) =/= 0 -> host_system_error;
        ?ERX_HW_XHCI_USBSTS_HCE_GET(Status) =/= 0 -> host_controller_error;
        ?ERX_HW_XHCI_USBSTS_HCH_GET(Status) =/= 0 -> host_controller_halted;
        true -> none
    end.

%% A batch of Count events handled: the pass reads on while the batch was not
%% empty and the pass has not reached its bound, and acknowledges the line
%% otherwise.
drained(Count, Acc = {#{line := {draining, Before}}, _}) ->
    Events = Before + Count,
    if
        Count =:= 0; Events >= ?ERX_XHCI_EVENTS_PER_INTERRUPT -> emit(ack, set_line(idle, Acc));
        true -> emit(complete, set_line({draining, Events}, Acc))
    end.

nif_event({port, Port}, _Now, Acc) ->
    case root_port(Port, Acc) of
        true -> emit({port_event, Port}, Acc);
        false -> emit({fail, {malformed_event, {port, Port}}}, Acc)
    end;
nif_event({Tag, Code, Extra}, Now, Acc) ->
    event({complete, Tag, Code, Extra}, Now, Acc);
nif_event(Event, _Now, Acc) ->
    emit({fail, {malformed_event, Event}}, Acc).

%% A port of the root hub: 1 to the port count the capability registers read.
root_port(Port, {#{capabilities := #{ports := Ports}}, _}) ->
    is_integer(Port) andalso Port >= 1 andalso Port =< Ports.

%% Root ports

-doc """
A root-port operation on the port whose PORTSC reads Word and whose last
get_status reported the change bits Reported: the PORTSC words to write,
each modify/4 of Word, the answer to the bus process, and the change bits
reported and not yet cleared after it. get_status writes nothing, answers
the USB 2 hub words, wPortStatus and wPortChange, with the PORTSC speed ID,
and reports every change bit Word has set. `{clear, Change}` writes those
of Change's bits that were reported, or nothing when none was, so a bit set
since the read stays set; a name no change bit stands behind answers
`{error, badarg}`.
""".
-spec port_operation(port_op(), non_neg_integer(), non_neg_integer()) ->
          {[non_neg_integer()], ok | {ok, <<_:32>>, byte()} | {error, badarg}, non_neg_integer()}.
port_operation(get_status, Word, _Reported) ->
    {[], {ok, <<(port_status(Word)):16/little, (port_changes(Word)):16/little>>,
          ?ERX_HW_XHCI_PORTSC_SPEED_GET(Word)},
     Word band change_bits()};
port_operation(power_on, Word, Reported) ->
    {[set_portsc(Word, ?ERX_HW_XHCI_PORTSC_PP_MASK)], ok, Reported};
port_operation(reset, Word, Reported) ->
    {[set_portsc(Word, ?ERX_HW_XHCI_PORTSC_PR_MASK)], ok, Reported};
port_operation(disable, Word, Reported) ->
    {[set_portsc(Word, ?ERX_HW_XHCI_PORTSC_PED_MASK)], ok, Reported};
port_operation({clear, Change}, Word, Reported) ->
    case lists:keyfind(Change, 1, port_changes()) of
        {Change, Bits, _UsbBit} ->
            Clear = Bits band Reported,
            {[set_portsc(Word, Clear) || Clear =/= 0], ok, Reported band bnot Bits};
        false ->
            {[], {error, badarg}, Reported}
    end.

%% Every PORTSC change bit, from the one table.
change_bits() ->
    lists:foldl(fun({_Name, Bits, _UsbBit}, All) -> All bor Bits end, 0, port_changes()).

set_portsc(Word, Bits) -> modify(Word, ?ERX_HW_XHCI_PORTSC_PRESERVE, Bits, Bits).

%% wPortStatus from PORTSC. The port is suspended in the U3 link state; the
%% speed bits stay clear, since a root port's speed is its speed ID.
port_status(Word) ->
    lists:foldl(fun(Bit, Status) -> Status bor Bit end, 0,
                [Bit || {true, Bit} <- [{Word band ?ERX_HW_XHCI_PORTSC_CCS_MASK =/= 0, ?ERX_USB_PORT_STATUS_CONNECTION},
                 {Word band ?ERX_HW_XHCI_PORTSC_PED_MASK =/= 0, ?ERX_USB_PORT_STATUS_ENABLED},
                 {?ERX_HW_XHCI_PORTSC_PLS_GET(Word) =:= ?ERX_HW_XHCI_PORTSC_PLS_U3, ?ERX_USB_PORT_STATUS_SUSPEND},
                 {Word band ?ERX_HW_XHCI_PORTSC_OCA_MASK =/= 0, ?ERX_USB_PORT_STATUS_OVER_CURRENT},
                 {Word band ?ERX_HW_XHCI_PORTSC_PR_MASK =/= 0, ?ERX_USB_PORT_STATUS_RESET},
                 {Word band ?ERX_HW_XHCI_PORTSC_PP_MASK =/= 0, ?ERX_USB_PORT_STATUS_POWER}]]).

%% wPortChange from PORTSC: a name's bit when any change bit behind it is set.
port_changes(Word) ->
    lists:foldl(fun({_Name, Bits, UsbBit}, Changes) when Word band Bits =/= 0 -> Changes bor UsbBit;
                   (_Change, Changes) -> Changes
                end, 0, port_changes()).

%% Every PORTSC change bit behind the USB 2 change name the bus core reads and
%% clears, with that name's bit in wPortChange: the one table both directions use.
port_changes() ->
    [{connection, ?ERX_HW_XHCI_PORTSC_CSC_MASK, ?ERX_USB_PORT_CHANGE_CONNECTION},
     {enabled, ?ERX_HW_XHCI_PORTSC_PEC_MASK bor ?ERX_HW_XHCI_PORTSC_CEC_MASK, ?ERX_USB_PORT_CHANGE_ENABLED},
     {suspend, ?ERX_HW_XHCI_PORTSC_PLC_MASK, ?ERX_USB_PORT_CHANGE_SUSPEND},
     {over_current, ?ERX_HW_XHCI_PORTSC_OCC_MASK, ?ERX_USB_PORT_CHANGE_OVER_CURRENT},
     {reset, ?ERX_HW_XHCI_PORTSC_PRC_MASK bor ?ERX_HW_XHCI_PORTSC_WRC_MASK, ?ERX_USB_PORT_CHANGE_RESET}].

-doc """
The word to write to a register read as Read, to set Bits within the field
Mask: the read's bits the register's Preserve mask keeps, but those of the
field, and Bits. Every write-one-to-clear or write-one-to-act bit is outside
Preserve, so the write sets only the ones in Bits (hw/svd/xhci/xhci.svd's
derived preserve masks; FreeBSD's XHCI_PS_CLEAR, xhcireg.h:146, for PORTSC).
""".
-spec modify(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) -> non_neg_integer().
modify(Read, Preserve, Mask, Bits) ->
    (Read band Preserve band bnot Mask) bor Bits.

%% Capabilities

-doc """
The capability registers' words decoded, or why the controller cannot be
driven: `{unsupported, page_size}` when PAGESIZE does not offer the 4 KiB
pages the device NIF lays out (5.4.3, pp. 399-400; xhci.c:546-549), and
`{malformed, {protocol, I}}` when the I-th supported-protocol capability names
no port, a port past the port count, or a port an earlier capability
already named (Table 7-8, p. 523). The scratchpad
count is HCSPARAMS2's high five bits above its low five (5.3.4, pp. 383-384).
""".
-spec decode_capabilities(#{register() => non_neg_integer()}, bound()) ->
          {ok, capabilities()} | {error, {unsupported, page_size} | {malformed, {protocol, pos_integer()}}}.
decode_capabilities(Words = #{hcsparams1 := Params1, hcsparams2 := Params2, hccparams1 := CParams1,
                              pagesize := PageSize}, #{protocols := Count}) ->
    Ports = ?ERX_HW_XHCI_HCSPARAMS1_MAXPORTS_GET(Params1),
    try
        ?ERX_HW_XHCI_PAGESIZE_FOUR_KIB_GET(PageSize) =:= 1 orelse throw({unsupported, page_size}),
        Protocols = lists:foldl(fun(I, Acc) -> protocol_ports(I, Words, Ports, Acc) end,
                                #{}, lists:seq(1, Count)),
        {ok, #{slots => ?ERX_HW_XHCI_HCSPARAMS1_MAXSLOTS_GET(Params1),
               interrupters => ?ERX_HW_XHCI_HCSPARAMS1_MAXINTRS_GET(Params1),
               ports => Ports,
               scratchpads => (?ERX_HW_XHCI_HCSPARAMS2_SPB_MAX_HI_GET(Params2)
                                   bsl ?ERX_HW_XHCI_HCSPARAMS2_SPB_MAX_LO_WIDTH)
                   bor ?ERX_HW_XHCI_HCSPARAMS2_SPB_MAX_LO_GET(Params2),
               ac64 => ?ERX_HW_XHCI_HCCPARAMS1_AC64_GET(CParams1) =:= 1,
               context_bytes => case ?ERX_HW_XHCI_HCCPARAMS1_CSZ_GET(CParams1) of 1 -> 64; 0 -> 32 end,
               protocols => Protocols}}
    catch
        throw:Reason -> {error, Reason}
    end.

%% The ports of the I-th supported-protocol capability, each with its major
%% revision, added to those of the capabilities before it: Compatible Port
%% Count ports from Compatible Port Offset, all within 1..Ports and none
%% named before, since a port speaks one protocol.
protocol_ports(I, Words, Ports, Named) ->
    #{{protocol, I, revision} := Revision, {protocol, I, ports} := PortWord} = Words,
    First = ?ERX_HW_XHCI_PORTS_OFFSET_GET(PortWord),
    Count = ?ERX_HW_XHCI_PORTS_COUNT_GET(PortWord),
    First >= 1 andalso Count >= 1 andalso First + Count - 1 =< Ports orelse throw({malformed, {protocol, I}}),
    Range = lists:seq(First, First + Count - 1),
    lists:any(fun(Port) -> is_map_key(Port, Named) end, Range) andalso throw({malformed, {protocol, I}}),
    Major = ?ERX_HW_XHCI_REVISION_MAJOR_GET(Revision),
    maps:merge(Named, maps:from_list([{Port, Major} || Port <- Range])).

%% Commands, one at a time

%% Posts the first waiting command when none is in flight. A reset's entry
%% posts the command of its first step as it stands now, so a reset planned
%% again while it waited posts its new first step; an entry whose pipe is no
%% longer resetting is dropped. Tags of commands and transfers are one
%% namespace.
start_command(Now, {S = #{command := none, commands := [Owner | Waiting], inflight := Inflight}, A}) ->
    case owned_command(Owner, S) of
        {ok, Command} ->
            Tag = tag(Inflight, 0, S),
            emit({command, Tag, Command},
                 {S#{command := {Tag, Owner, Command, Now + ?ERX_XHCI_COMMAND_DEADLINE_MS}, commands := Waiting}, A});
        stale ->
            start_command(Now, {S#{commands := Waiting}, A})
    end;
start_command(_Now, Acc) ->
    Acc.

owned_command({bus, _From, Command}, _S) ->
    {ok, Command};
owned_command({reset, Pipe = {Slot, Dci}}, #{pipes := Pipes, slots := Slots}) ->
    case Pipes of
        #{Pipe := #{state := {resetting, #{steps := [drop_add | _]}}, endpoint := Endpoint}} ->
            #{Slot := #{hub := Hub}} = Slots,
            {ok, {configure_endpoints, Slot, #{add => [Endpoint], drop => [Dci], hub => Hub}}};
        #{Pipe := #{state := {resetting, #{steps := [Step | _]}}}} ->
            {ok, {Step, Slot, Dci}};
        #{} ->
            stale
    end.

%% A command's decoded answer, to the bus process or to the reset whose step it is.
commanded(_Owner, Command, malformed, Acc) ->
    emit({fail, {malformed_answer, Command}}, Acc);
commanded({bus, From, Command}, Command, Answer, Acc) ->
    answer({reply, From}, Answer, bus_done(Command, Answer, Acc));
commanded({reset, Pipe}, _Command, Answer, Acc) ->
    step_answered(Pipe, Answer, Acc).

%% What a bus command's success changes: Address Device adds the slot and
%% its EP0 pipe, Configure Endpoint drops and adds the pipes it names; a
%% failure and the other commands change nothing. Each command has its own
%% clause, so one of a shape the core does not know fails loudly.
bus_done({address_device, Slot, #{speed := Speed, tt := Tt}}, {ok, Address}, {S, A}) ->
    #{slots := Slots, pipes := Pipes} = S,
    Ep0 = #{endpoint => #{address => 0, type => control}, state => open, waiting => []},
    {S#{slots := Slots#{Slot => #{address => Address, speed => Speed, tt => Tt, hub => none}},
        pipes := Pipes#{{Slot, ?EP0} => Ep0}}, A};
bus_done({configure_endpoints, Slot, #{add := Add, drop := Drop, hub := Hub}}, ok, {S, A}) ->
    #{slots := Slots = #{Slot := Record}, pipes := Pipes} = S,
    Kept = maps:without([{Slot, Dci} || Dci <- Drop], Pipes),
    Added = maps:from_list([{{Slot, dci(Endpoint)}, #{endpoint => Endpoint, state => open, waiting => []}}
                            || Endpoint <- Add]),
    {S#{slots := Slots#{Slot := Record#{hub := Hub}}, pipes := maps:merge(Kept, Added)}, A};
bus_done(_Command, {error, _}, Acc) ->
    Acc;
bus_done(enable_slot, {ok, _Slot}, Acc) ->
    Acc;
bus_done({evaluate_context, _Slot, _Packet}, ok, Acc) ->
    Acc.

%% Transfers

%% Posts Transfer on Pipe for Requester, or answers it as the pipe's state
%% answers posts. A control pipe's posts wait their turn.
post(Pipe, Requester, Transfer, Acc = {S = #{pipes := Pipes}, A}) ->
    case Pipes of
        #{Pipe := Record = #{state := open, endpoint := #{type := control}, waiting := Waiting}} ->
            post_waiting(Pipe, {S#{pipes := Pipes#{Pipe := Record#{waiting := Waiting ++ [{Requester, Transfer}]}}}, A});
        #{Pipe := #{state := open}} ->
            send(Pipe, Requester, Transfer, Acc);
        #{Pipe := #{state := PipeState}} ->
            answer(Requester, {error, refusal(PipeState)}, Acc);
        #{} ->
            answer(Requester, {error, gone}, Acc)
    end.

%% Posts the first request waiting on an open control pipe with none in flight.
post_waiting(Pipe, Acc = {S = #{pipes := Pipes, inflight := Inflight}, A}) ->
    case Pipes of
        #{Pipe := Record = #{state := open, waiting := [{Requester, Transfer} | Rest]}} ->
            case lists:keymember(Pipe, 1, maps:values(Inflight)) of
                true -> Acc;
                false -> send(Pipe, Requester, Transfer, {S#{pipes := Pipes#{Pipe := Record#{waiting := Rest}}}, A})
            end;
        #{} ->
            Acc
    end.

send(Pipe, Requester, Transfer, {S = #{inflight := Inflight}, A}) ->
    Tag = tag(Inflight, 0, S),
    emit({transfer, Pipe, Tag, Transfer}, {S#{inflight := Inflight#{Tag => {Pipe, Requester}}}, A}).

%% A transfer's result. One that halts the endpoint halts an open pipe, or,
%% on EP0, begins its reset, the request answered when the reset ends; on a
%% resetting pipe whose Stop Endpoint is not yet posted, it plans the reset
%% again as halted.
transferred(_Pipe, _Requester, malformed, Acc) ->
    emit({fail, malformed_transfer}, Acc);
transferred(Pipe, Requester, Result, Acc = {#{pipes := Pipes}, _}) ->
    case {halts(Result), Pipes} of
        {true, #{Pipe := #{state := open, endpoint := #{type := control}}}} ->
            begin_reset(Pipe, {halt, Requester, Result}, halted, Acc);
        {true, #{Pipe := #{state := open}}} ->
            answer(Requester, Result, set_pipe(Pipe, halted, Acc));
        {true, #{Pipe := #{state := {resetting, Reset = #{steps := [stop_endpoint | _]}}}}} ->
            Replanned = case reset_command_in_flight(Pipe, Acc) of
                            true -> Acc;
                            false -> replan(Pipe, Reset, halted, Acc)
                        end,
            answer(Requester, Result, Replanned);
        _ ->
            answer(Requester, Result, post_waiting(Pipe, Acc))
    end.

reset_command_in_flight(Pipe, {#{command := Command}, _}) ->
    case Command of
        {_Tag, {reset, Pipe}, _, _} -> true;
        _ -> false
    end.

%% Pipe states

%% The one writer of a pipe's state: a pipe that leaves open answers what
%% waits on it as its new state answers posts, and one that opens posts the
%% next.
set_pipe(Pipe, open, {S = #{pipes := Pipes}, A}) ->
    #{Pipe := Record} = Pipes,
    post_waiting(Pipe, {S#{pipes := Pipes#{Pipe := Record#{state := open}}}, A});
set_pipe(Pipe, PipeState, {S = #{pipes := Pipes}, A}) ->
    #{Pipe := Record = #{waiting := Waiting}} = Pipes,
    Left = {S#{pipes := Pipes#{Pipe := Record#{state := PipeState, waiting := []}}}, A},
    lists:foldl(fun({Requester, _Transfer}, Acc) -> answer(Requester, {error, refusal(PipeState)}, Acc) end,
                Left, Waiting).

refusal(halted) -> halted;
refusal({resetting, _}) -> resetting.

%% reset_pipe

begin_reset(Pipe = {Slot, _}, Requester, Queue, Acc = {#{pipes := Pipes, slots := Slots}, _}) ->
    #{Pipe := #{endpoint := Endpoint}} = Pipes,
    #{Slot := Device} = Slots,
    Reset = #{requester => Requester, steps => plan(Queue, Endpoint, Device)},
    advance(Pipe, set_pipe(Pipe, {resetting, Reset}, Acc)).

%% The design's table of reset_pipe's steps by the queue's state.
plan(halted, Endpoint, Device) ->
    [reset_endpoint] ++ [clear_tt || buffered_in_tt(Endpoint, Device)]
        ++ [clear_halt || not control(Endpoint)] ++ [set_tr_dequeue];
plan(busy, _Endpoint, _Device) ->
    [stop_endpoint];
plan(stopped, #{type := control}, _Device) ->
    [set_tr_dequeue];
plan(idle, #{type := control}, _Device) ->
    [];
plan(StoppedOrIdle, _Endpoint, _Device) when StoppedOrIdle =:= stopped; StoppedOrIdle =:= idle ->
    [drop_add, clear_halt].

%% A control or bulk endpoint of a low- or full-speed device behind a
%% high-speed hub's translator, whose buffered split transaction a halt can
%% leave in the translator.
buffered_in_tt(#{type := Type}, #{speed := Speed, tt := Tt}) ->
    Tt =/= none andalso (Speed =:= low orelse Speed =:= full) andalso (Type =:= control orelse Type =:= bulk).

control(#{type := Type}) -> Type =:= control.

replan(Pipe = {Slot, _}, Reset, Queue, Acc = {#{pipes := Pipes, slots := Slots}, _}) ->
    #{Pipe := #{endpoint := Endpoint}} = Pipes,
    #{Slot := Device} = Slots,
    advance(Pipe, set_pipe(Pipe, {resetting, Reset#{steps := plan(Queue, Endpoint, Device)}}, Acc)).

%% Starts a reset's first step: a command waits its turn; a request posts on
%% the EP0 it goes to; no step left ends the reset. A replanned reset whose
%% command is already waiting keeps its one place.
advance(Pipe, Acc = {S = #{pipes := Pipes, commands := Commands}, A}) ->
    #{Pipe := #{state := {resetting, #{steps := Steps}}}} = Pipes,
    case Steps of
        [] ->
            finish(Pipe, ok, Acc);
        [clear_tt | _] ->
            {Hub, Request} = tt_clear(Pipe, S),
            post({Hub, ?EP0}, {step, Pipe}, Request, Acc);
        [clear_halt | _] ->
            {Slot, _} = Pipe,
            post({Slot, ?EP0}, {step, Pipe}, endpoint_clear(Pipe, S), Acc);
        [_Command | _] ->
            case lists:member({reset, Pipe}, Commands) orelse reset_command_in_flight(Pipe, Acc) of
                true -> Acc;
                false -> {S#{commands := Commands ++ [{reset, Pipe}]}, A}
            end
    end.

%% The answer to a reset's first step. A Stop Endpoint's success plans the
%% reset again as stopped, and its context state error, the endpoint having
%% halted meanwhile, as halted; any other success runs the next step, and a
%% failure ends the reset. An answer for a pipe no longer resetting is
%% stale and changes nothing, so removing a pipe leaves no step to purge.
step_answered(Pipe, Answer, Acc = {#{pipes := Pipes}, _}) ->
    case {Pipes, Answer} of
        {#{Pipe := #{state := {resetting, Reset = #{steps := [stop_endpoint | _]}}}}, ok} ->
            replan(Pipe, Reset, stopped, Acc);
        {#{Pipe := #{state := {resetting, Reset = #{steps := [stop_endpoint | _]}}}}, {error, context_state_error}} ->
            replan(Pipe, Reset, halted, Acc);
        {#{Pipe := #{state := {resetting, _}}}, {error, Reason}} ->
            finish(Pipe, {error, Reason}, Acc);
        {#{Pipe := #{state := {resetting, Reset = #{steps := [_Done | Rest]}}}}, _Success} ->
            advance(Pipe, set_pipe(Pipe, {resetting, Reset#{steps := Rest}}, Acc));
        _Stale ->
            Acc
    end.

%% Ends a reset: success opens the pipe, failure halts it. A reset begun by
%% a halt answers the request that halted with that request's own result.
finish(Pipe, Outcome, Acc = {#{pipes := Pipes}, _}) ->
    #{Pipe := #{state := {resetting, #{requester := Requester}}}} = Pipes,
    Opened = set_pipe(Pipe, case Outcome of ok -> open; {error, _} -> halted end, Acc),
    case Requester of
        {halt, Halted, Result} -> answer(Halted, Result, Opened);
        _ -> answer(Requester, Outcome, Opened)
    end.

%% CLEAR_TT_BUFFER to the translator's hub, for the endpoint by its number,
%% direction and type and the device's address; wIndex the translator's
%% port, or 1 on a hub with one translator (FreeBSD's
%% usbd_req_clear_tt_buffer, usb_request.c:2246-2270).
tt_clear(Pipe = {Slot, _}, #{pipes := Pipes, slots := Slots}) ->
    #{Pipe := #{endpoint := #{address := EpAddress, type := Type}}} = Pipes,
    #{Slot := #{address := Address, tt := #{hub_slot := Hub, port := Port, multi := Multi}}} = Slots,
    Value = (EpAddress band ?ERX_USB_ENDPOINT_NUMBER_MASK)
        bor (Address bsl ?ERX_USB_TT_CLEAR_ADDRESS_SHIFT)
        bor (transfer_type(Type) bsl ?ERX_USB_TT_CLEAR_TYPE_SHIFT)
        bor ((EpAddress band ?ERX_USB_ENDPOINT_DIR_IN) bsl ?ERX_USB_TT_CLEAR_DIR_SHIFT),
    Index = case Multi of true -> Port; false -> 1 end,
    {Hub, {control, erx_usb_setup:packet(?ERX_USB_REQUEST_TYPE_CLASS bor ?ERX_USB_RECIPIENT_OTHER,
                                         ?ERX_USB_HUB_REQUEST_CLEAR_TT_BUFFER, Value, Index, 0), none}}.

transfer_type(control) -> ?ERX_USB_TRANSFER_TYPE_CONTROL;
transfer_type(bulk) -> ?ERX_USB_TRANSFER_TYPE_BULK.

%% CLEAR_FEATURE(ENDPOINT_HALT) to the endpoint, which resets the device's
%% side of its toggle.
endpoint_clear(Pipe, #{pipes := Pipes}) ->
    #{Pipe := #{endpoint := #{address := EpAddress}}} = Pipes,
    {control, erx_usb_setup:packet(?ERX_USB_REQUEST_TYPE_STANDARD bor ?ERX_USB_RECIPIENT_ENDPOINT,
                                   ?ERX_USB_REQUEST_CLEAR_FEATURE, ?ERX_USB_FEATURE_ENDPOINT_HALT, EpAddress, 0), none}.

%% Answers

answer({reply, From}, Answer, Acc) -> emit({reply, From, Answer}, Acc);
answer({step, Pipe}, Answer, Acc) -> step_answered(Pipe, Answer, Acc).

emit(Action, {S, A}) -> {S, [Action | A]}.

%% The lowest tag no post in flight holds.
tag(Inflight, N, S = #{command := {N, _, _, _}}) -> tag(Inflight, N + 1, S);
tag(Inflight, N, S) when is_map_key(N, Inflight) -> tag(Inflight, N + 1, S);
tag(_Inflight, N, _S) -> N.

%% An endpoint's device context index: twice its number, plus one for IN
%% (xHCI 4.5.1).
dci(#{address := EpAddress}) ->
    2 * (EpAddress band ?ERX_USB_ENDPOINT_NUMBER_MASK) + direction(EpAddress).

direction(EpAddress) when EpAddress band ?ERX_USB_ENDPOINT_DIR_IN =/= 0 -> 1;
direction(_EpAddress) -> 0.

kind(enable_slot) -> enable_slot;
kind(Command) -> element(1, Command).

%% Decoders

-doc "The completion code Code by its name in abi/formats/xhci.txt, or `{unknown, Code}`.".
-spec completion(integer()) -> completion().
completion(Code) when is_integer(Code) ->
    case lists:keyfind(Code, 2, ?ERX_XHCI_COMPLETION_MEMBERS) of
        {Name, Code} -> Name;
        false -> {unknown, Code}
    end.

-doc """
A command completion's answer: Enable Slot's slot, Address Device's address,
`ok` for the others, or the error its code names, Address Device's as
`{address, Code}`. A success whose slot or address is out of range, or a code
or value that is not an integer, is `malformed`.
""".
-spec command_answer(atom(), term(), term()) -> ok | {ok, pos_integer()} | {error, term()} | malformed.
command_answer(_Kind, Code, _Extra) when not is_integer(Code) ->
    malformed;
command_answer(enable_slot, ?ERX_XHCI_COMPLETION_SUCCESS, Slot) ->
    bounded(Slot, ?ERX_USB_DEVICES_MAX);
command_answer(address_device, ?ERX_XHCI_COMPLETION_SUCCESS, Address) ->
    bounded(Address, ?ERX_USB_ADDRESS_MAX);
command_answer(_Kind, ?ERX_XHCI_COMPLETION_SUCCESS, _Extra) ->
    ok;
command_answer(address_device, Code, _Extra) ->
    {error, {address, completion(Code)}};
command_answer(_Kind, Code, _Extra) ->
    {error, completion(Code)}.

bounded(Value, Max) when is_integer(Value), Value >= 1, Value =< Max -> {ok, Value};
bounded(_Value, _Max) -> malformed.

-doc """
A transfer completion's answer to its caller: the bytes moved on success or
a short packet; `stall` when the endpoint stalled; `stopped` for a transfer a
reset dropped; `{controller, Code}` for any other code. A code that is not an
integer or bytes that are not a binary are `malformed`.
""".
-spec transfer_result(term(), term()) -> result() | malformed.
transfer_result(Code, Bytes) when not is_integer(Code); not is_binary(Bytes) ->
    malformed;
transfer_result(Code, Bytes) when Code =:= ?ERX_XHCI_COMPLETION_SUCCESS; Code =:= ?ERX_XHCI_COMPLETION_SHORT_PACKET ->
    {ok, Bytes};
transfer_result(?ERX_XHCI_COMPLETION_STALL, _Bytes) ->
    {error, stall};
transfer_result(Code, _Bytes) when Code =:= ?ERX_XHCI_COMPLETION_STOPPED;
                                   Code =:= ?ERX_XHCI_COMPLETION_STOPPED_SHORT_PACKET;
                                   Code =:= ?ERX_XHCI_COMPLETION_STOPPED_LENGTH_INVALID ->
    {error, stopped};
transfer_result(Code, _Bytes) ->
    {error, {controller, completion(Code)}}.

%% Every completion but a success, a short packet and the stop codes halts
%% the endpoint (xHCI 4.10.2, p. 195), as the NIF's queue states take it.
halts({ok, _Bytes}) -> false;
halts({error, stopped}) -> false;
halts({error, _}) -> true.
