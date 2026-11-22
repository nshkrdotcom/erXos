%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_xhci_core).
-moduledoc """
The controller process's pure core (docs/design-usb.md, "The controller
process" and "Transfers and pipes"): the commands it runs, every pipe's
lifecycle, the transfers in flight with their requesters, and the map from
each live device's reference to its slot.

step/3 takes one event, the time it is handled at, in milliseconds, and the
state, and answers the next state and the actions the controller process
performs, in order: `{command, Tag, Command}` and `{transfer, Pipe, Tag,
Transfer}` post to the device NIF; `{bus, Answer}` sends the bus process
Answer with erx_usb_bus_link:answer/2; `{send, To, Message}` sends a
function process Message; `{queue_state, Pipe}` asks the NIF for a queue's
state, which the process feeds back as `{queue_state, Pipe, Report}` before
any other event; and `{fail, Reason}` ends the process, whose restart resets
the controller. A step that fails answers that action alone, so nothing
after it is posted and a held interrupt is not acknowledged.
The process feeds back every completion the NIF returns, `{complete, Tag,
Code, Extra}`, and every post the NIF refuses, `{refused, Tag, Reason}`.
Tags are the core's: the lowest number no post in flight holds.

**Requests.** The bus process's requests arrive as `{bus, Request}`, each
Request as erx_usb_bus_link spells it, and a function's as `{pipe, From,
Request}`, each Request as erx_usb_pipe spells it. Each answer is built by
the module that spells its request, erx_usb_bus_link:reply/2 and
erx_usb_pipe:reply/2, so the process delivers it without deciding anything.

**Device references** (the design's "A name dies at once; hardware is freed
only on the controller's report"). A request names a device by the
reference the bus process gave it at attach and an endpoint by its address,
never by a slot or a context index. The core maps each live reference to
its slot, bound by Enable Slot's success, and looks every request up
through that map: a reference detached, never seen or whose slot has been
torn down answers `{error, gone}` without reaching the NIF, whatever device
later has its slot. A waiting bus command is looked up when its turn comes,
so one whose device detached meanwhile is answered `{error, gone}` and
never posted. Detach unbinds the reference at once; the slot stays held
until its Disable Slot succeeds, so the controller cannot give its number
to another device first, and an Enable Slot that names a slot the core
still holds is malformed. A reference detached while its Enable Slot is in
flight leaves a slot nobody owns, which is torn down, the Enable Slot
answered `{error, gone}`.

**Teardown** of a slot is the one path to a disabled slot: for a detach, a
failed Address Device and a slot nobody owns. Its pipes become `draining`,
which answers posts `{error, gone}`, and the requests waiting on them and
any reset of them are answered `{error, gone}`. Then, one command at a
time, Stop Endpoint for each of its queues that still runs transfers, and
Disable Slot once none does (4.6.4, pp. 109-110). A queue runs transfers
while it is open with a transfer posted: a halting completion, a stop's
success or its context state error (4.6.9, p. 140) leaves it halted or
stopped, which Disable Slot accepts as well. Commands run one at a time,
and a waiting command for the slot is either a reset of a draining pipe,
dropped at its turn, or a bus command looked up through a reference no
longer bound to it, so when the teardown's turn comes no other command for
the slot is in flight or will be posted. Disable Slot's success frees the
slot and its pipes; any other answer of a teardown command fails the
controller.

**A failed Address Device** unbinds its reference from the slot and tears
the slot down; then, when its code is a USB Transaction Error and the
device sits behind a translator, it sends CLEAR_TT_BUFFER for address 0's
default control endpoint to the translator's hub (4.6.5, pp. 114-115),
and only then answers `{error, {address, Code}}`, or `{error, {tt_clear,
Reason}}` when the clear fails or passes its deadline. An Address Device
whose device detached while it was posted is answered when it completes:
with its address on success, the teardown following; after the cleanup
on failure.

**Aborting a control request.** A request on a control pipe gets a
deadline `xhci_control_deadline_ms` after it is posted. At the deadline,
on an open pipe, the request is aborted (4.11.2.2, p. 214; 4.6.9, p. 134):
the pipe is reset as `reset_pipe` resets a busy one, Stop Endpoint, then Set
TR Dequeue Pointer on a stopped EP0 or the halted row when the stop finds
it halted, and the aborted request's own completion is dropped. At the
last step's success the request is answered `{error, timeout}` and EP0 is
open again; a step that fails fails the controller, a command by its
deadline and a request by its own abort.

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
`{error, ebusy}` calls it again `xhci_poll_ms` later as `{negotiate, continue}`, the
one action that carries a negotiation on: every other call begins one, so a
restarted process, which starts from new/0, resets the controller afresh
(docs/design-usb.md, "Install"). An install still
busy `xhci_install_deadline_ms` after its first call fails the controller
without being called again. Its `ok` runs the controller, and the bus
process is answered `{root_ports, Ports}`, the root hub's port count, once
both that and the bus's `attach` have come, whichever comes last; a root
port's event before then is dropped, since the bus core reads every root
port when it starts.

**Root ports.** The bus process's root-hub operation `{port, root, Port,
Op}` reads the port's PORTSC and answers from it: `get_status` with the
USB 2 status and change words and the PORTSC speed ID; `power_on`, `reset`,
`disable` and `{clear, Change}` by writing PORTSC's port power, port reset,
port enable (whose 1 disables) or the change bits behind Change, each with
modify/4. A clear writes only those of Change's bits that the port's last
`get_status` reported, so a change that set after that read, which the bus
core has not seen, stays set for its next read. A port outside the
controller's port count is answered `{error, badarg}`, and a port event
that names one fails the controller as a malformed event, since the
controller wrote it. Every PORTSC change bit stands behind one USB 2
change name, so a port's changes can all be cleared and it raises its next
event (xHCI
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
when the controller runs. A controller that fails first does not
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
fails the controller at the next `expired`. The bus process's commands
are answered with their decoded completion. Address Device is posted with
the NIF's parameters, address_parameters/1, its success adds the device
and its EP0 pipe. The bus's Configure Endpoint is posted in parts of at
most `xhci_configure_adds_max` adds, the bindings one command carries in
the device NIF, and each part is posted only once the one before it has
succeeded. Each part's success adds the pipes it names. The bus is
answered ok after the last part, or with the first part's failure; the
pipes the parts before that failure added stay bound until the slot's
teardown, which the bus begins by giving the device up.
Stop Endpoint answers a success or a context state error; any other code,
a slot not enabled error, which an enabled slot cannot get (4.6.9, p.
140), fails the controller.

**Pipes** are in one of the design's states: `open`, which accepts posts;
`halted`, which answers them `{error, halted}`; `{resetting, Reset}`,
which answers them `{error, resetting}`; `{draining, Activity}`, which
answers them `{error, gone}` until its slot is freed. set_pipe/3 is the one
writer of a pipe's state, so a pipe that leaves `open` answers its waiting
requests as it would a post, and one that returns to it posts the next. A
control pipe, EP0, carries one request at a time, so its posts wait in
order. A transfer that completes with a code that halts the endpoint
(every code but success, short packet and the stop codes) halts its pipe;
EP0 is never left halted: the core resets it as `reset_pipe` would before
it answers the request that halted it.

**reset_pipe** first asks the NIF for the queue's state, `idle`, `busy`,
`stopped` or `halted`, and chooses its steps from the answer by plan/3,
the design's table: a halted queue takes Reset Endpoint, then
CLEAR_TT_BUFFER for a control or bulk endpoint of a low- or full-speed
device behind a translator, then CLEAR_FEATURE(ENDPOINT_HALT) for any
endpoint but a control one, then Set TR Dequeue Pointer; a busy queue
takes Stop Endpoint and is planned again as stopped, or as halted when the
stop answers a context state error; a stopped EP0 takes Set TR Dequeue
Pointer and an idle one nothing; any other stopped or idle queue is
dropped and added by Configure Endpoint, then CLEAR_FEATURE(ENDPOINT_HALT).
The steps run one at a time, each on the previous one's success. A request
step is a transfer whose requester is the reset, so answering that
transfer continues the reset; it names the device's reference, so an
answer for a pipe no longer resetting, or for a device that no longer
holds the slot, is stale and changes nothing, even when a new device's
pipe of the same name is resetting. A transfer that halts while the reset's Stop
Endpoint still waits to be posted plans the reset again as halted, since
the NIF accepts only Reset Endpoint on a halted queue. The last step's
success opens the pipe and answers `ok`; a failed step halts it and
answers the step's error.
""".

