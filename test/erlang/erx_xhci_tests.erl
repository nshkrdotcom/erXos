%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Host tests of the controller process, erx_xhci (docs/design-usb.md, "The controller
%% process"), over erx_device's stand-in for a device the test process plays: the test
%% answers each NIF call the process makes, in the order it makes them, acts as the bus
%% process through erx_usb_bus_link, and delivers the interrupts itself. The decisions are
%% erx_xhci_core's, tested on their own; these cases check that the process performs each
%% action, feeds each answer back, arms its timer and ends on a failure.

-module(erx_xhci_tests).

-include_lib("eunit/include/eunit.hrl").

-define(IRQ_LINE, 0).
-define(SUCCESS, 1).
-define(REF, {device, 1}).
-define(SLOT, 2).
-define(ADDRESS, 5).
-define(GET_STATUS, <<16#80, 0, 0:16, 0:16, 2:16/little>>).
%% USBSTS with its event interrupt set; IMAN with interrupt pending and enabled.
-define(EINT, 16#8).
-define(IMAN, 16#3).
%% HCSPARAMS1: 32 slots, 1 interrupter, 4 ports; HCSPARAMS2: no scratchpads; HCCPARAMS1:
%% AC64; PAGESIZE: 4 KiB. Protocol 0: USB 2 on ports 1-2; protocol 1: USB 3 on ports 3-4.
-define(CAPABILITIES, [{hcsparams1, 16#04000120}, {hcsparams2, 0}, {hccparams1, 1}, {pagesize, 1},
                       {{revision, 0}, 16#02000802}, {{ports, 0}, 16#0201},
                       {{revision, 1}, 16#03000002}, {{ports, 1}, 16#0203}]).

%% The start reads the capabilities under the NIF's names, calls the install again on its
%% timer while it is busy, holds an interrupt that comes before the controller runs and
%% acknowledges it once it does, answers the bus's attach with the root ports, and reads
%% USBSTS about once a second with no interrupt.
the_controller_starts_and_answers_its_bus_test() ->
    Controller = start(),
    ?assertEqual({elements, bios_owned}, play(0)),
    ?assertEqual({elements, revision}, play(2)),
    [?assertEqual({read, Register}, play(Word)) || {Register, Word} <- ?CAPABILITIES],
    ?assertEqual({negotiate, 0}, play({error, ebusy})),
    Controller ! {erx_irq, device(), ?IRQ_LINE},
    %% The retry after ebusy carries the negotiation on; only the first call begins one. The
    %% reset's end, a controller that is no PCIe function goes on from at once.
    ?assertEqual({negotiate, continue}, play(reset)),
    ?assertEqual({negotiate, continue}, play({ok, 0})),
    ?assertEqual({ack, ?IRQ_LINE}, play(ok)),
    ok = erx_usb_bus_link:attach(Controller),
    ?assertEqual({root_ports, 4}, bus_answer()),
    ?assertEqual({read, usbsts}, play(0)),
    stop(Controller).

%% A controller that is a PCIe function opens it through the pci facet before it opens its
%% device, and masters it once the negotiation answers that the reset has ended, before the
%% call that installs, so the controller reads and writes memory only once it may
%% (docs/design-pcie.md, "Who programs what, and when").
a_pci_function_is_opened_first_and_mastered_before_the_install_test() ->
    flush(),
    Self = self(),
    Place = {0, 0, 2, 0},
    Facet = spawn(fun() -> pci_facet(Self) end),
    persistent_term:put({erx, pci}, Facet),
    Owner = spawn(fun() -> Self ! {started, erx_xhci:start_link(#{stand_in => Self, place => Place})},
                           receive stop -> ok end end),
    ?assertEqual({pci, {open, Place}}, play(ok)),
    Controller = receive {started, {ok, Pid}} -> Pid after 2000 -> error(not_started) end,
    ?assertEqual({elements, bios_owned}, play(0)),
    ?assertEqual({elements, revision}, play(2)),
    [?assertEqual({read, Register}, play(Word)) || {Register, Word} <- ?CAPABILITIES],
    ?assertEqual({negotiate, 0}, play({error, ebusy})),
    Controller ! {erx_irq, device(), ?IRQ_LINE},
    ?assertEqual({negotiate, continue}, play(reset)),
    ?assertEqual({pci, {master, Place}}, play(ok)),
    ?assertEqual({negotiate, continue}, play({error, ebusy})),
    ?assertEqual({negotiate, continue}, play({ok, 0})),
    ?assertEqual({ack, ?IRQ_LINE}, play(ok)),
    ok = erx_usb_bus_link:attach(Controller),
    ?assertEqual({root_ports, 4}, bus_answer()),
    stop(Controller),
    Owner ! stop,
    persistent_term:erase({erx, pci}),
    exit(Facet, kill).

%% A pci facet that plays each request to the test, as the device stand-in plays a call.
pci_facet(Player) ->
    receive
        {'$gen_call', From, Request} ->
            gen_server:reply(From, erx_device:play(Player, {pci, Request})),
            pci_facet(Player)
    end.

%% A root port's event goes to the bus process from an interrupt's pass, which clears the
%% event interrupt and interrupt pending, reads the events until an empty batch and then
%% acknowledges the line; the bus's root-port operation reads that port's PORTSC, the
%% first element of the NIF's array.
a_port_event_reaches_the_bus_and_its_status_is_read_test() ->
    Controller = running(),
    interrupt(Controller, [{port, 1}]),
    ?assertEqual({port_event, 1}, bus_answer()),
    ok = erx_usb_bus_link:request(Controller, {port, root, 1, get_status}),
    ?assertEqual({read, {portsc, 0}}, play(16#20201)),
    ?assertMatch({port_done, root, 1, {ok, _Words, _Speed}}, bus_answer()),
    stop(Controller).

%% A message that comes while a pass reads the event ring waits for the pass's end:
%% the pass reads on and acknowledges the line before the bus's request is taken.
a_pass_ends_before_the_next_message_is_taken_test() ->
    Controller = running(),
    Controller ! {erx_irq, device(), ?IRQ_LINE},
    {read, usbsts} = play(?EINT),
    {read, iman} = play(?IMAN),
    {write, usbsts, _} = play(ok),
    {write, iman, _} = play(ok),
    {Caller, {complete, Ring}} = next_call(),
    ok = erx_usb_bus_link:request(Controller, {port, root, 1, get_status}),
    Caller ! {erx_device, {ok, [{port, 1}]}},
    ?assertEqual({complete, Ring}, play({ok, []})),
    ?assertEqual({ack, ?IRQ_LINE}, play(ok)),
    ?assertEqual({read, {portsc, 0}}, play(16#20201)),
    ?assertEqual({port_event, 1}, bus_answer()),
    ?assertMatch({port_done, root, 1, {ok, _Words, _Speed}}, bus_answer()),
    stop(Controller).

%% A device is enabled and addressed, a function's control transfer on its EP0 is posted
%% and answered with its bytes, a reset of its idle EP0 asks the NIF for the queue's state
%% and needs no step, and its detach disables the slot, after which its pipe is
%% answered gone without a post.
a_device_is_addressed_used_and_detached_test() ->
    Controller = running(),
    addressed(Controller),
    Pipe = erx_usb_pipe:new(Controller, ?REF, 0),
    Self = self(),
    spawn_link(fun() -> Self ! {function, erx_usb_pipe:control(Pipe, ?GET_STATUS, {in, 2})} end),
    {post, {?SLOT, 1}, Tag, {control, ?GET_STATUS, {in, 2}}} = play(ok),
    interrupt(Controller, [{Tag, ?SUCCESS, <<1, 0>>}]),
    ?assertEqual({ok, <<1, 0>>}, receive {function, Answer} -> Answer after 2000 -> error(no_answer) end),
    ok = erx_usb_bus_link:request(Controller, {reset_pipe, ?REF, 0, 0}),
    ?assertEqual({queue_state, {?SLOT, 1}}, play(idle)),
    ?assertEqual({pipe_reset, ?REF, 0, 0, ok}, bus_answer()),
    ok = erx_usb_bus_link:request(Controller, {detach, ?REF}),
    {post, command, Disable, {disable_slot, ?SLOT}} = play(ok),
    interrupt(Controller, [{Disable, ?SUCCESS, none}]),
    ?assertEqual({error, gone}, erx_usb_pipe:control(Pipe, ?GET_STATUS, {in, 2})),
    stop(Controller).

%% A transfer the NIF refuses is fed back, so its function is answered with the NIF's
%% reason.
a_refused_transfer_is_answered_with_its_reason_test() ->
    Controller = running(),
    addressed(Controller),
    Self = self(),
    Pipe = erx_usb_pipe:new(Controller, ?REF, 0),
    spawn_link(fun() -> Self ! {function, erx_usb_pipe:control(Pipe, ?GET_STATUS, {in, 2})} end),
    {post, {?SLOT, 1}, _Tag, {control, ?GET_STATUS, {in, 2}}} = play({error, full}),
    ?assertEqual({error, full}, receive {function, Answer} -> Answer after 2000 -> error(no_answer) end),
    stop(Controller).

%% A failure the core decides ends the process with its reason, and the interrupt whose
%% pass failed is not acknowledged.
a_failure_ends_the_process_with_its_reason_test() ->
    Controller = running(),
    Monitor = monitor(process, Controller),
    Controller ! {erx_irq, device(), ?IRQ_LINE},
    {read, usbsts} = play(?EINT),
    {read, iman} = play(?IMAN),
    {write, usbsts, _} = play(ok),
    {write, iman, _} = play(ok),
    {complete, _Ring} = play({error, broken}),
    ?assertEqual({complete, broken}, receive {'DOWN', Monitor, process, Controller, Reason} -> Reason
                                     after 2000 -> error(no_exit) end),
    ?assertEqual(none, receive {erx_device, _, Call} -> Call after 100 -> none end).

%% A controller started over a device the test plays, unlinked so that its failure does
%% not end the test, after what an earlier case's controller left in the mailbox.
start() ->
    flush(),
    {ok, Controller} = erx_xhci:start_link(#{stand_in => self()}),
    unlink(Controller),
    Controller.

stop(Controller) ->
    Monitor = monitor(process, Controller),
    exit(Controller, kill),
    receive {'DOWN', Monitor, process, Controller, _} -> ok end.

device() -> {stand_in, self()}.

flush() ->
    receive _ -> flush() after 0 -> ok end.

%% A started controller, its bus attached and its root ports answered.
running() ->
    Controller = start(),
    {elements, bios_owned} = play(0),
    {elements, revision} = play(2),
    [{read, Register} = play(Word) || {Register, Word} <- ?CAPABILITIES],
    {negotiate, 0} = play({ok, 0}),
    ok = erx_usb_bus_link:attach(Controller),
    {root_ports, 4} = bus_answer(),
    Controller.

%% Device ?REF enabled on slot ?SLOT and given address ?ADDRESS, a high-speed device on
%% root port 1.
addressed(Controller) ->
    ok = erx_usb_bus_link:request(Controller, {enable_slot, ?REF, enabling_slot}),
    {post, command, Enable, enable_slot} = play(ok),
    interrupt(Controller, [{Enable, ?SUCCESS, ?SLOT}]),
    ?assertEqual({slot, ?REF, enabling_slot, {ok, ?SLOT}}, bus_answer()),
    Device = #{slot => ?SLOT, root_port => 1, route => [], speed => high, tt => none},
    ok = erx_usb_bus_link:request(Controller, {address, ?REF, addressing, Device}),
    {post, command, Address, {address_device, ?SLOT, #{root_port := 1, tt := none}}} = play(ok),
    interrupt(Controller, [{Address, ?SUCCESS, ?ADDRESS}]),
    ?assertEqual({addressed, ?REF, addressing, {ok, ?ADDRESS}}, bus_answer()).

%% An interrupt whose pass reads Events, then an empty batch, then acknowledges the line.
interrupt(Controller, Events) ->
    Controller ! {erx_irq, device(), ?IRQ_LINE},
    {read, usbsts} = play(?EINT),
    {read, iman} = play(?IMAN),
    {write, usbsts, _} = play(ok),
    {write, iman, _} = play(ok),
    {complete, Ring} = play({ok, Events}),
    {complete, Ring} = play({ok, []}),
    {ack, ?IRQ_LINE} = play(ok),
    ok.

%% The controller's next NIF call, answered Answer.
play(Answer) ->
    {Caller, Call} = next_call(),
    Caller ! {erx_device, Answer},
    Call.

%% The controller's next NIF call and the process waiting for its answer.
next_call() ->
    receive
        {erx_device, Caller, Call} -> {Caller, Call}
    after 2000 ->
        error(no_call)
    end.

%% The controller's next message to its bus process.
bus_answer() ->
    receive
        Message = {erx_usb_bus_link, _} ->
            {ok, Answer} = erx_usb_bus_link:from_controller(Message),
            Answer
    after 2000 ->
        error(no_bus_answer)
    end.
