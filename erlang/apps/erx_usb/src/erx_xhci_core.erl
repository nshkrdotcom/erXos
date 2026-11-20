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
a step that fails answers that action alone, so nothing after it is posted.
The process feeds back every completion the NIF returns, `{complete, Tag,
Code, Extra}`, and every post the NIF refuses, `{refused, Tag, Reason}`.
Tags are the core's: the lowest number no post in flight holds.

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

-export([new/0, step/3, next_deadline/1]).
-export([completion/1, command_answer/3, transfer_result/2]).

-export_type([state/0, event/0, action/0, pipe/0, command/0, completion/0]).

-include("generated/erx_abi.hrl").

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

-type event() :: {command, From :: term(), bus_command()}
               | {post, From :: term(), pipe(), transfer()}
               | {reset_pipe, From :: term(), pipe(), queue_report()}
               | {complete, tag(), Code :: integer(), Extra :: term()}
               | {refused, tag(), Reason :: term()}
               | expired.

-type action() :: {command, tag(), command()}
               | {transfer, pipe(), tag(), transfer()}
               | {reply, From :: term(), Answer :: term()}
               | {fail, Reason :: term()}.

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
commands waiting, oldest first.
""".
-opaque state() :: #{slots := #{slot() => slot_record()},
                     pipes := #{pipe() => pipe_record()},
                     inflight := #{tag() => {pipe(), requester()}},
                     command := none | {tag(), owner(), command(), Deadline :: ms()},
                     commands := [owner()]}.

-define(EP0, 1).
-define(IS_BUS_COMMAND(C), (C =:= enable_slot orelse element(1, C) =:= address_device
                            orelse element(1, C) =:= evaluate_context orelse element(1, C) =:= configure_endpoints)).

-doc "A controller with no slots and nothing in flight.".
-spec new() -> state().
new() ->
    #{slots => #{}, pipes => #{}, inflight => #{}, command => none, commands => []}.

-doc "The next state on Event, handled at Now, and the actions the controller process performs.".
-spec step(event(), ms(), state()) -> {state(), [action()]}.
step(Event, Now, State) ->
    {Next, Reversed} = start_command(Now, event(Event, Now, {State, []})),
    case [Fail || Fail = {fail, _} <- Reversed] of
        [] -> {Next, lists:reverse(Reversed)};
        Fails -> {Next, [lists:last(Fails)]}
    end.

-doc "The deadline of the command in flight, or `none`.".
-spec next_deadline(state()) -> ms() | none.
next_deadline(#{command := none}) -> none;
next_deadline(#{command := {_Tag, _Owner, _Command, At}}) -> At.

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
event(expired, Now, Acc = {#{command := {_Tag, _Owner, Command, At}}, _}) when At =< Now ->
    emit({fail, {command_timeout, Command}}, Acc);
event(expired, _Now, Acc) ->
    Acc.

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
    {Hub, {control, setup(?ERX_USB_REQUEST_TYPE_CLASS bor ?ERX_USB_RECIPIENT_OTHER,
                          ?ERX_USB_HUB_REQUEST_CLEAR_TT_BUFFER, Value, Index), none}}.

transfer_type(control) -> ?ERX_USB_TRANSFER_TYPE_CONTROL;
transfer_type(bulk) -> ?ERX_USB_TRANSFER_TYPE_BULK.

%% CLEAR_FEATURE(ENDPOINT_HALT) to the endpoint, which resets the device's
%% side of its toggle.
endpoint_clear(Pipe, #{pipes := Pipes}) ->
    #{Pipe := #{endpoint := #{address := EpAddress}}} = Pipes,
    {control, setup(?ERX_USB_REQUEST_TYPE_STANDARD bor ?ERX_USB_RECIPIENT_ENDPOINT,
                    ?ERX_USB_REQUEST_CLEAR_FEATURE, ?ERX_USB_FEATURE_ENDPOINT_HALT, EpAddress), none}.

setup(RequestType, Request, Value, Index) ->
    <<RequestType, Request, Value:16/little, Index:16/little, 0:16/little>>.

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