-export([new/0, step/3, next_deadline/1, capabilities/1]).
-export([completion/1, command_answer/3, transfer_result/2, decode_capabilities/2, port_operation/3, modify/4,
         address_parameters/1]).

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
-type ref() :: erx_usb_bus_core:ref().
-type speed() :: erx_usb_claim:speed().

-doc "A completion code by its name in abi/formats/xhci.txt, or a code that file does not name.".
-type completion() :: atom() | {unknown, integer()}.

-doc "A queue's state as the NIF reports it: open with nothing posted, open with transfers posted, stopped, halted.".
-type queue_report() :: idle | busy | stopped | halted.

-type tt() :: #{hub_slot := slot(), port := 1..?ERX_USB_HUB_PORTS_MAX, multi := boolean()}.
-doc "An addressed device: its address, and the speed and translator its resets are planned by.".
-type device() :: #{address := address(), speed := speed(), tt := none | tt()}.
-doc """
Address Device's parameters as the device NIF takes them (design-usb.md, "What
Erlang names and what the NIF builds"): the route string, the root port, the
port speed ID, the translator and EP0's packet size.
""".
-type address_parameters() :: #{route := 0..16#fffff, root_port := 1..255, speed := 1..15, tt := none | tt(),
                                ep0_packet := pos_integer()}.
-type config() :: #{add := [erx_usb_claim:pipe()], drop := [dci()], hub := term()}.

-doc "A command as the core posts it; the controller process gives it to the NIF in the NIF's form.".
-type command() :: enable_slot
                 | {address_device, slot(), address_parameters()}
                 | {evaluate_context, slot(), #{ep0_packet := pos_integer()}}
                 | {configure_endpoints, slot(), config()}
                 | {stop_endpoint | reset_endpoint | set_tr_dequeue, slot(), dci()}
                 | {disable_slot, slot()}.

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

-type event() :: {bus, erx_usb_bus_link:request()}
               | {pipe, From :: pid(), erx_usb_pipe:request()}
               | {queue_state, pipe(), queue_report()}
               | {complete, tag(), Code :: integer(), Extra :: term()}
               | {refused, tag(), Reason :: term()}
               | {start, bound()}
               | {read, #{register() => non_neg_integer()}}
               | {negotiated, ok | {error, term()}}
               | interrupt
               | {completed, {ok, [nif_event()]} | {error, term()}}
               | expired.

-type action() :: {command, tag(), command()}
               | {transfer, pipe(), tag(), transfer()}
               | {bus, erx_usb_bus_link:answer()}
               | {send, To :: pid(), Message :: term()}
               | {queue_state, pipe()}
               | {read, [register()]}
               | {write, register(), non_neg_integer()}
               | negotiate
               | {negotiate, continue}
               | complete
               | ack
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
-doc """
Who an answer goes to: the bus process for one of its requests; a function
process for one of its requests; the reset of a pipe whose step it is; the
failed Address Device a translator's clear follows, with its answer; or no
one, for a request its abort answers.
""".
-type requester() :: {bus, erx_usb_bus_link:request()}
                   | {pipe, From :: pid(), erx_usb_pipe:request()}
                   | {step, pipe(), ref()}
                   | {tt_clear, requester(), Failed :: {error, term()}}
                   | aborted.

-type step() :: stop_endpoint | reset_endpoint | set_tr_dequeue | drop_add | clear_tt | clear_halt.
-doc """
A reset in progress: who asked, the request whose halt began it with that
request's result, or the request its abort answers `timeout`; and the steps
still to run, the first in flight or waiting its turn, or `{asking, Was}`
while the NIF's report of the queue is awaited, Was the pipe's state when
the reset was asked for.
""".
-type reset() :: #{requester := requester() | {halt, requester(), result()} | {abort, requester()},
                   steps := [step()] | {asking, open | halted}}.

-doc """
A pipe's state. A draining pipe's Activity is `running` while its queue may
still run a transfer posted on it, so its teardown stops it, and `quiet`
once the queue is halted, stopped or was idle at the detach.
""".
-type pipe_state() :: open | halted | {resetting, reset()} | {draining, running | quiet}.
-type pipe_record() :: #{endpoint := #{address := byte(), type := control | bulk | interrupt, atom() => term()},
                         state := pipe_state(),
                         waiting := [{requester(), transfer()}]}.

-doc "What follows a slot's Disable Slot: nothing, or the answer of the failed Address Device that tore it down.".
-type then() :: nothing | {answer_address, requester(), Failed :: {error, term()}, none | tt()}.
-doc """
A held slot: the reference whose Enable Slot it answered, its device once
Address Device succeeds, the hub fields its last Configure Endpoint named,
and, once its teardown has begun, what follows the teardown.
""".
-type slot_record() :: #{ref := ref(), device := none | device(), hub := term(), teardown := none | then()}.

-doc "Who a command is for: the bus process, the reset of a pipe whose step it is, or a slot's teardown.".
-type owner() :: {bus, erx_usb_bus_link:request()} | {reset, pipe()} | {teardown, slot()}.

-doc """
`refs` maps each live reference to its slot, or to `none` before its Enable
Slot succeeds and after its slot's teardown has begun; `inflight` holds
every transfer posted and not yet completed, by tag, with its control
deadline; `command` the one command in flight, with its deadline;
`commands` the commands waiting, oldest first; `port_ops` the root-port
operations whose PORTSC read is awaited, oldest first; `line` the interrupt
line: `idle`, `held` by an interrupt before the controller runs and owed its
`ack`, or `{draining, Events}` while a pass reads the event ring;
`reported` the PORTSC change bits each root port's last `get_status`
reported and no clear has written since; `attached` whether the bus
process has attached; `now`, only while a step runs, the time of the event
it handles, which a control transfer's deadline counts from.
""".
-opaque state() :: #{phase := phase(),
                     line := idle | held | {draining, Events :: non_neg_integer()},
                     capabilities := none | capabilities(),
                     port_ops := [{port_no(), port_op(), requester()}],
                     reported := #{port_no() => non_neg_integer()},
                     attached := boolean(),
                     refs := #{ref() => slot() | none},
                     slots := #{slot() => slot_record()},
                     pipes := #{pipe() => pipe_record()},
                     inflight := #{tag() => {pipe(), requester(), Deadline :: ms() | none}},
                     command := none | {tag(), owner(), command(), Deadline :: ms()},
                     commands := [owner()],
                     now => ms()}.

-define(EP0, 1).

-doc "A controller not yet started, with no slots and nothing in flight.".
-spec new() -> state().
new() ->
    #{phase => stopped, line => idle, capabilities => none, port_ops => [], reported => #{}, attached => false,
      refs => #{}, slots => #{}, pipes => #{}, inflight => #{}, command => none, commands => []}.

-doc "What the controller's capability registers said, for its inspection record, or `none` before they are read.".
-spec capabilities(state()) -> capabilities() | none.
capabilities(#{capabilities := Capabilities}) -> Capabilities.

-doc "The next state on Event, handled at Now, and the actions the controller process performs.".
-spec step(event(), ms(), state()) -> {state(), [action()]}.
step(Event, Now, State) ->
    {Stepped, Reversed} = start_command(Now, event(Event, Now, {State#{now => Now}, []})),
    Next = maps:remove(now, Stepped),
    case [Fail || Fail = {fail, _} <- Reversed] of
        [] -> {Next, lists:reverse(Reversed)};
        Fails -> {Next, [lists:last(Fails)]}
    end.

%% An interrupt held before the controller ran is owed one ack once it runs:
%% given here, and the line left idle; a line not held is left as it is.
release_line({S = #{line := held}, A}) -> emit(ack, {S#{line := idle}, A});
release_line(Acc) -> Acc.

-doc """
The earliest of the command's deadline, the phase's, the start's next poll or
the next status read, and the control transfers' deadlines, or `none`.
""".
-spec next_deadline(state()) -> ms() | none.
next_deadline(#{command := Command, phase := Phase, inflight := Inflight}) ->
    Control = [At || {_Pipe, _Requester, At} <- maps:values(Inflight)],
    case [At || At <- [command_deadline(Command), phase_deadline(Phase) | Control], At =/= none] of
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

event({bus, attach}, _Now, {S = #{phase := Phase}, A}) ->
    Attached = {S#{attached := true}, A},
    case Phase of
        {running, _} -> root_ports(Attached);
        _ -> Attached
    end;
event({bus, Request = {port, root, Port, Op}}, _Now, Acc) ->
    root_port_operation(Port, Op, {bus, Request}, Acc);
event({bus, Request = {control, Ref, _Tag, Setup, Data}}, _Now, Acc) ->
    post_through(Ref, 0, {bus, Request}, {control, Setup, Data}, Acc);
event({bus, Request = {enable_slot, Ref, _Step}}, _Now, {S = #{refs := Refs}, A}) ->
    queue_command({bus, Request}, {S#{refs := Refs#{Ref => none}}, A});
event({bus, Request = {Kind, _Ref, _Step, _Parameters}}, _Now, Acc)
  when Kind =:= address; Kind =:= evaluate_context; Kind =:= configure_endpoints ->
    queue_command({bus, Request}, Acc);
event({bus, Request = {reset_pipe, Ref, _Interface, Address}}, _Now, Acc) ->
    ask_reset(Ref, Address, {bus, Request}, Acc);
event({bus, {detach, Ref}}, _Now, Acc) ->
    detach(Ref, Acc);
event({pipe, From, Request = {control, Pipe, Setup, Data, _Monitor}}, _Now, Acc) ->
    {Ref, Address} = erx_usb_pipe:endpoint(Pipe),
    post_through(Ref, Address, {pipe, From, Request}, {control, Setup, Data}, Acc);
event({pipe, From, Request = {Kind, Pipe, _Tag, Length}}, _Now, Acc) when Kind =:= interrupt_in; Kind =:= bulk_in ->
    {Ref, Address} = erx_usb_pipe:endpoint(Pipe),
    post_through(Ref, Address, {pipe, From, Request}, {normal, {in, Length}}, Acc);
event({pipe, From, Request = {bulk_out, Pipe, _Tag, Data}}, _Now, Acc) ->
    {Ref, Address} = erx_usb_pipe:endpoint(Pipe),
    post_through(Ref, Address, {pipe, From, Request}, {normal, {out, Data}}, Acc);
event({pipe, From, Request = {reset_pipe, Pipe, _Monitor}}, _Now, Acc) ->
    {Ref, Address} = erx_usb_pipe:endpoint(Pipe),
    ask_reset(Ref, Address, {pipe, From, Request}, Acc);
event({queue_state, Pipe, Queue}, _Now, Acc) when Queue =:= idle; Queue =:= busy; Queue =:= stopped;
                                                  Queue =:= halted ->
    queue_reported(Pipe, Queue, Acc);
event({complete, Tag, Code, Extra}, _Now, {S = #{command := {Tag, Owner, Command, _}}, A}) ->
    commanded(Owner, Command, command_answer(kind(Command), Code, Extra), {S#{command := none}, A});
event({complete, Tag, Code, Extra}, _Now, {S = #{inflight := Inflight}, A}) ->
    case maps:take(Tag, Inflight) of
        {{Pipe, Requester, _At}, Rest} -> transferred(Pipe, Requester, transfer_result(Code, Extra), {S#{inflight := Rest}, A});
        error -> emit({fail, {unknown_tag, Tag}}, {S, A})
    end;
event({refused, Tag, Reason}, _Now, Acc = {#{command := {Tag, _, Command, _}}, _}) ->
    emit({fail, {refused, Command, Reason}}, Acc);
event({refused, Tag, Reason}, _Now, {S = #{inflight := Inflight}, A}) ->
    case maps:take(Tag, Inflight) of
        {{Pipe, Requester, _At}, Rest} -> answer(Requester, {error, Reason}, post_waiting(Pipe, {S#{inflight := Rest}, A}));
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
event(expired, Now, Acc) ->
    command_expired(Now, phase_expired(Now, control_expired(Now, Acc)));
event(Event, _Now, Acc) ->
    emit({fail, {unexpected, Event}}, Acc).

command_expired(Now, Acc = {#{command := {_Tag, _Owner, Command, At}}, _}) when At =< Now ->
    emit({fail, {command_timeout, Command}}, Acc);
command_expired(_Now, Acc) ->
    Acc.

%% The bus process's answer to its attach, the root hub's port count.
root_ports(Acc = {#{capabilities := #{ports := Ports}}, _}) ->
    emit({bus, {root_ports, Ports}}, Acc).

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

negotiated(ok, Now, Acc = {#{attached := Attached}, _}) ->
    Running = set_phase({running, Now + ?ERX_XHCI_STATUS_INTERVAL_MS}, Acc),
    release_line(case Attached of
                     true -> root_ports(Running);
                     false -> Running
                 end);
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
    emit({negotiate, continue}, set_phase({installing, Deadline, calling}, Acc));
phase_expired(Now, Acc = {#{phase := {running, At}}, _}) when At =< Now ->
    emit({read, [usbsts]}, set_phase({running, Now + ?ERX_XHCI_STATUS_INTERVAL_MS}, Acc));
phase_expired(_Now, Acc) ->
    Acc.

set_phase(Phase, {S, A}) -> {S#{phase := Phase}, A}.

set_line(Line, {S, A}) -> {S#{line := Line}, A}.

%% Reads, by the registers answered

read([{{legacy, bios_owned}, Byte}], Now, Acc = {#{phase := {bios_handoff, _, reading}}, _}) ->
    bios_owned(Byte, Now, Acc);
read([{{portsc, Port}, Word}], _Now, {S = #{port_ops := Ops, reported := Reported}, A}) when is_integer(Word) ->
    case lists:keytake(Port, 1, Ops) of
        {value, {Port, Op, Requester}, Rest} ->
            {Writes, Answer, StillReported} = port_operation(Op, Word, maps:get(Port, Reported, 0)),
            Next = {S#{port_ops := Rest, reported := Reported#{Port => StillReported}}, A},
            Written = lists:foldl(fun(Write, In) -> emit({write, {portsc, Port}, Write}, In) end, Next, Writes),
            answer(Requester, Answer, Written);
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
        true -> port_event(Port, Acc);
        false -> emit({fail, {malformed_event, {port, Port}}}, Acc)
    end;
nif_event({Tag, Code, Extra}, Now, Acc) ->
    event({complete, Tag, Code, Extra}, Now, Acc);
nif_event(Event, _Now, Acc) ->
    emit({fail, {malformed_event, Event}}, Acc).

%% A root port's event goes to the bus process once it has its root ports;
%% before then the bus core reads every root port when it starts.
port_event(Port, Acc = {#{attached := true}, _}) -> emit({bus, {port_event, Port}}, Acc);
port_event(_Port, Acc) -> Acc.

%% A port of the root hub: 1 to the port count the capability registers read.
root_port(Port, {#{capabilities := #{ports := Ports}}, _}) ->
    is_integer(Port) andalso Port >= 1 andalso Port =< Ports.

%% Root ports

%% The bus process's operation Op on root port Port: its PORTSC read, the
%% operation done when the read is answered; refused before the controller
%% runs and for a port outside the port count.
root_port_operation(Port, Op, Requester, Acc = {#{phase := {running, _}}, _}) ->
    case root_port(Port, Acc) of
        true ->
            {S = #{port_ops := Ops}, A} = Acc,
            emit({read, [{portsc, Port}]}, {S#{port_ops := Ops ++ [{Port, Op, Requester}]}, A});
        false ->
            answer(Requester, {error, badarg}, Acc)
    end;
root_port_operation(_Port, _Op, Requester, Acc) ->
    answer(Requester, {error, halted}, Acc).

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

queue_command(Owner, {S = #{commands := Commands}, A}) ->
    {S#{commands := Commands ++ [Owner]}, A}.

%% Owner's next command, posted before every waiting one.
continue_command(Owner, {S = #{commands := Commands}, A}) ->
    {S#{commands := [Owner | Commands]}, A}.

%% Posts the first waiting command when none is in flight. Each entry is
%% resolved when its turn comes: a bus command through its reference, so one
%% whose device detached is answered `{error, gone}` and never posted; a
%% reset's as its first step stands now, so a reset planned again while it
%% waited posts its new first step, and one whose pipe is no longer resetting
%% is dropped; a teardown's as its slot's next step. Tags of commands and
%% transfers are one namespace.
start_command(Now, {S = #{command := none, commands := [Owner | Waiting], inflight := Inflight}, A}) ->
    Next = {S#{commands := Waiting}, A},
    case owned_command(Owner, S) of
        {ok, Command} ->
            Tag = tag(Inflight, 0, S),
            emit({command, Tag, Command},
                 {S#{command := {Tag, Owner, Command, Now + ?ERX_XHCI_COMMAND_DEADLINE_MS}, commands := Waiting}, A});
        stale ->
            start_command(Now, Next);
        gone ->
            start_command(Now, answer(Owner, {error, gone}, Next))
    end;
start_command(_Now, Acc) ->
    Acc.

owned_command({bus, {enable_slot, Ref, _Step}}, #{refs := Refs}) ->
    case is_map_key(Ref, Refs) of
        true -> {ok, enable_slot};
        false -> gone
    end;
owned_command({bus, {address, Ref, _Step, Parameters}}, S) ->
    on_slot(Ref, S, fun(Slot) -> {address_device, Slot, address_parameters(Parameters)} end);
owned_command({bus, {evaluate_context, Ref, _Step, Context}}, S) ->
    on_slot(Ref, S, fun(Slot) -> {evaluate_context, Slot, Context} end);
owned_command({bus, {configure_endpoints, Ref, _Step, #{add := Add, hub := Hub}}}, S) ->
    {Part, _Left} = configure_part(Add),
    on_slot(Ref, S, fun(Slot) -> {configure_endpoints, Slot, #{add => Part, drop => [], hub => Hub}} end);
owned_command({reset, Pipe = {Slot, Dci}}, #{pipes := Pipes, slots := Slots}) ->
    case Pipes of
        #{Pipe := #{state := {resetting, #{steps := [drop_add | _]}}, endpoint := Endpoint}} ->
            #{Slot := #{hub := Hub}} = Slots,
            {ok, {configure_endpoints, Slot, #{add => [Endpoint], drop => [Dci], hub => Hub}}};
        #{Pipe := #{state := {resetting, #{steps := [Step | _]}}}}
          when Step =:= stop_endpoint; Step =:= reset_endpoint; Step =:= set_tr_dequeue ->
            {ok, {Step, Slot, Dci}};
        #{} ->
            stale
    end;
owned_command({teardown, Slot}, #{pipes := Pipes, inflight := Inflight}) ->
    Running = [Dci || {{PipeSlot, Dci}, #{state := {draining, running}}} <- lists:sort(maps:to_list(Pipes)),
                      PipeSlot =:= Slot, posted({Slot, Dci}, Inflight)],
    case Running of
        [Dci | _] -> {ok, {stop_endpoint, Slot, Dci}};
        [] -> {ok, {disable_slot, Slot}}
    end.

%% The command Build makes for the slot live reference Ref is bound to, or
%% `gone`.
on_slot(Ref, #{refs := Refs}, Build) ->
    case Refs of
        #{Ref := Slot} when is_integer(Slot) -> {ok, Build(Slot)};
        #{} -> gone
    end.

%% A command's decoded answer, to the bus process, to the reset whose step it
%% is or to the teardown of its slot. Stop Endpoint answers a success or a
%% context state error; any other code fails the controller (4.6.9, p. 140).
commanded(_Owner, Command, malformed, Acc) ->
    emit({fail, {malformed_answer, Command}}, Acc);
commanded(_Owner, Command = {stop_endpoint, _, _}, {error, Reason}, Acc) when Reason =/= context_state_error ->
    emit({fail, {command_failed, Command, Reason}}, Acc);
commanded({bus, Request}, Command, Answer, Acc) ->
    bus_done(Request, Command, Answer, Acc);
commanded({reset, Pipe}, _Command, Answer, Acc) ->
    step_answered(Pipe, Answer, Acc);
commanded({teardown, Slot}, Command, Answer, Acc) ->
    torn(Slot, Command, Answer, Acc).

%% A bus command's answer, with what its success changes. Enable Slot binds
%% the reference to its slot, or tears the slot down when the reference
%% detached meanwhile; Address Device adds the device and its EP0 pipe, and
%% its failure tears the slot down before it is answered; a part of the bus's
%% Configure Endpoint adds the pipes it names and continues the request with
%% the adds left, which the request carries until its last part answers it
%% (an answer names only the request's reference and step). A device that
%% detached while its command was in flight gets nothing added, its teardown
%% already waiting. Each command has its own clauses, so one of a shape the
%% core does not know fails loudly.
bus_done({enable_slot, _Ref, _Step}, enable_slot, {ok, Slot}, Acc = {#{slots := Slots}, _})
  when is_map_key(Slot, Slots) ->
    emit({fail, {malformed_answer, enable_slot}}, Acc);
bus_done(Request = {enable_slot, Ref, _Step}, enable_slot, {ok, Slot}, {S = #{refs := Refs, slots := Slots}, A}) ->
    Enabled = {S#{slots := Slots#{Slot => #{ref => Ref, device => none, hub => none, teardown => none}}}, A},
    case Refs of
        #{Ref := none} -> answer({bus, Request}, {ok, Slot}, bind(Ref, Slot, Enabled));
        #{} -> answer({bus, Request}, {error, gone}, tear_down(Slot, nothing, Enabled))
    end;
bus_done(Request = {enable_slot, _Ref, _Step}, enable_slot, Failed = {error, _}, Acc) ->
    answer({bus, Request}, Failed, Acc);
bus_done(Request = {address, Ref, _Step, #{speed := Speed, tt := Tt}}, {address_device, Slot, _}, {ok, Address},
         Acc = {S, A}) ->
    Added = case live(Ref, Slot, S) of
                true ->
                    #{slots := Slots = #{Slot := Record}, pipes := Pipes} = S,
                    Ep0 = #{endpoint => #{address => 0, type => control}, state => open, waiting => []},
                    {S#{slots := Slots#{Slot := Record#{device := #{address => Address, speed => Speed, tt => Tt}}},
                        pipes := Pipes#{{Slot, ?EP0} => Ep0}}, A};
                false ->
                    Acc
            end,
    answer({bus, Request}, {ok, Address}, Added);
bus_done(Request = {address, Ref, _Step, #{tt := Tt}}, {address_device, Slot, _}, Failed = {error, _}, Acc = {S, _}) ->
    Unbound = case live(Ref, Slot, S) of
                  true -> bind(Ref, none, Acc);
                  false -> Acc
              end,
    tear_down(Slot, {answer_address, {bus, Request}, Failed, Tt}, Unbound);
bus_done(Request = {evaluate_context, _Ref, _Step, _Context}, {evaluate_context, _Slot, _}, Answer, Acc) ->
    answer({bus, Request}, Answer, Acc);
bus_done(Request = {configure_endpoints, Ref, Step, Config = #{add := Add}},
         {configure_endpoints, Slot, #{add := Part, hub := Hub}}, ok, Acc = {S, A}) ->
    case live(Ref, Slot, S) of
        true ->
            #{slots := Slots = #{Slot := Record}, pipes := Pipes} = S,
            New = maps:from_list([{{Slot, dci(EpAddress)}, #{endpoint => Endpoint, state => open, waiting => []}}
                                  || Endpoint = #{address := EpAddress} <- Part]),
            Added = {S#{slots := Slots#{Slot := Record#{hub := Hub}}, pipes := maps:merge(Pipes, New)}, A},
            case configure_part(Add) of
                {_Part, []} -> answer({bus, Request}, ok, Added);
                {_Part, Left} -> continue_command({bus, {configure_endpoints, Ref, Step, Config#{add := Left}}}, Added)
            end;
        false ->
            answer({bus, Request}, ok, Acc)
    end;
bus_done(Request = {configure_endpoints, _Ref, _Step, _}, {configure_endpoints, _Slot, _}, Failed = {error, _}, Acc) ->
    answer({bus, Request}, Failed, Acc).

%% The adds of the bus's Configure Endpoint split into the part posted next,
%% at most the bindings one command carries, and those left for later parts.
configure_part(Add) ->
    lists:split(min(length(Add), ?ERX_XHCI_CONFIGURE_ADDS_MAX), Add).

-doc """
Address Device's parameters as the device NIF takes them, from the bus
core's: the route string, four bits a tier below the root port, the first
tier lowest (6.2.2, Table 6-4, p. 444; 4.3.3, p. 88); the speed as its port
speed ID (abi/formats/xhci.txt); and EP0's packet size at that speed, the
only one allowed at low, high and SuperSpeed and at full speed the one its
device descriptor's first 8 bytes are read with (4.3, p. 85). The slot is
the one the device's reference is bound to, not one the bus names.
""".
-spec address_parameters(erx_usb_bus_core:address_params()) -> address_parameters().
address_parameters(#{route := Tiers, root_port := RootPort, speed := Speed, tt := Tt}) ->
    #{route => lists:foldr(fun(Port, Route) -> (Route bsl ?ERX_XHCI_ROUTE_TIER_BITS) bor Port end, 0, Tiers),
      root_port => RootPort, speed => speed_id(Speed), tt => Tt, ep0_packet => ep0_packet(Speed)}.

speed_id(low) -> ?ERX_XHCI_SPEED_LOW;
speed_id(full) -> ?ERX_XHCI_SPEED_FULL;
speed_id(high) -> ?ERX_XHCI_SPEED_HIGH;
speed_id(super) -> ?ERX_XHCI_SPEED_SUPER.

ep0_packet(low) -> ?ERX_USB_EP0_PACKET_LOW;
ep0_packet(full) -> ?ERX_USB_EP0_PACKET_FULL_FIRST;
ep0_packet(high) -> ?ERX_USB_EP0_PACKET_HIGH;
ep0_packet(super) -> ?ERX_USB_EP0_PACKET_SUPER.

%% Device references

bind(Ref, SlotOrNone, {S = #{refs := Refs}, A}) -> {S#{refs := Refs#{Ref := SlotOrNone}}, A}.

live(Ref, Slot, #{refs := Refs}) -> maps:get(Ref, Refs, none) =:= Slot.

%% The pipe of endpoint EpAddress of the live device Ref, or `gone`: the one
%% lookup every request through a reference takes.
lookup(Ref, EpAddress, #{refs := Refs, pipes := Pipes}) ->
    case Refs of
        #{Ref := Slot} when is_integer(Slot) ->
            Pipe = {Slot, dci(EpAddress)},
            case is_map_key(Pipe, Pipes) of
                true -> {ok, Pipe};
                false -> gone
            end;
        #{} ->
            gone
    end.

post_through(Ref, EpAddress, Requester, Transfer, Acc = {S, _}) ->
    case lookup(Ref, EpAddress, S) of
        {ok, Pipe} -> post(Pipe, Requester, Transfer, Acc);
        gone -> answer(Requester, {error, gone}, Acc)
    end.

%% A detached reference names nothing from now on, and its slot, when it has
%% one, is torn down.
detach(Ref, {S = #{refs := Refs}, A}) ->
    Unbound = {S#{refs := maps:remove(Ref, Refs)}, A},
    case Refs of
        #{Ref := Slot} when is_integer(Slot) -> tear_down(Slot, nothing, Unbound);
        #{} -> Unbound
    end.

%% Teardown

%% Begins Slot's teardown, Then to follow its Disable Slot: its pipes drain,
%% and its next step waits its turn. A teardown already begun, by a detach
%% while the slot's Address Device was posted, takes the failed address's
%% answer to follow it.
tear_down(Slot, Then, {S = #{slots := Slots, pipes := Pipes}, A}) ->
    #{Slot := Record = #{teardown := Teardown}} = Slots,
    Marked = {S#{slots := Slots#{Slot := Record#{teardown := Then}}}, A},
    case Teardown of
        none ->
            Drained = lists:sort([Pipe || Pipe = {PipeSlot, _} <- maps:keys(Pipes), PipeSlot =:= Slot]),
            queue_command({teardown, Slot}, lists:foldl(fun drain/2, Marked, Drained));
        _Begun ->
            Marked
    end.

%% A pipe of a slot being torn down: its reset's requester and the requests
%% waiting on it answered `{error, gone}`, and whether its queue may still run
%% a posted transfer kept.
drain(Pipe, Acc = {#{pipes := Pipes}, _}) ->
    case Pipes of
        #{Pipe := #{state := PipeState = {resetting, #{requester := Requester}}}} ->
            Activity = activity(Pipe, PipeState, Acc),
            answer(asked_by(Requester), {error, gone}, set_pipe(Pipe, {draining, Activity}, Acc));
        #{Pipe := #{state := PipeState}} ->
            set_pipe(Pipe, {draining, activity(Pipe, PipeState, Acc)}, Acc)
    end.

asked_by({halt, Requester, _Result}) -> Requester;
asked_by({abort, Requester}) -> Requester;
asked_by(Requester) -> Requester.

%% Whether a pipe's queue may still run a posted transfer, from the pipe's
%% state: an open queue with a transfer posted does, as does a reset's queue
%% whose Stop Endpoint waits to be posted; a halted pipe's queue is halted or
%% stopped, a stop in flight leaves its queue stopped or halted, and a
%% reset's later steps run on a queue that is halted, stopped or idle.
activity(Pipe, open, Acc) -> running_if_posted(Pipe, Acc);
activity(Pipe, {resetting, #{steps := {asking, open}}}, Acc) -> running_if_posted(Pipe, Acc);
activity(Pipe, {resetting, #{steps := [stop_endpoint | _]}}, Acc) ->
    case reset_command_in_flight(Pipe, Acc) of
        true -> quiet;
        false -> running_if_posted(Pipe, Acc)
    end;
activity(_Pipe, _HaltedOrResetting, _Acc) -> quiet.

running_if_posted(Pipe, {#{inflight := Inflight}, _}) ->
    case posted(Pipe, Inflight) of
        true -> running;
        false -> quiet
    end.

posted(Pipe, Inflight) -> lists:keymember(Pipe, 1, maps:values(Inflight)).

%% A teardown command's answer. A stop leaves its queue halted or stopped,
%% and the next step waits its turn; Disable Slot's success frees the slot and
%% its pipes, every transfer posted on them already answered, and runs what
%% follows. Any other answer fails the controller.
torn(Slot, {stop_endpoint, Slot, Dci}, Answer, Acc) when Answer =:= ok; Answer =:= {error, context_state_error} ->
    queue_command({teardown, Slot}, set_pipe({Slot, Dci}, {draining, quiet}, Acc));
torn(Slot, {disable_slot, Slot}, ok, {S = #{slots := Slots, pipes := Pipes}, A}) ->
    #{Slot := #{teardown := Then}} = Slots,
    then(Then, {S#{slots := maps:remove(Slot, Slots),
                   pipes := maps:filter(fun({PipeSlot, _Dci}, _Record) -> PipeSlot =/= Slot end, Pipes)}, A});
torn(_Slot, Command, {error, Reason}, Acc) ->
    emit({fail, {command_failed, Command, Reason}}, Acc).

%% What follows a slot's Disable Slot. A failed Address Device is answered
%% now, or, on a USB Transaction Error behind a translator, once
%% CLEAR_TT_BUFFER for the default control endpoint at address 0 has cleared
%% the translator's buffer (4.6.5, p. 115).
then(nothing, Acc) ->
    Acc;
then({answer_address, Requester, Failed, Tt}, Acc) ->
    TransactionError = {error, {address, completion(?ERX_XHCI_COMPLETION_TRANSACTION_ERROR)}},
    case {Failed, Tt} of
        {TransactionError, #{}} ->
            {Hub, Request} = tt_clear(#{address => 0, type => control}, 0, Tt),
            post({Hub, ?EP0}, {tt_clear, Requester, Failed}, Request, Acc);
        _ ->
            answer(Requester, Failed, Acc)
    end.

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
            case posted(Pipe, Inflight) of
                true -> Acc;
                false -> send(Pipe, Requester, Transfer, {S#{pipes := Pipes#{Pipe := Record#{waiting := Rest}}}, A})
            end;
        #{} ->
            Acc
    end.

%% A control transfer is posted with its deadline; others wait as long as
%% their device takes.
send(Pipe, Requester, Transfer, {S = #{inflight := Inflight, now := Now}, A}) ->
    Tag = tag(Inflight, 0, S),
    Deadline = case Transfer of
                   {control, _Setup, _Data} -> Now + ?ERX_XHCI_CONTROL_DEADLINE_MS;
                   {normal, _Data} -> none
               end,
    emit({transfer, Pipe, Tag, Transfer}, {S#{inflight := Inflight#{Tag => {Pipe, Requester, Deadline}}}, A}).

%% A transfer's result. One that halts the endpoint halts an open pipe, or,
%% on EP0, begins its reset, the request answered when the reset ends; on a
%% resetting pipe whose Stop Endpoint is not yet posted, it plans the reset
%% again as halted; on a draining pipe it leaves the queue quiet.
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
        {true, #{Pipe := #{state := {draining, running}}}} ->
            answer(Requester, Result, set_pipe(Pipe, {draining, quiet}, Acc));
        _ ->
            answer(Requester, Result, post_waiting(Pipe, Acc))
    end.

reset_command_in_flight(Pipe, {#{command := Command}, _}) ->
    case Command of
        {_Tag, {reset, Pipe}, _, _} -> true;
        _ -> false
    end.

%% Aborting a control request

%% The control transfers whose deadlines have passed: each on an open pipe is
%% aborted, and one on a pipe that is resetting or draining is left to that
%% reset or teardown, which answers it; either way its deadline is spent.
control_expired(Now, Acc = {#{inflight := Inflight}, _}) ->
    Due = lists:sort([Tag || Tag := {_Pipe, _Requester, At} <- Inflight, At =/= none, At =< Now]),
    lists:foldl(fun abort/2, Acc, Due).

abort(Tag, {S = #{inflight := Inflight, pipes := Pipes}, A}) ->
    #{Tag := {Pipe, Requester, _At}} = Inflight,
    case Pipes of
        #{Pipe := #{state := open}} ->
            begin_reset(Pipe, {abort, Requester}, busy, {S#{inflight := Inflight#{Tag := {Pipe, aborted, none}}}, A});
        #{} ->
            {S#{inflight := Inflight#{Tag := {Pipe, Requester, none}}}, A}
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
refusal({resetting, _}) -> resetting;
refusal({draining, _}) -> gone.

%% reset_pipe

%% A reset of a pipe, the bus process's for a function that ended or a
%% function's own (erx_usb_pipe:reset_pipe/1): the pipe resets at
%% once, asking the NIF for its queue's state, or answers that it is already
%% resetting or gone.
ask_reset(Ref, EpAddress, Requester, Acc = {S = #{pipes := Pipes}, _}) ->
    case lookup(Ref, EpAddress, S) of
        {ok, Pipe} ->
            case Pipes of
                #{Pipe := #{state := {resetting, _}}} ->
                    answer(Requester, {error, resetting}, Acc);
                #{Pipe := #{state := Was}} ->
                    emit({queue_state, Pipe},
                         set_pipe(Pipe, {resetting, #{requester => Requester, steps => {asking, Was}}}, Acc))
            end;
        gone ->
            answer(Requester, {error, gone}, Acc)
    end.

%% The NIF's report of a pipe whose reset asked for it plans the reset; a
%% report for a pipe that has gone with its device changes nothing.
queue_reported(Pipe, Queue, Acc = {#{pipes := Pipes}, _}) ->
    case Pipes of
        #{Pipe := #{state := {resetting, Reset = #{steps := {asking, _Was}}}}} -> replan(Pipe, Reset, Queue, Acc);
        #{} -> Acc
    end.

begin_reset(Pipe, Requester, Queue, Acc) ->
    replan(Pipe, #{requester => Requester}, Queue, Acc).

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

%% The reset of Pipe planned from Queue and started.
replan(Pipe = {Slot, _}, Reset, Queue, Acc = {#{pipes := Pipes, slots := Slots}, _}) ->
    #{Pipe := #{endpoint := Endpoint}} = Pipes,
    #{Slot := #{device := Device}} = Slots,
    advance(Pipe, set_pipe(Pipe, {resetting, Reset#{steps => plan(Queue, Endpoint, Device)}}, Acc)).

%% Starts a reset's first step: a command waits its turn; a request posts on
%% the EP0 it goes to; no step left ends the reset. A replanned reset whose
%% command is already waiting keeps its one place.
advance(Pipe = {Slot, _}, Acc = {S = #{pipes := Pipes, slots := Slots, commands := Commands}, A}) ->
    #{Pipe := #{state := {resetting, #{steps := Steps}}, endpoint := Endpoint}} = Pipes,
    #{Slot := #{ref := Ref}} = Slots,
    case Steps of
        [] ->
            finish(Pipe, ok, Acc);
        [clear_tt | _] ->
            #{Slot := #{device := #{address := Address, tt := Tt}}} = Slots,
            {Hub, Request} = tt_clear(Endpoint, Address, Tt),
            post({Hub, ?EP0}, {step, Pipe, Ref}, Request, Acc);
        [clear_halt | _] ->
            post({Slot, ?EP0}, {step, Pipe, Ref}, endpoint_clear(Endpoint), Acc);
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
        {#{Pipe := #{state := {resetting, #{steps := [_ | _]}}}}, {error, Reason}} ->
            finish(Pipe, {error, Reason}, Acc);
        {#{Pipe := #{state := {resetting, Reset = #{steps := [_Done | Rest]}}}}, _Success} ->
            advance(Pipe, set_pipe(Pipe, {resetting, Reset#{steps := Rest}}, Acc));
        _Stale ->
            Acc
    end.

%% Ends a reset: success opens the pipe, failure halts it. A reset begun by
%% a halt answers the request that halted with that request's own result; an
%% abort's success answers the aborted request `timeout`, and its failure
%% fails the controller.
finish(Pipe, Outcome, Acc = {#{pipes := Pipes}, _}) ->
    #{Pipe := #{state := {resetting, #{requester := Requester}}}} = Pipes,
    Settled = case Outcome of
                  ok -> open;
                  {error, _} -> halted
              end,
    case {Requester, Outcome} of
        {{abort, _Aborted}, {error, Reason}} -> emit({fail, {abort_failed, Pipe, Reason}}, Acc);
        {{abort, Aborted}, ok} -> answer(Aborted, {error, timeout}, set_pipe(Pipe, open, Acc));
        {{halt, Halted, Result}, _} -> answer(Halted, Result, set_pipe(Pipe, Settled, Acc));
        {_, _} -> answer(Requester, Outcome, set_pipe(Pipe, Settled, Acc))
    end.

%% CLEAR_TT_BUFFER to the translator's hub, for the endpoint by its number,
%% direction and type at device address Address; wIndex the translator's
%% port, or 1 on a hub with one translator (FreeBSD's
%% usbd_req_clear_tt_buffer, usb_request.c:2246-2270): the hub's slot and the
%% request.
tt_clear(#{address := EpAddress, type := Type}, Address, #{hub_slot := Hub, port := Port, multi := Multi}) ->
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
endpoint_clear(#{address := EpAddress}) ->
    {control, erx_usb_setup:packet(?ERX_USB_REQUEST_TYPE_STANDARD bor ?ERX_USB_RECIPIENT_ENDPOINT,
                                   ?ERX_USB_REQUEST_CLEAR_FEATURE, ?ERX_USB_FEATURE_ENDPOINT_HALT, EpAddress, 0), none}.

%% Answers

%% Answers Requester with Answer: the bus process's and a function's requests
%% in the messages their modules spell; a reset's step continues its reset; a
%% translator's clear answers the failed Address Device it follows, with that
%% command's answer or the clear's failure; an aborted request's own
%% completion is dropped, since its abort answers it.
answer({bus, Request}, Answer, Acc) ->
    emit({bus, erx_usb_bus_link:reply(Request, Answer)}, Acc);
answer({pipe, From, Request}, Answer, Acc) ->
    emit({send, From, erx_usb_pipe:reply(Request, Answer)}, Acc);
%% A request step's answer reaches its reset only while the device that
%% posted it still holds the slot: a slot enabled again for another device,
%% whose pipe of the same name may be resetting, takes no answer of the
%% device before it.
answer({step, Pipe = {Slot, _}, Ref}, Answer, Acc = {S, _}) ->
    case live(Ref, Slot, S) of
        true -> step_answered(Pipe, Answer, Acc);
        false -> Acc
    end;
answer({tt_clear, Requester, Failed}, {ok, _Bytes}, Acc) ->
    answer(Requester, Failed, Acc);
answer({tt_clear, Requester, _Failed}, {error, Reason}, Acc) ->
    answer(Requester, {error, {tt_clear, Reason}}, Acc);
answer(aborted, _Answer, Acc) ->
    Acc.

emit(Action, {S, A}) -> {S, [Action | A]}.

%% The lowest tag no post in flight holds.
tag(Inflight, N, S = #{command := {N, _, _, _}}) -> tag(Inflight, N + 1, S);
tag(Inflight, N, S) when is_map_key(N, Inflight) -> tag(Inflight, N + 1, S);
tag(_Inflight, N, _S) -> N.

%% An endpoint's device context index: twice its number, plus one for IN,
%% and EP0's 1 (xHCI 4.5.1).
dci(EpAddress) when EpAddress band ?ERX_USB_ENDPOINT_NUMBER_MASK =:= 0 -> ?EP0;
dci(EpAddress) -> 2 * (EpAddress band ?ERX_USB_ENDPOINT_NUMBER_MASK) + direction(EpAddress).

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
