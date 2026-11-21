%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_xhci_core (docs/design-usb.md, "The controller process"): the pipe
%% machine, reset_pipe's table, a device's teardown and a control request's abort,
%% explored to a fixed point against a model of the NIF's queue states; a failed Address
%% Device explored the same way; traces of each row of the table, of EP0's reset after a
%% stall, of the teardown, the abort and the failed address; requests through device
%% references; the bus commands, one at a time; and the decoders. Every number is written
%% out here, so a code or request value changed in abi/formats/xhci.txt or usb.txt fails a
%% case instead of moving with the module.
-module(erx_xhci_core_tests).

-include_lib("eunit/include/eunit.hrl").

-export([explore/2, explore_address/1]).

-define(SUCCESS, 1).
-define(TRANSACTION_ERROR, 4).
-define(TRB_ERROR, 5).
-define(STALL, 6).
-define(NO_SLOTS, 9).
-define(SLOT_NOT_ENABLED, 11).
-define(CONTEXT_STATE_ERROR, 19).
-define(STOPPED, 26).

%% One Configure Endpoint adds at most 4 endpoints (xhci_configure_adds_max), and a
%% device has at most 7 pipes besides EP0 (usb_endpoints_max 8).
-define(ADDS_MAX, 4).
-define(PIPES_MAX, 7).

-define(HUB, 1).
-define(DEV, 2).
-define(HUB_REF, {device, 1}).
-define(DEV_REF, {device, 2}).
-define(NEW_REF, {device, 3}).
-define(HUB_EP0, {?HUB, 1}).
-define(DEV_EP0, {?DEV, 1}).
%% Bulk IN endpoint 2: device context index 2 * 2 + 1.
-define(BULK, {?DEV, 5}).
-define(BULK_ADDRESS, 16#82).
-define(HUB_ADDRESS, 5).
-define(DEV_ADDRESS, 6).
%% A control transfer not answered in 5 s is aborted.
-define(CONTROL_DEADLINE, 5000).

-define(GET_STATUS, <<16#80, 0, 0:16, 0:16, 2:16/little>>).

%% The devices the cases address, as the bus core names them: a full-speed device behind
%% the hub's single translator at port 2, a low-speed one behind a multi-TT hub's port 3,
%% and a high-speed one with no translator, each on the hub at root port 1.
devices() ->
    [#{slot => ?DEV, root_port => 1, route => [2], speed => full, tt => #{hub_slot => ?HUB, port => 2, multi => false}},
     #{slot => ?DEV, root_port => 1, route => [3], speed => low, tt => #{hub_slot => ?HUB, port => 3, multi => true}},
     #{slot => ?DEV, root_port => 1, route => [1], speed => high, tt => none}].

%% The pipe machine explored from a hub and a device with one bulk-IN endpoint, for each
%% device, over every event the model allows: a caller's post on each pipe and reset_pipe
%% on the device's, at most one of each outstanding, the NIF reporting its queue state
%% when the core asks; each answer a posted transfer can get (success, STALL, transaction
%% error) while its queue runs; each answer the command in flight can get (success and a
%% TRB error, a stop only success, or a context state error when it finds the queue
%% halted); and, in the second world, the device's detach and the clock moving once to
%% the control requests' deadline. At every state the model checks that each command is
%% one the NIF accepts in its queue's state (so a Reset Endpoint on a stopped queue, a
%% drop of EP0 or a Disable Slot with a queue still running a transfer fails), that at
%% most one command and one EP0 request are in flight, that each caller is answered once,
%% that a post through the detached device is answered gone without reaching the NIF,
%% that a reset answered ok left the queue open with both toggles reset and, after a halt
%% behind a translator, the translator's buffer cleared; that an aborted request is
%% answered timeout only with its EP0 open again and, after a halt behind a translator,
%% the buffer cleared; and that from every state the callers are all answered, and a
%% detached device's slot disabled, when every later answer succeeds.
the_pipe_machine_is_explored_to_a_fixed_point_test_() ->
    %% Each case gets its own limit: a group's {timeout, ...} leaves every test
    %% in it at EUnit's 5 s default.
    [{timeout, 600, ?_assertMatch({ok, _}, explore(Device, Features))}
     || Device <- devices(), Features <- [#{}, #{detach => true, tick => true}]].

%% The rows of the table, each as the commands and requests it posts, every one answered
%% with success. A halted bulk endpoint behind a single translator clears the
%% translator's buffer with wValue its number 2, the address 6 from bit 4, type bulk (2)
%% in bits 12..11 (USB 2.0, Table 11-18) and IN in bit 15, and wIndex 1.
reset_pipe_takes_the_steps_of_its_queue_state_test() ->
    [Full, Low, High] = devices(),
    TtFull = {tt, ?HUB_EP0, setup(16#23, 8, 2 bor (6 bsl 4) bor (2 bsl 11) bor 16#8000, 1)},
    TtLow = {tt, ?HUB_EP0, setup(16#23, 8, 2 bor (6 bsl 4) bor (2 bsl 11) bor 16#8000, 3)},
    ClearHalt = {request, ?DEV_EP0, setup(16#02, 1, 0, ?BULK_ADDRESS)},
    DropAdd = {command, configure_endpoints},
    ?assertEqual([{command, reset_endpoint}, TtFull, ClearHalt, {command, set_tr_dequeue}],
                 reset_steps(Full, ?BULK, halted)),
    ?assertEqual([{command, reset_endpoint}, TtLow, ClearHalt, {command, set_tr_dequeue}],
                 reset_steps(Low, ?BULK, halted)),
    ?assertEqual([{command, reset_endpoint}, ClearHalt, {command, set_tr_dequeue}],
                 reset_steps(High, ?BULK, halted)),
    ?assertEqual([{command, stop_endpoint}, DropAdd, ClearHalt], reset_steps(High, ?BULK, busy)),
    ?assertEqual([DropAdd, ClearHalt], reset_steps(High, ?BULK, stopped)),
    ?assertEqual([DropAdd, ClearHalt], reset_steps(Full, ?BULK, idle)),
    ?assertEqual([{command, reset_endpoint}, {tt, ?HUB_EP0, setup(16#23, 8, 0 bor (6 bsl 4), 1)},
                  {command, set_tr_dequeue}],
                 reset_steps(Full, ?DEV_EP0, halted)),
    ?assertEqual([{command, stop_endpoint}, {command, set_tr_dequeue}], reset_steps(High, ?DEV_EP0, busy)),
    ?assertEqual([{command, set_tr_dequeue}], reset_steps(High, ?DEV_EP0, stopped)),
    ?assertEqual([], reset_steps(High, ?DEV_EP0, idle)).

%% A Stop Endpoint answered with a context state error, the endpoint having halted
%% meanwhile, goes on as the halted row; the drop-and-add re-adds the endpoint as it was
%% configured, with the slot's hub fields. Any other failure of a stop fails the
%% controller: an enabled slot cannot get a slot not enabled error (xHCI 4.6.9, p. 140).
a_stop_that_finds_a_halt_takes_the_halted_row_test() ->
    {S0, _} = addressed(lists:last(devices())),
    {S1, [{command, T1, {stop_endpoint, ?DEV, 5}}]} = step({reset_pipe, me, ?BULK, busy}, S0),
    {S2, [{command, T2, {reset_endpoint, ?DEV, 5}}]} = step({complete, T1, ?CONTEXT_STATE_ERROR, none}, S1),
    {_, [{transfer, ?DEV_EP0, _, {control, <<16#02, 1, 0:16, ?BULK_ADDRESS:16/little, 0:16>>, none}}]} =
        step({complete, T2, ?SUCCESS, none}, S2),
    {S3, [{command, T3, {stop_endpoint, ?DEV, 5}}]} = step({reset_pipe, me, ?BULK, busy}, S0),
    ?assertMatch({_, [{command, _, {configure_endpoints, ?DEV,
                                    #{add := [#{address := ?BULK_ADDRESS, type := bulk, packet_size := 512}],
                                      drop := [5], hub := none}}}]},
                 step({complete, T3, ?SUCCESS, none}, S3)),
    ?assertMatch({_, [{fail, {command_failed, {stop_endpoint, ?DEV, 5}, slot_not_enabled}}]},
                 step({complete, T3, ?SLOT_NOT_ENABLED, none}, S3)).

%% A failed step halts the pipe and answers the step's error; the pipe then refuses
%% posts until another reset succeeds.
a_failed_step_halts_the_pipe_test() ->
    {S0, _} = addressed(lists:last(devices())),
    {S1, [{command, T1, {reset_endpoint, ?DEV, 5}}]} = step({reset_pipe, me, ?BULK, halted}, S0),
    {S2, [{reply, me, {error, trb_error}}]} = step({complete, T1, ?TRB_ERROR, none}, S1),
    ?assertMatch({_, [{reply, you, {error, halted}}]}, step({post, you, ?BULK, {normal, {in, 64}}}, S2)),
    ?assertMatch({_, [{command, _, {reset_endpoint, ?DEV, 5}}]}, step({reset_pipe, me, ?BULK, halted}, S2)).

%% reset_pipe asks the NIF for its queue's state before it plans; a second reset of a
%% resetting pipe is answered resetting, a report the core did not ask for changes
%% nothing, and one that is not a queue state fails the controller.
reset_pipe_asks_for_the_queue_state_test() ->
    {S0, _} = addressed(lists:last(devices())),
    {S1, [{queue_state, ?BULK}]} = erx_xhci_core:step({bus, {reset_pipe, ?DEV_REF, 0, ?BULK_ADDRESS}}, 0, S0),
    ?assertMatch({_, [{bus, {pipe_reset, ?DEV_REF, 1, ?BULK_ADDRESS, {error, resetting}}}]},
                 erx_xhci_core:step({bus, {reset_pipe, ?DEV_REF, 1, ?BULK_ADDRESS}}, 0, S1)),
    ?assertMatch({_, [{command, _, {stop_endpoint, ?DEV, 5}}]}, erx_xhci_core:step({queue_state, ?BULK, busy}, 0, S1)),
    ?assertEqual({S0, []}, erx_xhci_core:step({queue_state, ?BULK, busy}, 0, S0)),
    ?assertMatch({_, [{fail, {unexpected, {queue_state, ?BULK, open}}}]},
                 erx_xhci_core:step({queue_state, ?BULK, open}, 0, S1)),
    ?assertMatch({_, [{bus, {pipe_reset, ?NEW_REF, 0, ?BULK_ADDRESS, {error, gone}}}]},
                 erx_xhci_core:step({bus, {reset_pipe, ?NEW_REF, 0, ?BULK_ADDRESS}}, 0, S0)).

%% A request that halts EP0 is answered only once EP0 is reset; a request posted
%% meanwhile is refused `resetting`, and one waiting behind the halted one is answered
%% the same when the reset begins.
ep0_is_reset_before_its_halted_request_is_answered_test() ->
    {S0, _} = addressed(lists:last(devices())),
    {S1, [{transfer, ?DEV_EP0, T1, _}]} = step({post, first, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S0),
    {S2, []} = step({post, second, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S1),
    {S3, [{reply, second, {error, resetting}}, {command, T2, {reset_endpoint, ?DEV, 1}}]} =
        step({complete, T1, ?STALL, <<>>}, S2),
    {S4, [{reply, third, {error, resetting}}]} = step({post, third, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S3),
    {S5, [{command, T3, {set_tr_dequeue, ?DEV, 1}}]} = step({complete, T2, ?SUCCESS, none}, S4),
    {S6, [{reply, first, {error, stall}}]} = step({complete, T3, ?SUCCESS, none}, S5),
    ?assertMatch({_, [{transfer, ?DEV_EP0, _, _}]}, step({post, fourth, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S6)).

%% EP0 carries one request at a time: the second waits for the first's completion.
ep0_carries_one_request_at_a_time_test() ->
    {S0, _} = addressed(lists:last(devices())),
    {S1, [{transfer, ?DEV_EP0, T1, _}]} = step({post, a, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S0),
    {S2, []} = step({post, b, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S1),
    ?assertMatch({_, [{transfer, ?DEV_EP0, _, _}, {reply, a, {ok, <<1, 0>>}}]},
                 step({complete, T1, ?SUCCESS, <<1, 0>>}, S2)).

%% Requests reach the controller in the messages of erx_usb_bus_link and erx_usb_pipe,
%% and each is answered in the message its module spells: a function's control request
%% under its monitor, an interrupt-IN completion as {usb, Pipe, Tag, Result}, the bus
%% process's control request as control_done with its tag.
requests_are_answered_in_their_modules_messages_test() ->
    {S0, _} = addressed(lists:last(devices())),
    Control = erx_usb_pipe:new(self(), ?DEV_REF, 0),
    Monitor = make_ref(),
    {S1, [{transfer, ?DEV_EP0, T1, {control, ?GET_STATUS, {in, 2}}}]} =
        erx_xhci_core:step({pipe, self(), {control, Control, ?GET_STATUS, {in, 2}, Monitor}}, 0, S0),
    Me = self(),
    ?assertMatch({_, [{send, Me, {Monitor, {ok, <<1, 0>>}}}]}, erx_xhci_core:step({complete, T1, ?SUCCESS, <<1, 0>>}, 0, S1)),
    Bulk = erx_usb_pipe:new(self(), ?DEV_REF, ?BULK_ADDRESS),
    {S2, [{transfer, ?BULK, T2, {normal, {in, 64}}}]} =
        erx_xhci_core:step({pipe, self(), {interrupt_in, Bulk, report, 64}}, 0, S0),
    ?assertMatch({_, [{send, Me, {usb, Bulk, report, {ok, <<7>>}}}]}, erx_xhci_core:step({complete, T2, ?SUCCESS, <<7>>}, 0, S2)),
    {S3, [{transfer, ?HUB_EP0, T3, {control, ?GET_STATUS, {in, 2}}}]} =
        erx_xhci_core:step({bus, {control, ?HUB_REF, {port, 2, get_status}, ?GET_STATUS, {in, 2}}}, 0, S0),
    ?assertMatch({_, [{bus, {control_done, ?HUB_REF, {port, 2, get_status}, {ok, <<1, 2>>}}}]},
                 erx_xhci_core:step({complete, T3, ?SUCCESS, <<1, 2>>}, 0, S3)),
    %% An endpoint the device has no pipe for, and a reference never seen, are gone.
    ?assertMatch({_, [{send, Me, {usb, _, x, {error, gone}}}]},
                 erx_xhci_core:step({pipe, self(), {interrupt_in, erx_usb_pipe:new(self(), ?DEV_REF, 16#83), x, 8}}, 0, S0)),
    ?assertMatch({_, [{bus, {control_done, ?NEW_REF, t, {error, gone}}}]},
                 erx_xhci_core:step({bus, {control, ?NEW_REF, t, ?GET_STATUS, {in, 2}}}, 0, S0)).

%% Bus commands run one at a time, each answered as the request it came in; a refused
%% transfer is answered with the NIF's reason. Address Device is posted with the NIF's
%% parameters for the slot the reference is bound to: the route string four bits a tier,
%% the first lowest (xHCI 6.2.2, p. 444); the port speed ID; EP0's packet size of the
%% speed (4.3, p. 85).
bus_commands_run_one_at_a_time_test() ->
    S0 = erx_xhci_core:new(),
    Device = #{slot => 7, root_port => 3, route => [2, 15], speed => high, tt => none},
    {S1, [{command, T1, enable_slot}]} = step({bus, {enable_slot, ?DEV_REF, enabling}}, S0),
    {S2, []} = step({bus, {address, ?DEV_REF, addressing, Device}}, S1),
    {S3, [{reply, enabling, {ok, ?DEV}}, {command, T2, {address_device, ?DEV, Parameters}}]} =
        step({complete, T1, ?SUCCESS, ?DEV}, S2),
    ?assertEqual(#{route => 16#f2, root_port => 3, speed => 3, tt => none, ep0_packet => 64}, Parameters),
    ?assertMatch({_, [{reply, me, {error, gone}}]}, step({post, me, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S3)),
    {S4, [{reply, addressing, {ok, 9}}]} = step({complete, T2, ?SUCCESS, 9}, S3),
    {S5, [{transfer, ?DEV_EP0, T3, _}]} = step({post, me, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S4),
    ?assertMatch({_, [{reply, me, {error, full}}]}, step({refused, T3, full}, S5)),
    {S6, [{command, T4, {evaluate_context, ?DEV, #{ep0_packet := 64}}}]} =
        step({bus, {evaluate_context, ?DEV_REF, ep0_packet, #{ep0_packet => 64}}}, S4),
    ?assertMatch({_, [{reply, ep0_packet, ok}]}, step({complete, T4, ?SUCCESS, none}, S6)),
    %% A failed Enable Slot leaves the reference with no slot, so its Address Device is gone.
    ?assertMatch({_, [{reply, enabling, {error, no_slots}}, {reply, addressing, {error, gone}}]},
                 step({complete, T1, ?NO_SLOTS, 0}, S2)),
    [begin
         {A1, []} = step({bus, {address, ?DEV_REF, a, Device#{speed := Speed}}}, S1),
         ?assertMatch({_, [_, {command, _, {address_device, ?DEV, #{speed := Id, ep0_packet := Packet}}}]},
                      step({complete, T1, ?SUCCESS, ?DEV}, A1))
     end || {Speed, Id, Packet} <- [{low, 2, 8}, {full, 1, 8}, {super, 4, 512}]].

%% The controller fails on an answer it cannot trust or a command it never gets.
the_controller_fails_on_a_malformed_answer_or_a_lost_command_test() ->
    S0 = erx_xhci_core:new(),
    {S1, [{command, T1, enable_slot}]} = erx_xhci_core:step({bus, {enable_slot, ?DEV_REF, bus}}, 1000, S0),
    ?assertMatch({_, [{fail, {malformed_answer, enable_slot}}]}, step({complete, T1, ?SUCCESS, 0}, S1)),
    ?assertMatch({_, [{fail, {malformed_answer, enable_slot}}]}, step({complete, T1, ?SUCCESS, 17}, S1)),
    ?assertMatch({_, [{fail, {unknown_tag, 99}}]}, step({complete, 99, ?SUCCESS, <<>>}, S1)),
    {S2, []} = step({bus, {enable_slot, ?NEW_REF, bus}}, S1),
    ?assertMatch({_, [{fail, {malformed_answer, enable_slot}}]}, step({complete, T1, ?SUCCESS, 0}, S2)),
    ?assertEqual(6000, erx_xhci_core:next_deadline(S1)),
    ?assertEqual({S1, []}, erx_xhci_core:step(expired, 5999, S1)),
    ?assertMatch({_, [{fail, {command_timeout, enable_slot}}]}, erx_xhci_core:step(expired, 6000, S1)),
    ?assertEqual(none, erx_xhci_core:next_deadline(S0)),
    %% An Enable Slot naming a slot the core still holds: the controller gave it twice.
    {S3, [{reply, bus, {ok, ?DEV}}, {command, T3, enable_slot}]} = step({complete, T1, ?SUCCESS, ?DEV}, S2),
    ?assertMatch({_, [{fail, {malformed_answer, enable_slot}}]}, step({complete, T3, ?SUCCESS, ?DEV}, S3)).

%% Device references

%% A detached device's slot is torn down: its requests answered gone at once, the
%% transfers posted on it stopped, one command at a time, the halted bulk queue not
%% stopped, then Disable Slot; the transfers the disable retires are answered stopped,
%% and only its success frees the slot. A request through the detached reference answers
%% gone even once another device has the slot, and the new device's own reference
%% reaches it.
a_detached_device_is_torn_down_and_its_reference_stays_gone_test() ->
    {S0, _} = addressed(lists:last(devices())),
    {S1, [{transfer, ?DEV_EP0, T1, _}]} = step({post, a, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S0),
    {S2, []} = step({post, b, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S1),
    {S3, [{transfer, ?BULK, T2, _}]} = step({post, c, ?BULK, {normal, {in, 64}}}, S2),
    {S4, [{reply, b, {error, gone}}, {command, T3, {stop_endpoint, ?DEV, 1}}]} = step({bus, {detach, ?DEV_REF}}, S3),
    ?assertMatch({_, [{reply, d, {error, gone}}]}, step({post, d, ?BULK, {normal, {in, 64}}}, S4)),
    ?assertMatch({_, [{reply, e, {error, gone}}]}, step({reset_pipe, e, ?BULK, idle}, S4)),
    {S5, [{command, T4, {stop_endpoint, ?DEV, 5}}]} = step({complete, T3, ?SUCCESS, none}, S4),
    {S6, [{command, T5, {disable_slot, ?DEV}}]} = step({complete, T4, ?SUCCESS, none}, S5),
    {S7, [{reply, a, {error, stopped}}]} = step({complete, T1, ?STOPPED, <<>>}, S6),
    {S8, [{reply, c, {error, stopped}}]} = step({complete, T2, ?STOPPED, <<>>}, S7),
    {S9, []} = step({complete, T5, ?SUCCESS, none}, S8),
    %% The slot is free: the controller may give it to the next device.
    {S10, [{reply, x, {ok, ?DEV}}]} = enable(?NEW_REF, x, ?DEV, S9),
    {S11, [{reply, y, {ok, 7}}]} = address(?NEW_REF, y, lists:last(devices()), 7, S10),
    ?assertMatch({_, [{reply, old, {error, gone}}]}, step({post, old, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S11)),
    ?assertMatch({_, [{bus, {control_done, ?DEV_REF, t, {error, gone}}}]},
                 erx_xhci_core:step({bus, {control, ?DEV_REF, t, ?GET_STATUS, {in, 2}}}, 0, S11)),
    ?assertMatch({_, [{transfer, ?DEV_EP0, _, _}]},
                 erx_xhci_core:step({bus, {control, ?NEW_REF, t, ?GET_STATUS, {in, 2}}}, 0, S11)),
    %% A halted bulk queue is not stopped: Disable Slot accepts it.
    {H1, [{transfer, ?BULK, T6, _}]} = step({post, c, ?BULK, {normal, {in, 64}}}, S0),
    {H2, [{reply, c, {error, stall}}]} = step({complete, T6, ?STALL, <<>>}, H1),
    ?assertMatch({_, [{command, _, {disable_slot, ?DEV}}]}, step({bus, {detach, ?DEV_REF}}, H2)),
    %% A teardown command that fails fails the controller.
    ?assertMatch({_, [{fail, {command_failed, {disable_slot, ?DEV}, trb_error}}]}, step({complete, T5, ?TRB_ERROR, none}, S8)).

%% A queue that halts while its teardown waits for its turn is halted, not running, so
%% the teardown disables the slot without stopping it, though another transfer is still
%% posted on it; the NIF accepts only Reset Endpoint on a halted queue.
a_halt_while_the_teardown_waits_leaves_the_queue_unstopped_test() ->
    {S0, _} = addressed(lists:last(devices())),
    {S1, [{transfer, ?BULK, T1, _}]} = step({post, a, ?BULK, {normal, {in, 64}}}, S0),
    {S2, [{transfer, ?BULK, _, _}]} = step({post, b, ?BULK, {normal, {in, 64}}}, S1),
    {S3, [{command, T3, {evaluate_context, ?HUB, _}}]} =
        step({bus, {evaluate_context, ?HUB_REF, bus, #{ep0_packet => 64}}}, S2),
    {S4, []} = step({bus, {detach, ?DEV_REF}}, S3),
    {S5, [{reply, a, {error, stall}}]} = step({complete, T1, ?STALL, <<>>}, S4),
    ?assertMatch({_, [{reply, bus, ok}, {command, _, {disable_slot, ?DEV}}]}, step({complete, T3, ?SUCCESS, none}, S5)).

%% A reset in progress at the detach answers its requester gone; its Stop Endpoint
%% already posted is waited for and leaves the queue stopped, so the teardown disables
%% at once; one still waiting is dropped and the teardown stops the queue itself.
a_reset_in_progress_at_the_detach_is_answered_gone_test() ->
    {S0, _} = addressed(lists:last(devices())),
    {S1, [{transfer, ?BULK, _, _}]} = step({post, c, ?BULK, {normal, {in, 64}}}, S0),
    {S2, [{command, T2, {stop_endpoint, ?DEV, 5}}]} = step({reset_pipe, me, ?BULK, busy}, S1),
    {S3, [{reply, me, {error, gone}}]} = step({bus, {detach, ?DEV_REF}}, S2),
    ?assertMatch({_, [{command, _, {disable_slot, ?DEV}}]}, step({complete, T2, ?SUCCESS, none}, S3)),
    %% The stop waits behind a command of the hub's.
    {W1, [{command, TW, {evaluate_context, ?HUB, _}}]} =
        step({bus, {evaluate_context, ?HUB_REF, bus, #{ep0_packet => 64}}}, S1),
    {W2, []} = step({reset_pipe, me, ?BULK, busy}, W1),
    {W3, [{reply, me, {error, gone}}]} = step({bus, {detach, ?DEV_REF}}, W2),
    ?assertMatch({_, [{reply, bus, ok}, {command, _, {stop_endpoint, ?DEV, 5}}]}, step({complete, TW, ?SUCCESS, none}, W3)).

%% A reset's request still posted on the hub when its device's slot is disabled answers
%% that reset only: a new device given the same slot, whose pipe of the same name is
%% resetting meanwhile, keeps its own steps, so its drop-and-add still runs first.
a_reset_step_answered_after_its_slot_is_reused_is_stale_test() ->
    Full = hd(devices()),
    {S0, _} = addressed(Full),
    {S1, [{transfer, ?BULK, T1, _}]} = step({post, c, ?BULK, {normal, {in, 64}}}, S0),
    {S2, [{reply, c, {error, stall}}]} = step({complete, T1, ?STALL, <<>>}, S1),
    {S3, [{command, T3, {reset_endpoint, ?DEV, 5}}]} = step({reset_pipe, me, ?BULK, halted}, S2),
    {S4, [{transfer, ?HUB_EP0, Clear, _}]} = step({complete, T3, ?SUCCESS, none}, S3),
    {S5, [{reply, me, {error, gone}}, {command, T5, {disable_slot, ?DEV}}]} = step({bus, {detach, ?DEV_REF}}, S4),
    {S6, []} = step({complete, T5, ?SUCCESS, none}, S5),
    S7 = requested([{{enable_slot, ?NEW_REF, bus}, ?DEV},
                    {{address, ?NEW_REF, bus, Full}, 7},
                    {{configure_endpoints, ?NEW_REF, bus, #{add => [bulk()], hub => none}}, none}],
                   S6),
    {S8, [{command, T8, {evaluate_context, ?HUB, _}}]} =
        step({bus, {evaluate_context, ?HUB_REF, bus, #{ep0_packet => 64}}}, S7),
    {S9, [{queue_state, ?BULK}]} = step({bus, {reset_pipe, ?NEW_REF, new, ?BULK_ADDRESS}}, S8),
    {S10, []} = step({queue_state, ?BULK, idle}, S9),
    {S11, []} = step({complete, Clear, ?SUCCESS, <<>>}, S10),
    ?assertMatch({_, [{reply, bus, ok}, {command, _, {configure_endpoints, ?DEV, #{drop := [5]}}}]},
                 step({complete, T8, ?SUCCESS, none}, S11)).

%% A reference detached while its Enable Slot is posted leaves a slot nobody owns, which
%% is disabled, the Enable Slot answered gone; one detached before its Enable Slot is
%% posted, or before its Address Device is, is answered gone and nothing is posted.
a_slot_nobody_owns_is_disabled_test() ->
    {S0, _} = addressed(lists:last(devices())),
    {S1, [{command, T1, enable_slot}]} = step({bus, {enable_slot, ?NEW_REF, enabling}}, S0),
    {S2, []} = step({bus, {detach, ?NEW_REF}}, S1),
    {S3, [{reply, enabling, {error, gone}}, {command, T2, {disable_slot, 3}}]} = step({complete, T1, ?SUCCESS, 3}, S2),
    ?assertMatch({_, []}, step({complete, T2, ?SUCCESS, none}, S3)),
    {Q1, [{command, TQ, {evaluate_context, ?HUB, _}}]} =
        step({bus, {evaluate_context, ?HUB_REF, bus, #{ep0_packet => 64}}}, S0),
    {Q2, []} = step({bus, {enable_slot, ?NEW_REF, enabling}}, Q1),
    {Q3, []} = step({bus, {detach, ?NEW_REF}}, Q2),
    ?assertMatch({_, [{reply, bus, ok}, {reply, enabling, {error, gone}}]}, step({complete, TQ, ?SUCCESS, none}, Q3)),
    {E1, [{command, T3, enable_slot}]} = step({bus, {enable_slot, ?NEW_REF, enabling}}, S0),
    {E2, []} = step({bus, {address, ?NEW_REF, addressing, lists:last(devices())}}, E1),
    {E3, [{reply, enabling, {ok, 3}}, {command, TE, {address_device, 3, _}}]} = step({complete, T3, ?SUCCESS, 3}, E2),
    {E4, []} = step({bus, {evaluate_context, ?NEW_REF, ep0_packet, #{ep0_packet => 64}}}, E3),
    {E5, []} = step({bus, {detach, ?NEW_REF}}, E4),
    %% The posted Address Device is answered with its address, the waiting Evaluate
    %% Context gone, and the slot disabled.
    ?assertMatch({_, [{reply, addressing, {ok, 8}}, {reply, ep0_packet, {error, gone}}, {command, _, {disable_slot, 3}}]},
                 step({complete, TE, ?SUCCESS, 8}, E5)).

%% A failed Address Device

%% A failed Address Device tears its slot down before it is answered; behind a
%% translator on a USB Transaction Error, CLEAR_TT_BUFFER for address 0's control
%% endpoint (wValue 0, wIndex 1 on a single-TT hub, the port on a multi-TT one) follows
%% the Disable Slot, and the answer follows the clear: the address error on success, the
%% clear's failure otherwise; past the clear's deadline, the hub's EP0 is aborted and the
%% answer is the clear's timeout. Another code, or no translator, is answered at the
%% disable.
a_failed_address_is_cleaned_up_before_it_is_answered_test() ->
    [Full, Low, High] = devices(),
    {S0, [{command, T0, {disable_slot, ?DEV}}]} = failed_address(Full, ?TRANSACTION_ERROR),
    {S1, [{transfer, ?HUB_EP0, T1, {control, Clear, none}}]} = step({complete, T0, ?SUCCESS, none}, S0),
    ?assertEqual(setup(16#23, 8, 0, 1), Clear),
    ?assertMatch({_, [{reply, addressing, {error, {address, transaction_error}}}]}, step({complete, T1, ?SUCCESS, <<>>}, S1)),
    {S2, [{command, T2, {reset_endpoint, ?HUB, 1}}]} = step({complete, T1, ?STALL, <<>>}, S1),
    {S3, [{command, T3, {set_tr_dequeue, ?HUB, 1}}]} = step({complete, T2, ?SUCCESS, none}, S2),
    ?assertMatch({_, [{reply, addressing, {error, {tt_clear, stall}}}]}, step({complete, T3, ?SUCCESS, none}, S3)),
    ?assertEqual(?CONTROL_DEADLINE, erx_xhci_core:next_deadline(S1)),
    {S4, [{command, T4, {stop_endpoint, ?HUB, 1}}]} = erx_xhci_core:step(expired, ?CONTROL_DEADLINE, S1),
    {S5, [{command, T5, {set_tr_dequeue, ?HUB, 1}}]} = step({complete, T4, ?SUCCESS, none}, S4),
    {S6, []} = step({complete, T1, ?STOPPED, <<>>}, S5),
    ?assertMatch({_, [{reply, addressing, {error, {tt_clear, timeout}}}]}, step({complete, T5, ?SUCCESS, none}, S6)),
    {L0, [{command, L1, {disable_slot, ?DEV}}]} = failed_address(Low, ?TRANSACTION_ERROR),
    ?assertMatch({_, [{transfer, ?HUB_EP0, _, {control, <<16#23, 8, 0:16, 3:16/little, 0:16>>, none}}]},
                 step({complete, L1, ?SUCCESS, none}, L0)),
    {F0, [{command, F1, {disable_slot, ?DEV}}]} = failed_address(Full, ?CONTEXT_STATE_ERROR),
    ?assertMatch({_, [{reply, addressing, {error, {address, context_state_error}}}]}, step({complete, F1, ?SUCCESS, none}, F0)),
    {H0, [{command, H1, {disable_slot, ?DEV}}]} = failed_address(High, ?TRANSACTION_ERROR),
    {H2, [{reply, addressing, {error, {address, transaction_error}}}]} = step({complete, H1, ?SUCCESS, none}, H0),
    %% The bus detaches the device it gave up: its reference was already unbound.
    ?assertMatch({_, []}, step({bus, {detach, ?DEV_REF}}, H2)),
    ?assertMatch({_, [{reply, me, {error, gone}}]}, step({post, me, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, H0)).

%% The failed Address Device explored, behind a single-TT hub and with no translator.
the_failed_address_is_explored_to_a_fixed_point_test_() ->
    [{timeout, 300, ?_assertMatch({ok, _}, explore_address(Device))}
     || Device <- [hd(devices()), lists:last(devices())]].

%% The configuration of a device explored for each count of pipes, past one command's
%% adds.
the_configuration_is_explored_to_a_fixed_point_test_() ->
    {timeout, 300, [?_assertMatch({ok, _}, explore_configure(Count)) || Count <- lists:seq(1, ?PIPES_MAX)]}.

%% Aborting a control request

%% A control request not answered in 5 s is aborted: EP0 resets, so requests meanwhile
%% answer resetting; Stop Endpoint, then Set TR Dequeue Pointer past it; its own stopped
%% completion is dropped; and only at the last step's success is it answered timeout and
%% the next request posted. A stop that finds EP0 halted takes the halted row, behind a
%% translator its clear included; a step that fails fails the controller.
an_unanswered_control_request_is_aborted_test() ->
    [Full, _Low, High] = devices(),
    {S0, _} = addressed(High),
    {S1, [{transfer, ?DEV_EP0, T1, _}]} = step({post, a, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S0),
    {S2, [{transfer, ?BULK, _, _}]} = step({post, b, ?BULK, {normal, {in, 64}}}, S1),
    ?assertEqual(?CONTROL_DEADLINE, erx_xhci_core:next_deadline(S2)),
    ?assertMatch({_, []}, erx_xhci_core:step(expired, ?CONTROL_DEADLINE - 1, S2)),
    {S3, [{command, T2, {stop_endpoint, ?DEV, 1}}]} = erx_xhci_core:step(expired, ?CONTROL_DEADLINE, S2),
    {S4, [{reply, c, {error, resetting}}]} = step({post, c, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S3),
    {S5, [{command, T3, {set_tr_dequeue, ?DEV, 1}}]} = step({complete, T2, ?SUCCESS, none}, S4),
    {S6, []} = step({complete, T1, ?STOPPED, <<>>}, S5),
    {S7, [{reply, a, {error, timeout}}]} = step({complete, T3, ?SUCCESS, none}, S6),
    ?assertMatch({_, [{transfer, ?DEV_EP0, _, _}]}, step({post, d, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S7)),
    ?assertMatch({_, [{fail, {abort_failed, ?DEV_EP0, trb_error}}]}, step({complete, T3, ?TRB_ERROR, none}, S6)),
    %% Behind a translator, a stop that finds EP0 halted: Reset Endpoint, the clear, Set
    %% TR Dequeue Pointer.
    {F0, _} = addressed(Full),
    {F1, [{transfer, ?DEV_EP0, _, _}]} = step({post, a, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, F0),
    {F2, [{command, F3, {stop_endpoint, ?DEV, 1}}]} = erx_xhci_core:step(expired, ?CONTROL_DEADLINE, F1),
    {F4, [{command, F5, {reset_endpoint, ?DEV, 1}}]} = step({complete, F3, ?CONTEXT_STATE_ERROR, none}, F2),
    {F6, [{transfer, ?HUB_EP0, F7, {control, <<16#23, 8, _/binary>>, none}}]} = step({complete, F5, ?SUCCESS, none}, F4),
    {F8, [{command, F9, {set_tr_dequeue, ?DEV, 1}}]} = step({complete, F7, ?SUCCESS, <<>>}, F6),
    ?assertMatch({_, [{reply, a, {error, timeout}}]}, step({complete, F9, ?SUCCESS, none}, F8)),
    %% The clear stalls: the hub's EP0 is reset, and the abort's failed step fails the
    %% controller.
    {F10, [{command, F11, {reset_endpoint, ?HUB, 1}}]} = step({complete, F7, ?STALL, <<>>}, F6),
    {F12, [{command, F13, {set_tr_dequeue, ?HUB, 1}}]} = step({complete, F11, ?SUCCESS, none}, F10),
    ?assertMatch({_, [{fail, {abort_failed, ?DEV_EP0, stall}}]}, step({complete, F13, ?SUCCESS, none}, F12)).

%% The start's answer to the bus process waits for both the bus's attach and the
%% controller's start, whichever comes last, and a root port's event before then is
%% dropped.
the_bus_is_answered_once_attached_and_running_test() ->
    {S1, [negotiate]} = erx_xhci_core:step({read, #{{legacy, bios_owned} => 0}}, 0, handoff_started(unattached)),
    {S2, []} = erx_xhci_core:step({negotiated, ok}, 0, S1),
    {S3, [{read, [usbsts, iman]}]} = erx_xhci_core:step(interrupt, 0, S2),
    {S4, [_, _, complete]} = erx_xhci_core:step({read, #{usbsts => 16#8, iman => 3}}, 0, S3),
    {S5, [complete]} = erx_xhci_core:step({completed, {ok, [{port, 2}]}}, 0, S4),
    {S6, [ack]} = erx_xhci_core:step({completed, {ok, []}}, 0, S5),
    ?assertMatch({_, [{bus, {root_ports, 4}}]}, erx_xhci_core:step({bus, attach}, 0, S6)).

%% Helpers

%% Test-level events, each turned into the core's: a function's post on a pipe named by
%% its slot and context index, through the reference the fixtures bind to that slot,
%% {device, Slot}; the bus process's reset of such a pipe, with the queue state the NIF
%% reports when the core asks; and the core's own events unchanged. A caller's name rides
%% in its request's monitor, tag, interface or step, so every answer reads back as
%% {reply, Who, Answer}.
step(Event, State) -> at(0, Event, State).

at(Now, {post, Who, Pipe, Transfer}, State) ->
    norm(erx_xhci_core:step(post_event(Who, Pipe, Transfer), Now, State));
at(Now, {reset_pipe, Who, Pipe, Queue}, State) ->
    {S1, Actions} = erx_xhci_core:step({bus, {reset_pipe, ref(Pipe), Who, ep_address(Pipe)}}, Now, State),
    case lists:reverse(Actions) of
        [{queue_state, Pipe} | Before] ->
            {S2, After} = erx_xhci_core:step({queue_state, Pipe, Queue}, Now, S1),
            norm({S2, lists:reverse(Before) ++ After});
        _ ->
            norm({S1, Actions})
    end;
at(Now, Event, State) ->
    norm(erx_xhci_core:step(Event, Now, State)).

post_event(Who, Pipe = {_Slot, 1}, {control, Setup, Data}) ->
    {pipe, Who, {control, erx_usb_pipe:new(self(), ref(Pipe), 0), Setup, Data, Who}};
post_event(Who, Pipe, {normal, {in, Length}}) ->
    {pipe, Who, {interrupt_in, erx_usb_pipe:new(self(), ref(Pipe), ep_address(Pipe)), Who, Length}}.

ref({Slot, _Dci}) -> {device, Slot}.

ep_address({_Slot, 1}) -> 0;
ep_address({_Slot, Dci}) -> (Dci div 2) bor ((Dci band 1) bsl 7).

norm({S, Actions}) -> {S, [norm_action(Action) || Action <- Actions]}.

norm_action({send, Who, {Who, Answer}}) -> {reply, Who, Answer};
norm_action({send, Who, {usb, _Pipe, Who, Answer}}) -> {reply, Who, Answer};
norm_action({bus, {pipe_reset, _Ref, Who, _Address, Answer}}) -> {reply, Who, Answer};
norm_action({bus, {Kind, _Ref, Who, Answer}}) when Kind =:= slot; Kind =:= addressed; Kind =:= evaluated;
                                                   Kind =:= endpoints_configured ->
    {reply, Who, Answer};
norm_action(Action) -> Action.

setup(Type, Request, Value, Index) -> <<Type, Request, Value:16/little, Index:16/little, 0:16>>.

%% Ref's Enable Slot answered with Slot, its step named Who.
enable(Ref, Who, Slot, S0) ->
    {S1, Actions} = step({bus, {enable_slot, Ref, Who}}, S0),
    {command, Tag, enable_slot} = lists:last(Actions),
    step({complete, Tag, ?SUCCESS, Slot}, S1).

%% Ref's Address Device of Device answered with Address, its step named Who.
address(Ref, Who, Device, Address, S0) ->
    {S1, [{command, Tag, {address_device, _, _}}]} = step({bus, {address, Ref, Who, Device}}, S0),
    step({complete, Tag, ?SUCCESS, Address}, S1).

%% The core with the hub at slot 1, and with Device at slot 2, its bulk-IN endpoint
%% configured; and the device.
hub_addressed() ->
    Hub = #{slot => ?HUB, root_port => 1, route => [], speed => high, tt => none},
    requested([{{enable_slot, ?HUB_REF, bus}, ?HUB},
               {{address, ?HUB_REF, bus, Hub}, ?HUB_ADDRESS},
               {{configure_endpoints, ?HUB_REF, bus, #{add => [], hub => #{ports => 4, think_time => 0,
                                                                            multi_tt => false}}}, none}],
              erx_xhci_core:new()).

addressed(Device) ->
    {requested([{{enable_slot, ?DEV_REF, bus}, ?DEV},
                {{address, ?DEV_REF, bus, Device}, ?DEV_ADDRESS},
                {{configure_endpoints, ?DEV_REF, bus, #{add => [bulk()], hub => none}}, none}],
               hub_addressed()),
     Device}.

%% The device's bulk-IN endpoint, as its Configure Endpoint adds it.
bulk() ->
    #{address => ?BULK_ADDRESS, type => bulk, packet_size => 512, burst => 0, payload => 512,
      interval_exponent => 0}.

%% Each bus request run alone and its command answered with success and Extra.
requested(Requests, State) ->
    lists:foldl(fun({Request, Extra}, S) ->
                        {S1, [{command, Tag, _}]} = step({bus, Request}, S),
                        {S2, [{reply, bus, _}]} = step({complete, Tag, ?SUCCESS, Extra}, S1),
                        S2
                end, State, Requests).

%% The core whose hub is addressed and whose device's Address Device at slot 2 failed
%% with Code, its teardown's first action awaited.
failed_address(Device, Code) ->
    {S1, [{reply, enabling, {ok, ?DEV}}]} = enable(?DEV_REF, enabling, ?DEV, hub_addressed()),
    {S2, [{command, T2, {address_device, ?DEV, _}}]} = step({bus, {address, ?DEV_REF, addressing, Device}}, S1),
    step({complete, T2, Code, 0}, S2).

%% The steps a reset of Pipe takes from Queue, every one answered with success, until
%% its caller is answered ok.
reset_steps(Device, Pipe, Queue) ->
    {S0, _} = addressed(Device),
    run_reset(step({reset_pipe, me, Pipe, Queue}, S0), []).

run_reset({_, [{reply, me, ok}]}, Steps) ->
    lists:reverse(Steps);
run_reset({S, [{command, Tag, Command}]}, Steps) ->
    run_reset(step({complete, Tag, ?SUCCESS, none}, S), [{command, element(1, Command)} | Steps]);
run_reset({S, [{transfer, ?HUB_EP0, Tag, {control, Setup, none}}]}, Steps) ->
    run_reset(step({complete, Tag, ?SUCCESS, <<>>}, S), [{tt, ?HUB_EP0, Setup} | Steps]);
run_reset({S, [{transfer, Pipe, Tag, {control, Setup, none}}]}, Steps) ->
    run_reset(step({complete, Tag, ?SUCCESS, <<>>}, S), [{request, Pipe, Setup} | Steps]).

%% The explorations

%% Every state reachable from M0 by the events Events gives, each checked by the model
%% as it is reached and, by Drained, for whether every later success brings it to rest.
%% Each state keeps the state and event it was first reached by, so a failure names the
%% events that lead to it.
fixed_point(M0, Events, Drained) ->
    fixed_point([M0], #{M0 => root}, Events, Drained).

fixed_point([], Seen, _Events, _Drained) ->
    {ok, map_size(Seen)};
fixed_point([M | Rest], Seen, Events, Drained) ->
    Next = [{Event, Followed} || Event <- Events(M), Followed <- [follow(Event, M)], Followed =/= ended],
    case [Why || {_, {error, Why}} <- Next] ++ Drained(M) of
        [] ->
            New = maps:from_list([{N, {M, Event}} || {Event, {ok, N}} <- Next, not is_map_key(N, Seen)]),
            fixed_point(maps:keys(New) ++ Rest, maps:merge(New, Seen), Events, Drained);
        [Why | _] ->
            {error, Why, trace(M, Seen, [])}
    end.

trace(M, Seen, Events) ->
    case Seen of
        #{M := root} -> Events;
        #{M := {Parent, Event}} -> trace(Parent, Seen, [Event | Events])
    end.

%% The state Event leads to from M; or `ended`, when an abort's request to a hub whose
%% EP0 is halted or in its own reset fails and so fails the controller, as the design
%% has it, whose restart is the rest of that world.
follow(Event, M) ->
    try {ok, apply_event(Event, M)}
    catch
        throw:{failed, {abort_failed, _Pipe, Reason}} when Reason =:= halted; Reason =:= resetting -> ended;
        throw:Why -> {error, {Event, Why}}
    end.

%% The model beside the core: each queue's state as the NIF keeps it (open, stopping,
%% stopped, halted), the transfers posted on each, the command in flight, the callers
%% not yet answered, for each pipe a caller is resetting or whose request an abort is
%% running, what has been done to it; the time, 0 until the clock moves once to the
%% control requests' deadline; and whether the device has detached and its slot has
%% been disabled.
explore(Device, Features) ->
    {Core, _} = addressed(Device),
    fixed_point(#{world => pipes, core => Core, device => Device, features => Features,
                  queues => #{?HUB_EP0 => open, ?DEV_EP0 => open, ?BULK => open},
                  posted => #{}, command => none, callers => #{}, done => #{},
                  aborts => #{}, now => 0, ticked => false, detached => false, disabled => false},
                fun pipe_events/1, fun pipe_drained/1).

%% The events the model allows in M.
pipe_events(M = #{posted := Posted, callers := Callers}) ->
    Posts = [{caller_post, P} || P <- [?HUB_EP0, ?DEV_EP0, ?BULK], not is_map_key({post, P}, Callers)],
    Resets = [{caller_reset, P} || P <- [?DEV_EP0, ?BULK], not is_map_key({reset, P}, Callers)],
    Transfers = [{transfer_answer, Tag, Code} || {Tag, {P, Purpose}} <- lists:sort(maps:to_list(Posted)),
                                                 running(queue(P, M)),
                                                 Code <- transfer_codes(Purpose, M)],
    Posts ++ Resets ++ Transfers ++ command_answers(M) ++ world_events(M).

%% A transfer may succeed, stall or meet a transaction error, but the translator's clear
%% an abort sends only succeeds, since its failure fails the controller.
transfer_codes({tt_cleared, Pipe}, #{aborts := Aborts}) when is_map_key(Pipe, Aborts) -> [?SUCCESS];
transfer_codes(_Purpose, _M) -> [?SUCCESS, ?STALL, ?TRANSACTION_ERROR].

running(Queue) -> Queue =:= open orelse Queue =:= stopping.

%% The answers the command in flight may get: a stop's success, or a context state error
%% when its queue halted; Disable Slot's and Enable Slot's success; Address Device's
%% success with the address, a USB Transaction Error and a context state error; any
%% other command's success or a TRB error, but a request of the abort, whose failure
%% fails the controller, only success.
command_answers(#{command := none}) ->
    [];
command_answers(M = #{command := {_Tag, {stop_endpoint, Slot, Dci}}}) ->
    case queue({Slot, Dci}, M) of
        halted -> [{command_answer, ?CONTEXT_STATE_ERROR, none}];
        stopping -> [{command_answer, ?SUCCESS, none}]
    end;
command_answers(#{command := {_Tag, {disable_slot, _Slot}}}) ->
    [{command_answer, ?SUCCESS, none}];
command_answers(#{command := {_Tag, enable_slot}}) ->
    [{command_answer, ?SUCCESS, ?DEV}];
command_answers(#{command := {_Tag, {address_device, _Slot, _}}}) ->
    [{command_answer, Code, Extra} || {Code, Extra} <- [{?SUCCESS, ?DEV_ADDRESS}, {?TRANSACTION_ERROR, 0},
                                                         {?CONTEXT_STATE_ERROR, 0}]];
command_answers(#{world := address}) ->
    [{command_answer, ?SUCCESS, none}];
command_answers(#{command := {_Tag, {_Kind, Slot, 1}}, aborts := Aborts}) when is_map_key({Slot, 1}, Aborts) ->
    [{command_answer, ?SUCCESS, none}];
command_answers(_M) ->
    [{command_answer, ?SUCCESS, none}, {command_answer, ?TRB_ERROR, none}].

%% The device's detach, once, and the clock moved once to the earliest control
%% deadline, while no command is in flight, whose own deadline the move would pass.
world_events(M = #{features := Features, core := Core, command := Command}) ->
    Detach = [detach || maps:get(detach, Features, false), not maps:get(detached, M)],
    Tick = case erx_xhci_core:next_deadline(Core) of
               At when is_integer(At), Command =:= none -> [tick || maps:get(tick, Features, false),
                                                                   not maps:get(ticked, M)];
               _ -> []
           end,
    Detach ++ Tick.

queue(Pipe, #{queues := Queues}) ->
    case Queues of
        #{Pipe := Queue} -> Queue;
        #{} -> throw({no_queue, Pipe})
    end.

apply_event({caller_post, Pipe}, M = #{callers := Callers, detached := Detached, core := Core, now := Now}) ->
    Who = {post, Pipe},
    Transfer = case Pipe of
                   ?BULK -> {normal, {in, 64}};
                   _ -> {control, ?GET_STATUS, {in, 2}}
               end,
    case Detached andalso element(1, Pipe) =:= ?DEV of
        true ->
            case at(Now, {post, Who, Pipe, Transfer}, Core) of
                {Next, [{reply, Who, {error, gone}}]} -> M#{core := Next};
                {_, Actions} -> throw({detached_post_reached, Actions})
            end;
        false ->
            run({post, Who, Pipe, Transfer}, M#{callers := Callers#{Who => true}})
    end;
apply_event({caller_reset, Pipe}, M = #{callers := Callers, done := Done, posted := Posted}) ->
    Report = case maps:get(Pipe, maps:get(queues, M), gone) of
                 halted -> halted;
                 stopped -> stopped;
                 _RunningOrGone -> case [T || T := {P, _} <- Posted, P =:= Pipe] of [] -> idle; _ -> busy end
             end,
    Facts = [halted || Report =:= halted],
    run({reset_pipe, {reset, Pipe}, Pipe, Report},
        M#{callers := Callers#{{reset, Pipe} => true}, done := Done#{Pipe => Facts}});
apply_event({transfer_answer, Tag, Code}, M = #{posted := Posted, queues := Queues}) ->
    #{Tag := {Pipe, Purpose}} = Posted,
    M1 = completed(Purpose, Code, M#{posted := maps:remove(Tag, Posted)}),
    M2 = case Code of
             ?SUCCESS -> record(Purpose, M1);
             _Halts -> halt_queue(Pipe, M1#{queues := Queues#{Pipe := halted}})
         end,
    run({complete, Tag, Code, <<>>}, M2);
apply_event({command_answer, Code, Extra}, M = #{command := {Tag, Command}, posted := Posted}) ->
    {M1, Stopped} = command_done(Command, Code, M#{command := none}),
    M2 = lists:foldl(fun(T, Acc) ->
                             {_Pipe, Purpose} = maps:get(T, Posted),
                             run({complete, T, ?STOPPED, <<>>}, completed(Purpose, ?STOPPED, Acc))
                     end, M1, Stopped),
    M3 = #{aborts := Aborts} = run({complete, Tag, Code, Extra}, M2),
    case {Command, Code} of
        {{set_tr_dequeue, Slot, 1}, ?SUCCESS} -> M3#{aborts := maps:remove({Slot, 1}, Aborts)};
        _ -> M3
    end;
apply_event(detach, M) ->
    run({bus, {detach, ?DEV_REF}}, M#{detached := true});
apply_event(tick, M = #{core := Core, posted := Posted, queues := Queues, callers := Callers, detached := Detached}) ->
    Aborted = [P || {P = {Slot, 1}, _} <- maps:values(Posted), maps:get(P, Queues) =:= open,
                    not is_map_key({reset, P}, Callers), not (Detached andalso Slot =:= ?DEV)],
    Ticked = M#{now := erx_xhci_core:next_deadline(Core), ticked := true, aborts := maps:from_keys(Aborted, [])},
    run(expired, case Ticked of
                     #{tt_clear := posted} -> Ticked#{tt_clear := aborted};
                     _ -> Ticked
                 end).

%% The translator's clear after a failed address has completed, as it completed, unless
%% its deadline passed first, when its abort answers it.
completed(address_tt_clear, _Code, M = #{tt_clear := aborted}) -> M;
completed(address_tt_clear, Code, M) -> M#{tt_clear := {done, Code}};
completed(_Purpose, _Code, M) -> M.

%% A queue that halts records the halt for a reset or an abort in progress on it.
halt_queue(Pipe, M) -> record({halted, Pipe}, M).

record(Purpose, M) when is_atom(Purpose) -> M;
record({Fact, Pipe}, M = #{done := Done, aborts := Aborts}) ->
    Add = fun(Facts) -> lists:usort([Fact | Facts]) end,
    M#{done := maps:map(fun(Key, Facts) when Key =:= Pipe -> Add(Facts); (_Key, Facts) -> Facts end, Done),
       aborts := maps:map(fun(Key, Facts) when Key =:= Pipe -> Add(Facts); (_Key, Facts) -> Facts end, Aborts)}.

%% The NIF's state changes on a command's answer, and the transfers a successful restart
%% of a ring, or a slot's disable, answers `stopped`.
command_done({stop_endpoint, Slot, Dci}, Code, M = #{queues := Queues}) ->
    Pipe = {Slot, Dci},
    case {maps:get(Pipe, Queues), Code} of
        {halted, ?CONTEXT_STATE_ERROR} -> {M, []};
        {stopping, ?SUCCESS} -> {M#{queues := Queues#{Pipe := stopped}}, []}
    end;
command_done({reset_endpoint, Slot, Dci}, ?SUCCESS, M = #{queues := Queues}) ->
    {record({host_toggle, {Slot, Dci}}, M#{queues := Queues#{{Slot, Dci} := stopped}}), []};
command_done({set_tr_dequeue, Slot, Dci}, ?SUCCESS, M) ->
    restarted([{Slot, Dci}], M);
command_done({configure_endpoints, Slot, #{drop := [Dci]}}, ?SUCCESS, M) ->
    restarted([{Slot, Dci}], record({host_toggle, {Slot, Dci}}, M));
command_done({disable_slot, Slot}, ?SUCCESS, M = #{queues := Queues}) ->
    Gone = [P || P = {S, _} <- maps:keys(Queues), S =:= Slot],
    {M1 = #{queues := Left}, Stopped} = restarted(Gone, M),
    {M1#{queues := maps:without(Gone, Left), disabled := true, enabled => false}, Stopped};
command_done(enable_slot, ?SUCCESS, M) ->
    {M#{enabled := true}, []};
command_done({address_device, Slot, _}, ?SUCCESS, M = #{queues := Queues}) ->
    {M#{queues := Queues#{{Slot, 1} => open}}, []};
command_done({address_device, _Slot, _}, _Failed, M) ->
    {M#{failed := true}, []};
command_done({configure_endpoints, Slot, #{add := Add, drop := []}}, ?SUCCESS, M = #{world := configure}) ->
    #{queues := Queues} = M,
    Bound = [{Slot, endpoint_dci(EpAddress)} || #{address := EpAddress} <- Add],
    {M#{queues := maps:merge(Queues, maps:from_keys(Bound, open))}, []};
command_done({configure_endpoints, _Slot, #{drop := []}}, _Failed, M = #{world := configure}) ->
    {M#{failed := true}, []};
command_done(_Command, _Failed, M) ->
    {M, []}.

restarted(Pipes, M = #{queues := Queues, posted := Posted}) ->
    Stopped = lists:sort([T || T := {P, _} <- Posted, lists:member(P, Pipes)]),
    {M#{queues := maps:merge(Queues, maps:from_keys(Pipes, open)), posted := maps:without(Stopped, Posted)}, Stopped}.

%% Runs one event through the core and applies its actions to the model; a transfer the
%% model's NIF refuses is fed back as refused.
run(Event, M = #{core := Core, now := Now}) ->
    {Core1, Actions} = at(Now, Event, Core),
    {M1, Followups} = lists:foldl(fun act/2, {M#{core := Core1}, []}, Actions),
    lists:foldl(fun run/2, M1, lists:reverse(Followups)).

act({command, _Tag, _Command}, {#{command := {_, _}}, _}) ->
    throw(two_commands_in_flight);
act({command, Tag, Command}, {M, Followups}) ->
    {accept_command(Command, M#{command := {Tag, Command}}), Followups};
act({transfer, Pipe, Tag, Transfer}, {M = #{posted := Posted}, Followups}) ->
    Ep0Busy = element(2, Pipe) =:= 1 andalso [T || T := {P, _} <- Posted, P =:= Pipe] =/= [],
    case queue(Pipe, M) of
        _ when Ep0Busy -> throw({two_requests_on, Pipe});
        open -> {posted(Tag, Pipe, purpose(Pipe, Transfer, M), M), Followups};
        _NotOpen -> {M, [{refused, Tag, halted} | Followups]}
    end;
act({reply, From, Answer}, {M = #{world := address}, Followups}) ->
    address_answered(From, Answer, M, Followups);
act({reply, configuring, Answer}, {M = #{world := configure}, Followups}) ->
    {configure_answered(Answer, M), Followups};
act({reply, From, Answer}, {M = #{callers := Callers}, Followups}) ->
    case Callers of
        #{From := _} -> {answered(From, Answer, M#{callers := maps:remove(From, Callers)}), Followups};
        #{} -> throw({answered_twice, From, Answer})
    end;
act({fail, Reason}, _Acc) ->
    throw({failed, Reason}).

%% A transfer posted, for Purpose; the failed address's translator clear is awaited.
posted(Tag, Pipe, address_tt_clear, M = #{posted := Posted}) ->
    M#{posted := Posted#{Tag => {Pipe, address_tt_clear}}, tt_clear := posted};
posted(Tag, Pipe, Purpose, M = #{posted := Posted}) ->
    M#{posted := Posted#{Tag => {Pipe, Purpose}}}.

%% The commands the NIF accepts in each queue state (design-usb.md, "Queues and their
%% states"), and the state a stop moves its queue to. Disable Slot is accepted only when
%% every queue of the slot is stopped, halted or open with nothing posted (xHCI 4.6.4,
%% pp. 109-110).
accept_command(Command = {stop_endpoint, Slot, Dci}, M = #{queues := Queues}) ->
    case queue({Slot, Dci}, M) of
        open -> M#{queues := Queues#{{Slot, Dci} := stopping}};
        Other -> throw({refused_by_nif, Command, Other})
    end;
accept_command(Command = {reset_endpoint, Slot, Dci}, M) ->
    accept_in([halted], {Slot, Dci}, Command, M);
accept_command(Command = {set_tr_dequeue, Slot, Dci}, M) ->
    accept_in([stopped], {Slot, Dci}, Command, M);
accept_command(Command = {configure_endpoints, Slot, #{add := Add, drop := []}},
               M = #{world := configure, queues := Queues, failed := Failed, configure_answer := Answer}) ->
    Pipes = [{Slot, endpoint_dci(EpAddress)} || #{address := EpAddress} <- Add],
    length(Add) =< ?ADDS_MAX orelse throw({refused_by_nif, Command, too_many_bindings}),
    lists:any(fun(Pipe) -> is_map_key(Pipe, Queues) end, Pipes) andalso throw({refused_by_nif, Command, bound}),
    (Failed orelse Answer =/= none) andalso throw({posted_after_its_answer, Command}),
    M;
accept_command(Command = {configure_endpoints, _Slot, #{drop := [1]}}, _M) ->
    throw({refused_by_nif, Command, ep0_dropped});
accept_command(Command = {configure_endpoints, Slot, #{drop := [Dci], add := [_]}}, M = #{posted := Posted}) ->
    Pipe = {Slot, Dci},
    case [T || T := {P, _} <- Posted, P =:= Pipe] of
        [] -> accept_in([stopped, open], Pipe, Command, M);
        _ -> accept_in([stopped], Pipe, Command, M)
    end;
accept_command(Command = {disable_slot, Slot}, M = #{queues := Queues, posted := Posted}) ->
    maps:get(enabled, M, true) orelse throw({refused_by_nif, Command, not_enabled}),
    Running = [{P, Q} || P = {S, _} := Q <- Queues, S =:= Slot,
                         Q =:= stopping orelse (Q =:= open andalso lists:keymember(P, 1, maps:values(Posted)))],
    Running =:= [] orelse throw({refused_by_nif, Command, Running}),
    M;
accept_command(enable_slot, M = #{world := address, enabled := false, disabled := false}) ->
    M;
accept_command({address_device, ?DEV, #{}}, M = #{world := address, enabled := true}) ->
    M;
accept_command(Command, _M) ->
    throw({unexpected_command, Command}).

accept_in(States, Pipe, Command, M) ->
    case lists:member(queue(Pipe, M), States) of
        true -> M;
        false -> throw({refused_by_nif, Command, queue(Pipe, M)})
    end.

%% What a request the core posts is for: a caller's own transfer, the device's side of
%% a pipe's reset, or the translator's buffer for a pipe or, after a failed address, for
%% address 0's default control endpoint; a CLEAR_TT_BUFFER is checked against the device
%% and the endpoint it names, and the failed address's only after the slot's disable.
purpose(_Pipe, {control, <<16#02, 1, 0:16, EpAddress:16/little, 0:16>>, none}, _M) ->
    {device_toggle, {?DEV, endpoint_dci(EpAddress)}};
purpose(?HUB_EP0, {control, <<16#23, 8, Value:16/little, Index:16/little, 0:16>>, none}, M = #{device := Device}) ->
    #{tt := #{port := Port, multi := Multi}} = Device,
    EpAddress = (Value band 16#f) bor ((Value bsr 8) band 16#80),
    %% USB 2.0, Table 11-18: the endpoint type is bits 12..11.
    Type = case (Value bsr 11) band 3 of 0 -> control; 2 -> bulk end,
    Expected = case Multi of true -> Port; false -> 1 end,
    case {(Value bsr 4) band 16#7f, Index, {endpoint_dci(EpAddress), Type}} of
        {?DEV_ADDRESS, Expected, {1, control}} -> {tt_cleared, ?DEV_EP0};
        {?DEV_ADDRESS, Expected, {5, bulk}} -> {tt_cleared, ?BULK};
        {0, Expected, {1, control}} when map_get(world, M) =:= address, map_get(disabled, M) -> address_tt_clear;
        Wrong -> throw({wrong_tt_clear, Wrong})
    end;
purpose(_Pipe, _Transfer, _M) ->
    none.

endpoint_dci(0) -> 1;
endpoint_dci(EpAddress) -> 2 * (EpAddress band 16#f) + (EpAddress bsr 7).

%% A reset answered ok left the queue open; a bulk pipe's reset reset both toggles; and
%% one that met a halt cleared the translator's buffer for an endpoint behind one. An
%% aborted request is answered timeout only with its EP0 open again, the translator's
%% buffer cleared when the abort met a halt.
answered({reset, Pipe}, ok, M = #{done := Done}) ->
    Needed = [host_toggle || Pipe =:= ?BULK] ++ [device_toggle || Pipe =:= ?BULK] ++ tt_needed(Pipe, M),
    settled(Pipe, Needed, maps:get(Pipe, Done), M#{done := maps:remove(Pipe, Done)});
answered({reset, Pipe}, _Failed, M = #{done := Done}) ->
    M#{done := maps:remove(Pipe, Done)};
answered({post, Pipe}, {error, timeout}, M = #{aborts := Aborts}) ->
    #{Pipe := Facts} = Aborts,
    settled(Pipe, tt_needed(Pipe, Facts, M), Facts, M);
answered({post, _Pipe}, _Answer, M) ->
    M.

tt_needed(Pipe, M = #{done := Done}) -> tt_needed(Pipe, maps:get(Pipe, Done), M).

tt_needed(Pipe, Facts, #{device := Device}) ->
    [tt_cleared || Pipe =/= ?HUB_EP0, lists:member(halted, Facts), maps:get(tt, Device) =/= none,
                   maps:get(speed, Device) =/= high].

settled(Pipe, Needed, Facts, M) ->
    case {queue(Pipe, M), Needed -- Facts} of
        {open, []} -> M;
        Wrong -> throw({settled_wrongly, Pipe, Wrong})
    end.

%% From M, with every later answer a success, every caller is answered, and a detached
%% device's slot disabled, within 100 events. A transfer still posted on a ring that
%% does not run, a caller's or a reset's request, waits for the pipe's next reset, which
%% a caller's failure brings in the system (the bus detaches a device whose control pipe
%% fails), so the drain resets each pipe of a device still attached that holds one, or
%% holds a caller's post, and has no caller's reset outstanding.
pipe_drained(M) -> drained(M, 100).

drained(#{callers := Callers, detached := Detached, disabled := Disabled}, _Budget)
  when map_size(Callers) =:= 0, Disabled orelse not Detached ->
    [];
drained(M, 0) ->
    [{never_drained, maps:keys(maps:get(callers, M)), maps:get(disabled, M)}];
drained(M = #{callers := Callers, posted := Posted, queues := Queues, detached := Detached}, Budget) ->
    Successes = successes(pipe_events(M)),
    Holding = [P || {post, P} <- maps:keys(Callers)]
        ++ [P || {P, _} <- maps:values(Posted), not running(maps:get(P, Queues))],
    Resets = [{caller_reset, P} || P <- lists:usort(Holding), not is_map_key({reset, P}, Callers),
                                   not (Detached andalso element(1, P) =:= ?DEV)],
    case Successes ++ Resets of
        [] -> [{never_drained, maps:keys(Callers)}];
        [Event | _] ->
            case follow(Event, M) of
                {ok, Next} -> drained(Next, Budget - 1);
                ended -> [];
                {error, Why} -> [Why]
            end
    end.

successes(Events) ->
    [E || E = {transfer_answer, _, ?SUCCESS} <- Events]
        ++ [E || E = {command_answer, Code, _} <- Events, Code =/= ?TRB_ERROR, Code =/= ?TRANSACTION_ERROR].

%% The failed Address Device explored: from a hub addressed at slot 1 and the device's
%% Enable Slot posted, every answer of each command (the address's success, a USB
%% Transaction Error, a context state error), the translator clear's success or STALL,
%% the device's detach at any point and the clock moved once to the clear's deadline.
%% Checked at each state: the Enable Slot answers the slot unless the device detached,
%% gone then; every Address Device the bus sends is answered exactly once, a success with
%% the address, a failure only after its slot's Disable Slot and, on a transaction error
%% behind a translator, after CLEAR_TT_BUFFER for address 0's control endpoint has
%% completed, with the address error when the clear succeeded and the clear's failure
%% otherwise; the clear is posted only after the disable; Disable Slot is accepted by
%% the NIF; and from every state, with every later answer a success, the Address Device
%% is answered and a detached or failed device's slot disabled.
explore_address(Device) ->
    {Core0, [{command, Tag, enable_slot}]} = step({bus, {enable_slot, ?DEV_REF, enabling}}, hub_addressed()),
    fixed_point(#{world => address, core => Core0, device => Device, features => #{detach => true, tick => true},
                  queues => #{?HUB_EP0 => open}, posted => #{}, command => {Tag, enable_slot}, done => #{}, aborts => #{},
                  callers => #{},
                  now => 0, ticked => false, detached => false, disabled => false, enabled => false,
                  failed => false, slot_answer => none, address_sent => false, address_answer => none,
                  tt_clear => none},
                fun address_events/1, fun address_drained/1).

address_events(M = #{posted := Posted}) ->
    Transfers = [{transfer_answer, Tag, Code} || {Tag, {P, _}} <- lists:sort(maps:to_list(Posted)),
                                                 running(queue(P, M)), Code <- [?SUCCESS, ?STALL]],
    Transfers ++ command_answers(M) ++ world_events(M).

%% The bus process's side: the slot's answer sends the Address Device at once, unless
%% the device detached; each answer is checked against what the model has seen.
address_answered(enabling, Answer, M = #{slot_answer := none, detached := Detached}, Followups) ->
    case {Answer, Detached} of
        {{ok, ?DEV}, false} ->
            {M#{slot_answer := Answer, address_sent := true},
             [{bus, {address, ?DEV_REF, addressing, maps:get(device, M)}} | Followups]};
        {{error, gone}, true} ->
            {M#{slot_answer := Answer}, Followups};
        _ ->
            throw({wrong_slot_answer, Answer, Detached})
    end;
address_answered(addressing, Answer, M = #{address_answer := none, address_sent := true}, Followups) ->
    check_address_answer(Answer, M),
    {M#{address_answer := Answer}, Followups};
address_answered(From, Answer, _M, _Followups) ->
    throw({unexpected_answer, From, Answer}).

check_address_answer({ok, ?DEV_ADDRESS}, #{failed := false}) ->
    ok;
check_address_answer(Answer, #{failed := true, disabled := true, device := #{tt := Tt}, tt_clear := Clear,
                                 core := _}) ->
    Expected = case {Clear, Tt} of
                   {none, _} -> any_address_error;
                   {{done, ?SUCCESS}, #{}} -> {error, {address, transaction_error}};
                   {{done, ?STALL}, #{}} -> {error, {tt_clear, stall}};
                   {aborted, #{}} -> {error, {tt_clear, timeout}};
                   _ -> throw({address_answered_before_clear, Answer})
               end,
    case {Expected, Answer} of
        {any_address_error, {error, {address, Code}}} when Code =/= transaction_error; Tt =:= none -> ok;
        {Answer, Answer} -> ok;
        _ -> throw({wrong_address_answer, Answer, Expected})
    end;
check_address_answer(Answer, M) ->
    throw({address_answered_early, Answer, maps:with([failed, disabled, tt_clear], M)}).

%% From M, with every later answer a success, the Address Device sent is answered and a
%% detached or failed device's slot disabled, within 60 events.
address_drained(M) ->
    settles(M, 60, fun address_events/1, [slot_answer, address_answer, disabled],
            fun(#{slot_answer := SlotAnswer, address_sent := Sent, address_answer := AddressAnswer,
                  detached := Detached, failed := Failed, disabled := Disabled}) ->
                    SlotAnswer =/= none andalso (not Sent orelse AddressAnswer =/= none)
                        andalso (Disabled orelse not (Detached orelse Failed))
            end).

%% The failures met following, from M, the first success Events allows at each state
%% until Settled holds: none when it holds within Budget events, else the one that
%% stopped the drain, naming Shown of the state where it stopped.
settles(M, Budget, Events, Shown, Settled) ->
    case {Settled(M), Budget, successes(Events(M))} of
        {true, _, _} -> [];
        {false, 0, _} -> [{never_drained, maps:with(Shown, M)}];
        {false, _, []} -> [{never_drained, maps:with(Shown, M)}];
        {false, _, [Event | _]} ->
            case follow(Event, M) of
                {ok, Next} -> settles(Next, Budget - 1, Events, Shown, Settled);
                ended -> [];
                {error, Why} -> [Why]
            end
    end.

%% A device's configuration explored: from a hub and a high-speed device addressed, the
%% bus's Configure Endpoint for Count bulk pipes, every answer of each command the core
%% posts for it (success and a TRB error) and the device's detach at any point. Checked
%% at each state: each command adds at most ADDS_MAX endpoints, none already bound, and
%% none is posted once a part has failed or the bus has been answered; the bus is
%% answered once, ok only when the device has detached or every pipe is bound in the
%% NIF and takes a post in the core, and an error only after a part failed or the
%% device detached; and from every state, with
%% every later answer a success, the bus is answered and a detached device's slot
%% disabled.
explore_configure(Count) ->
    Core = requested([{{enable_slot, ?DEV_REF, bus}, ?DEV},
                           {{address, ?DEV_REF, bus, lists:last(devices())}, ?DEV_ADDRESS}],
                          hub_addressed()),
    Pipes = [(bulk())#{address := 16#80 + Number} || Number <- lists:seq(1, Count)],
    M0 = #{world => configure, core => Core, features => #{detach => true},
           queues => #{?HUB_EP0 => open, ?DEV_EP0 => open}, posted => #{}, command => none, callers => #{},
           done => #{}, aborts => #{}, now => 0, ticked => false, detached => false, disabled => false,
           wanted => lists:sort([{?DEV, endpoint_dci(EpAddress)} || #{address := EpAddress} <- Pipes]),
           failed => false, configure_answer => none},
    fixed_point(run({bus, {configure_endpoints, ?DEV_REF, configuring, #{add => Pipes, hub => none}}}, M0),
                fun configure_events/1, fun configure_drained/1).

configure_events(M) -> command_answers(M) ++ world_events(M).

configure_answered(Answer, M = #{configure_answer := none, failed := Failed, detached := Detached}) ->
    #{queues := Queues, wanted := Wanted} = M,
    Bound = lists:sort([Pipe || Pipe = {?DEV, Dci} <- maps:keys(Queues), Dci =/= 1]),
    case {Answer, Failed} of
        {ok, false} when Detached -> ok;
        {ok, false} when Bound =:= Wanted -> lists:foreach(fun(Pipe) -> takes_a_post(Pipe, M) end, Wanted);
        {{error, _}, _} when Failed; Detached -> ok;
        _ -> throw({wrong_configure_answer, Answer, #{bound => Bound, failed => Failed, detached => Detached}})
    end,
    M#{configure_answer := Answer};
configure_answered(Answer, _M) ->
    throw({answered_twice, configuring, Answer}).

%% A post on Pipe reaches the NIF: the core holds the pipe open. The probe's state is
%% not kept.
takes_a_post(Pipe, #{core := Core, now := Now}) ->
    case at(Now, {post, probe, Pipe, {normal, {in, 64}}}, Core) of
        {_, [{transfer, Pipe, _Tag, _Transfer}]} -> ok;
        {_, Actions} -> throw({configured_pipe_refuses_posts, Pipe, Actions})
    end.

configure_drained(M) ->
    settles(M, 40, fun configure_events/1, [configure_answer, disabled],
            fun(#{configure_answer := Answer, detached := Detached, disabled := Disabled}) ->
                    Answer =/= none andalso (Disabled orelse not Detached)
            end).
%% The start, the root ports and the interrupt pass (docs/design-usb.md, "The controller
%% process"). Register words are written out: PORTSC's bits (xHCI 5.4.8, Table 5-27, pp.
%% 405-413) are PED 16#2, PR 16#10, PLS 16#1e0, PP 16#200, speed 16#3c00, LWS 16#10000,
%% the change bits CSC 16#20000 to CEC 16#800000 and WPR 16#80000000; the bits a write
%% keeps are PP, PIC and the wake enables, 16#e00c200.

-define(PS_PED, 16#2).
-define(PS_PR, 16#10).
-define(PS_PP, 16#200).
-define(PS_LWS, 16#10000).
-define(PS_CSC, 16#20000).
-define(PS_PEC, 16#40000).
-define(PS_WRC, 16#80000).
-define(PS_OCC, 16#100000).
-define(PS_PRC, 16#200000).
-define(PS_PLC, 16#400000).
-define(PS_CEC, 16#800000).
-define(PS_WPR, 16#80000000).
-define(PS_CHANGES, 16#fe0000).
-define(PS_KEPT, 16#e00c200).

%% HCSPARAMS1: 32 slots, 1 interrupter, 4 ports; HCSPARAMS2: 0 scratchpads; HCCPARAMS1:
%% AC64; PAGESIZE: 4 KiB. Protocol 1: USB 2 on ports 1-2; protocol 2: USB 3 on 3-4.
capability_words() ->
    #{hcsparams1 => 16#04000120, hcsparams2 => 0, hccparams1 => 1, pagesize => 1,
      {protocol, 1, revision} => 16#02000802, {protocol, 1, ports} => 16#0201,
      {protocol, 2, revision} => 16#03000002, {protocol, 2, ports} => 16#0203}.

-define(BOUND, #{legacy => true, protocols => 2}).

%% A controller whose bus process has attached, or not, started to its BIOS handoff at
%% time 0, the core's first actions checked.
handoff_started() -> handoff_started(attached).

handoff_started(Bus) ->
    Regs = [hcsparams1, hcsparams2, hccparams1, pagesize,
            {protocol, 1, revision}, {protocol, 1, ports}, {protocol, 2, revision}, {protocol, 2, ports}],
    {S1, [{read, Regs}]} = erx_xhci_core:step({start, ?BOUND}, 0, new(Bus)),
    {S2, [{write, {legacy, os_owned}, 1}, {read, [{legacy, bios_owned}]}]} =
        erx_xhci_core:step({read, capability_words()}, 0, S1),
    S2.

%% A new controller, with its bus process attached or not.
new(attached) -> element(1, erx_xhci_core:step({bus, attach}, 0, erx_xhci_core:new()));
new(unattached) -> erx_xhci_core:new().

%% A running controller of capability_words(), its bus started.
running() ->
    {S1, [negotiate]} = erx_xhci_core:step({read, #{{legacy, bios_owned} => 0}}, 0, handoff_started()),
    {S2, [{bus, {root_ports, 4}}]} = erx_xhci_core:step({negotiated, ok}, 0, S1),
    S2.

the_start_reads_hands_off_and_installs_test() ->
    S0 = handoff_started(),
    ?assertMatch(#{ports := 4, slots := 32, interrupters := 1, scratchpads := 0, ac64 := true,
                   context_bytes := 32, protocols := #{1 := 2, 2 := 2, 3 := 3, 4 := 3}},
                 erx_xhci_core:capabilities(S0)),
    %% The BIOS still owns it: read again 10 ms later, then released.
    {S1, []} = erx_xhci_core:step({read, #{{legacy, bios_owned} => 1}}, 0, S0),
    ?assertEqual(10, erx_xhci_core:next_deadline(S1)),
    ?assertEqual({S1, []}, erx_xhci_core:step(expired, 9, S1)),
    {S2, [{read, [{legacy, bios_owned}]}]} = erx_xhci_core:step(expired, 10, S1),
    {S3, [negotiate]} = erx_xhci_core:step({read, #{{legacy, bios_owned} => 0}}, 10, S2),
    %% The install answers ebusy: called again 10 ms later, then ok starts the bus.
    {S4, []} = erx_xhci_core:step({negotiated, {error, ebusy}}, 12, S3),
    ?assertEqual(22, erx_xhci_core:next_deadline(S4)),
    {S5, [{negotiate, continue}]} = erx_xhci_core:step(expired, 22, S4),
    ?assertMatch({_, [{bus, {root_ports, 4}}]}, erx_xhci_core:step({negotiated, ok}, 23, S5)),
    ?assertMatch({_, [{fail, {install, eio}}]}, erx_xhci_core:step({negotiated, {error, eio}}, 23, S5)),
    %% Without a legacy support capability the install follows the capabilities.
    {N1, _} = erx_xhci_core:step({start, #{legacy => false, protocols => 0}}, 0, erx_xhci_core:new()),
    ?assertMatch({_, [negotiate]},
                 erx_xhci_core:step({read, maps:with([hcsparams1, hcsparams2, hccparams1, pagesize],
                                                     capability_words())}, 0, N1)).

%% The first negotiate after new/0 begins a negotiation and only the retries after ebusy
%% continue it, so a restarted controller process, which starts from new/0, begins
%% afresh whatever step the device record kept (docs/design-usb.md, "Install").
only_the_retry_continues_a_negotiation_test() ->
    Install = fun() ->
                      {N1, _} = erx_xhci_core:step({start, #{legacy => false, protocols => 0}}, 0,
                                                   erx_xhci_core:new()),
                      erx_xhci_core:step({read, maps:with([hcsparams1, hcsparams2, hccparams1, pagesize],
                                                          capability_words())}, 0, N1)
              end,
    {S1, [negotiate]} = Install(),
    {S2, []} = erx_xhci_core:step({negotiated, {error, ebusy}}, 1, S1),
    {S3, [{negotiate, continue}]} = erx_xhci_core:step(expired, erx_xhci_core:next_deadline(S2), S2),
    {S4, []} = erx_xhci_core:step({negotiated, {error, ebusy}}, 30, S3),
    ?assertMatch({_, [{negotiate, continue}]}, erx_xhci_core:step(expired, erx_xhci_core:next_deadline(S4), S4)).

the_start_gives_up_on_the_bios_and_on_the_install_test() ->
    Polled = lists:foldl(fun(At, S) ->
                                 {S1, [{read, _}]} = erx_xhci_core:step(expired, At, S),
                                 {S2, []} = erx_xhci_core:step({read, #{{legacy, bios_owned} => 1}}, At, S1),
                                 S2
                         end, element(1, erx_xhci_core:step({read, #{{legacy, bios_owned} => 1}}, 0,
                                                            handoff_started())),
                         lists:seq(10, 4990, 10)),
    {S1, [{read, _}]} = erx_xhci_core:step(expired, 5000, Polled),
    {S2, [{log, bios_handoff_timeout}, negotiate]} =
        erx_xhci_core:step({read, #{{legacy, bios_owned} => 1}}, 5000, S1),
    Busy = lists:foldl(fun(At, S) ->
                               {Sb, []} = erx_xhci_core:step({negotiated, {error, ebusy}}, At, S),
                               {Sc, [{negotiate, continue}]} = erx_xhci_core:step(expired, At + 10, Sb),
                               Sc
                       end, S2, lists:seq(5000, 7980, 10)),
    ?assertMatch({_, [{fail, install_timeout}]}, erx_xhci_core:step({negotiated, {error, ebusy}}, 8000, Busy)),
    %% Busy at 7999: called again at the deadline, 8000, no later; reached, it fails uncalled.
    {Late, []} = erx_xhci_core:step({negotiated, {error, ebusy}}, 7999, Busy),
    ?assertEqual(8000, erx_xhci_core:next_deadline(Late)),
    ?assertMatch({_, [{fail, install_timeout}]}, erx_xhci_core:step(expired, 8000, Late)).

the_start_refuses_capabilities_it_cannot_drive_test() ->
    Words = capability_words(),
    ?assertEqual({error, {unsupported, page_size}},
                 erx_xhci_core:decode_capabilities(Words#{pagesize => 2}, ?BOUND)),
    ?assertEqual({error, {malformed, {protocol, 2}}},
                 erx_xhci_core:decode_capabilities(Words#{{protocol, 2, ports} => 16#0204}, ?BOUND)),
    %% Protocol 2 on ports 2-3 overlaps protocol 1's 1-2: a port speaks one protocol.
    ?assertEqual({error, {malformed, {protocol, 2}}},
                 erx_xhci_core:decode_capabilities(Words#{{protocol, 2, ports} => 16#0202}, ?BOUND)),
    ?assertEqual({error, {malformed, {protocol, 1}}},
                 erx_xhci_core:decode_capabilities(Words#{{protocol, 1, ports} => 16#0200}, ?BOUND)),
    {S1, _} = erx_xhci_core:step({start, ?BOUND}, 0, erx_xhci_core:new()),
    ?assertMatch({_, [{fail, {capabilities, {unsupported, page_size}}}]},
                 erx_xhci_core:step({read, Words#{pagesize => 2}}, 0, S1)),
    %% An interrupt held while the capabilities are read is not acknowledged by the failure.
    {Held, []} = erx_xhci_core:step(interrupt, 0, S1),
    ?assertMatch({_, [{fail, {capabilities, {unsupported, page_size}}}]},
                 erx_xhci_core:step({read, Words#{pagesize => 2}}, 0, Held)),
    ?assertMatch({_, [{bus, {port_done, root, _, {error, halted}}}]}, erx_xhci_core:step({bus, {port, root, 1, get_status}}, 0, S1)).

%% Every root-port write over many PORTSC words: the enable bit only to disable, the
%% change bits only the ones its clear names, the reset only to reset, the kept bits as
%% read but port power when powering, and never the link state strobe or a warm reset.
portsc_writes_set_only_what_they_mean_test() ->
    rand:seed(exsss, {18, 18, 18}),
    Words = [0, 16#ffffffff | [1 bsl Bit || Bit <- lists:seq(0, 31)]]
        ++ [rand:uniform(1 bsl 32) - 1 || _ <- lists:seq(1, 2000)],
    Ops = [{power_on, ?PS_PP}, {reset, ?PS_PR}, {disable, ?PS_PED},
           {{clear, connection}, ?PS_CSC}, {{clear, enabled}, ?PS_PEC bor ?PS_CEC},
           {{clear, suspend}, ?PS_PLC}, {{clear, over_current}, ?PS_OCC},
           {{clear, reset}, ?PS_PRC bor ?PS_WRC}],
    [begin
         {[Written], ok, _} = erx_xhci_core:port_operation(Op, Word, ?PS_CHANGES),
         ?assertEqual({Op, Word, Set band ?PS_CHANGES}, {Op, Word, Written band ?PS_CHANGES}),
         ?assertEqual({Op, Word, Set band ?PS_PED}, {Op, Word, Written band ?PS_PED}),
         ?assertEqual({Op, Word, Set band ?PS_PR}, {Op, Word, Written band ?PS_PR}),
         ?assertEqual({Op, Word, (Word band ?PS_KEPT) bor (Set band ?PS_PP)}, {Op, Word, Written band ?PS_KEPT}),
         ?assertEqual({Op, Word, 0}, {Op, Word, Written band (?PS_LWS bor ?PS_WPR)})
     end || Word <- Words, {Op, Set} <- Ops],
    ?assertEqual({[], {error, badarg}, 0}, erx_xhci_core:port_operation({clear, test}, 0, 0)).

%% xHCI 4.19.2 (p. 322): a root port raises no further event until every change bit is
%% clear, so each one shows in wPortChange and the clear of the name it shows as clears it.
every_change_bit_can_be_cleared_test() ->
    Names = [{1, connection}, {2, enabled}, {4, suspend}, {8, over_current}, {16, reset}],
    [begin
         {[], {ok, <<0:16, Change:16/little>>, 0}, Bit} = erx_xhci_core:port_operation(get_status, Bit, 0),
         {Change, Name} = lists:keyfind(Change, 1, Names),
         {[Written], ok, 0} = erx_xhci_core:port_operation({clear, Name}, Bit, Bit),
         ?assertEqual({Bit, Bit}, {Bit, Written band ?PS_CHANGES})
     end || Bit <- [?PS_CSC, ?PS_PEC, ?PS_WRC, ?PS_OCC, ?PS_PRC, ?PS_PLC, ?PS_CEC]].

%% A clear writes only the change bits the port's last status read reported: a
%% configuration error that sets after a read that saw the enable change alone stays set
%% for the bus core's next read, and a name with nothing reported writes nothing.
a_clear_writes_only_what_was_reported_test() ->
    {[], {ok, _, _}, ?PS_PEC} = erx_xhci_core:port_operation(get_status, ?PS_PEC bor ?PS_PP, 0),
    {[Written], ok, 0} = erx_xhci_core:port_operation({clear, enabled}, ?PS_PEC bor ?PS_CEC bor ?PS_PP, ?PS_PEC),
    ?assertEqual(?PS_PEC, Written band ?PS_CHANGES),
    ?assertEqual({[], ok, 0}, erx_xhci_core:port_operation({clear, reset}, ?PS_PRC, 0)).

%% Root ports are 1 to the port count: the bus's operation on another is refused without
%% a read, and a port event naming one fails the controller, which wrote it.
root_ports_are_bounded_test() ->
    S0 = running(),
    ?assertMatch({_, [{bus, {port_done, root, _, {error, badarg}}}]}, erx_xhci_core:step({bus, {port, root, 5, get_status}}, 0, S0)),
    ?assertMatch({_, [{bus, {port_done, root, _, {error, badarg}}}]}, erx_xhci_core:step({bus, {port, root, 0, reset}}, 0, S0)),
    {S1, [{read, [usbsts, iman]}]} = erx_xhci_core:step(interrupt, 0, S0),
    {S2, [{write, usbsts, _}, {write, iman, _}, complete]} = erx_xhci_core:step({read, #{usbsts => 0, iman => 2}}, 0, S1),
    ?assertMatch({_, [{bus, {port_event, 4}}, complete]}, erx_xhci_core:step({completed, {ok, [{port, 4}]}}, 0, S2)),
    ?assertMatch({_, [{fail, {malformed_event, {port, 5}}}]},
                 erx_xhci_core:step({completed, {ok, [{port, 5}]}}, 0, S2)),
    ?assertMatch({_, [{fail, {malformed_event, oops}}]}, erx_xhci_core:step({completed, {ok, [oops]}}, 0, S2)).

-define(BYSTANDER, (?PS_PP bor ?PS_PED bor 1 bor ?PS_PRC)).
-define(PORT_HARDWARE, [connect, disconnect, reset_done, warm_reset_done, enable_change, config_error,
                        link_change, over_current]).
-define(PORT_OPS, [get_status, power_on, reset, disable, {clear, connection}, {clear, enabled},
                   {clear, suspend}, {clear, over_current}, {clear, reset}]).

%% The root-port machine explored to a fixed point (xHCI 4.19.2, p. 322; 5.4.8, pp.
%% 405-411): port 2 of a modelled PORTSC, whose hardware may connect, disconnect, end a
%% reset or a warm reset and raise an enable, configuration error, link state or
%% over-current change at any point, under every bus operation in any order. At every
%% write: no change bit is written that the port's last status read did not report, and
%% a clear leaves none of its name's reported bits set. The states the rule is for are
%% reached: a configuration error set behind a reported enable change, and a warm reset
%% change behind a reported reset change.
the_root_port_machine_is_explored_to_a_fixed_point_test() ->
    Seen = explore_port([port_start()], none),
    Behind = fun(Reported, Unreported) ->
                     [N || {_, Word, R} = N <- maps:keys(Seen), R band Reported =/= 0,
                           Word band Unreported band bnot R =/= 0]
             end,
    ?assertNotEqual([], Behind(?PS_PEC, ?PS_CEC)),
    ?assertNotEqual([], Behind(?PS_PRC, ?PS_WRC)).

%% Beside port 2, port 1 holds a reset change reported before the exploration began,
%% which a clear of port 1's reset must clear in every state of port 2, so no state of
%% port 2 is read or cleared as port 1's.
a_port_keeps_its_own_reported_changes_test() ->
    explore_port([port_start()], fun probe_bystander/1).

%% A running controller whose port 1 reported its reset change, and a powered port 2
%% with nothing reported.
port_start() ->
    {S1, [{read, [{portsc, 1}]}]} = erx_xhci_core:step({bus, {port, root, 1, get_status}}, 0, running()),
    {S2, [{bus, {port_done, root, _, {ok, _, _}}}]} = erx_xhci_core:step({read, #{{portsc, 1} => ?BYSTANDER}}, 0, S1),
    {S2, ?PS_PP, 0}.

explore_port(Start, Probe) ->
    explore_port(Start, Probe, maps:from_keys(Start, true)).

explore_port([], _Probe, Seen) ->
    Seen;
explore_port([Node | Rest], Probe, Seen) ->
    Probe =:= none orelse Probe(Node),
    Next = [N || N <- [hardware(H, Node) || H <- ?PORT_HARDWARE] ++ [bus_op(Op, Node) || Op <- ?PORT_OPS],
                 not is_map_key(N, Seen)],
    Unique = lists:usort(Next),
    explore_port(Unique ++ Rest, Probe, maps:merge(Seen, maps:from_keys(Unique, true))).

%% The modelled port's hardware. CCS is bit 0; a disconnect drops the enable; a reset
%% in progress ends enabled; each change bit sets as its event happens.
hardware(connect, {S, Word, Reported}) when Word band 1 =:= 0 -> {S, Word bor 1 bor ?PS_CSC, Reported};
hardware(disconnect, {S, Word, Reported}) when Word band 1 =:= 1 ->
    {S, (Word band bnot (1 bor ?PS_PED bor ?PS_PR)) bor ?PS_CSC, Reported};
hardware(reset_done, {S, Word, Reported}) when Word band ?PS_PR =/= 0 ->
    {S, (Word band bnot ?PS_PR) bor ?PS_PED bor ?PS_PRC, Reported};
hardware(warm_reset_done, {S, Word, Reported}) -> {S, Word bor ?PS_WRC, Reported};
hardware(enable_change, {S, Word, Reported}) -> {S, Word bor ?PS_PEC, Reported};
hardware(config_error, {S, Word, Reported}) -> {S, Word bor ?PS_CEC, Reported};
hardware(link_change, {S, Word, Reported}) -> {S, Word bor ?PS_PLC, Reported};
hardware(over_current, {S, Word, Reported}) -> {S, Word bor ?PS_OCC, Reported};
hardware(_Event, Node) -> Node.

%% One bus operation on port 2, its PORTSC read answered from the model and each write
%% applied as the register takes it: a change bit written 1 clears, the reset bit starts
%% a reset, the enable bit disables, port power is read-write. Reported is what the bus
%% has seen and not cleared, the change bits of the last status read.
bus_op(Op, {S0, Word, Reported}) ->
    {S1, [{read, [{portsc, 2}]}]} = erx_xhci_core:step({bus, {port, root, 2, Op}}, 0, S0),
    {S2, Actions} = erx_xhci_core:step({read, #{{portsc, 2} => Word}}, 0, S1),
    Writes = [W || {write, {portsc, 2}, W} <- Actions],
    [{bus, {port_done, root, _, _}}] = Actions -- [{write, {portsc, 2}, W} || W <- Writes],
    [?assertEqual({Op, Word, Reported, 0}, {Op, Word, Reported, W band ?PS_CHANGES band bnot Reported})
     || W <- Writes],
    After = lists:foldl(fun portsc_write/2, Word, Writes),
    case Op of
        get_status ->
            {S2, After, Word band ?PS_CHANGES};
        {clear, Name} ->
            Behind = name_bits(Name) band Reported,
            ?assertEqual({Op, Word, Reported, 0}, {Op, Word, Reported, After band Behind}),
            {S2, After, Reported band bnot name_bits(Name)};
        _ ->
            {S2, After, Reported}
    end.

name_bits(connection) -> ?PS_CSC;
name_bits(enabled) -> ?PS_PEC bor ?PS_CEC;
name_bits(suspend) -> ?PS_PLC;
name_bits(over_current) -> ?PS_OCC;
name_bits(reset) -> ?PS_PRC bor ?PS_WRC.

portsc_write(W, Word) ->
    Cleared = Word band bnot (W band ?PS_CHANGES),
    Reset = case W band ?PS_PR of 0 -> Cleared; _ -> (Cleared bor ?PS_PR) band bnot ?PS_PED end,
    Disabled = case W band ?PS_PED of 0 -> Reset; _ -> Reset band bnot ?PS_PED end,
    (Disabled band bnot ?PS_PP) bor (W band ?PS_PP).

%% Port 1's reported reset change is still port 1's to clear, whatever port 2 did.
probe_bystander({S, _Word, _Reported}) ->
    {S1, [{read, [{portsc, 1}]}]} = erx_xhci_core:step({bus, {port, root, 1, {clear, reset}}}, 0, S),
    ?assertMatch({_, [{write, {portsc, 1}, W}, {bus, {port_done, root, _, ok}}]} when W band ?PS_CHANGES =:= ?PS_PRC,
                 erx_xhci_core:step({read, #{{portsc, 1} => ?BYSTANDER}}, 0, S1)).

root_ports_answer_from_portsc_test() ->
    S0 = running(),
    %% Connected, enabled, powered, high speed (3), with a connection and a link state change.
    Word = 16#1 bor ?PS_PED bor ?PS_PP bor (3 bsl 10) bor ?PS_CSC bor ?PS_PLC,
    {S1, [{read, [{portsc, 2}]}]} = erx_xhci_core:step({bus, {port, root, 2, get_status}}, 0, S0),
    ?assertMatch({_, [{bus, {port_done, root, _, {ok, <<16#103:16/little, 16#5:16/little>>, 3}}}]},
                 erx_xhci_core:step({read, #{{portsc, 2} => Word}}, 0, S1)),
    %% Suspended: the U3 link state, 3 in PLS.
    ?assertMatch({_, [{bus, {port_done, root, _, {ok, <<16#5:16/little, 0:16>>, 0}}}]},
                 erx_xhci_core:step({read, #{{portsc, 2} => 16#1 bor (3 bsl 5)}}, 0, S1)),
    {S2, [{read, [{portsc, 3}]}]} = erx_xhci_core:step({bus, {port, root, 3, power_on}}, 0, S0),
    ?assertMatch({_, [{write, {portsc, 3}, ?PS_PP}, {bus, {port_done, root, _, ok}}]},
                 erx_xhci_core:step({read, #{{portsc, 3} => ?PS_PED bor ?PS_CSC}}, 0, S2)),
    ?assertMatch({_, [{fail, {unexpected_read, {portsc, 1}}}]},
                 erx_xhci_core:step({read, #{{portsc, 1} => 0}}, 0, S2)).

%% An interrupt: USBSTS and IMAN read; a host system error fails the controller; otherwise
%% the event interrupt (USBSTS bit 3) and the pending bit (IMAN bit 0) are cleared, IMAN's
%% enable (bit 1) kept, and the ring is drained before the line is acknowledged.
an_interrupt_pass_test() ->
    S0 = running(),
    {S1, [{read, [usbsts, iman]}]} = erx_xhci_core:step(interrupt, 0, S0),
    ?assertMatch({_, [{fail, host_system_error}]}, erx_xhci_core:step({read, #{usbsts => 16#5, iman => 3}}, 0, S1)),
    {S2, [{write, usbsts, 16#8}, {write, iman, 16#3}, complete]} =
        erx_xhci_core:step({read, #{usbsts => 16#18, iman => 3}}, 0, S1),
    {S3, [{bus, {port_event, 2}}, complete]} = erx_xhci_core:step({completed, {ok, [{port, 2}]}}, 0, S2),
    ?assertMatch({_, [ack]}, erx_xhci_core:step({completed, {ok, []}}, 0, S3)),
    ?assertMatch({_, [{fail, {unknown_tag, 7}}]}, erx_xhci_core:step({completed, {ok, [{7, ?SUCCESS, <<>>}]}}, 0, S3)),
    ?assertMatch({_, [{fail, {complete, broken}}]}, erx_xhci_core:step({completed, {error, broken}}, 0, S3)),
    %% Outside a pass nothing asked to complete.
    ?assertMatch({_, [{fail, {unexpected, completed}}]},
                 erx_xhci_core:step({completed, {ok, [{port, 2}]}}, 0, S0)).

%% A running controller's USBSTS is read on every interrupt and, with no interrupt, once
%% a second: a host system error (bit 2), a host controller error (bit 12) or a halt
%% (bit 0) fails it, and an all-ones read, a function that left the bus, shows the first.
the_status_of_a_running_controller_is_read_each_second_test() ->
    Stopped = [{16#4, host_system_error}, {16#1000, host_controller_error}, {16#1, host_controller_halted},
               {16#ffffffff, host_system_error}],
    S0 = running(),
    ?assertEqual(1000, erx_xhci_core:next_deadline(S0)),
    ?assertEqual({S0, []}, erx_xhci_core:step(expired, 999, S0)),
    {S1, [{read, [usbsts]}]} = erx_xhci_core:step(expired, 1000, S0),
    ?assertEqual(2000, erx_xhci_core:next_deadline(S1)),
    %% Running, an event interrupt pending: nothing done, the next read a second on.
    {S2, []} = erx_xhci_core:step({read, #{usbsts => 16#8}}, 1000, S1),
    ?assertEqual(2000, erx_xhci_core:next_deadline(S2)),
    [?assertMatch({_, [{fail, Reason}]}, erx_xhci_core:step({read, #{usbsts => Word}}, 1000, S1))
     || {Word, Reason} <- Stopped],
    %% A word that is not one fails the controller rather than reading as running.
    ?assertMatch({_, [{fail, {unexpected_read, [usbsts]}}]}, erx_xhci_core:step({read, #{usbsts => bad}}, 1000, S1)),
    %% A late deadline reads once and sets the next a second from when it came.
    {S3, [{read, [usbsts]}]} = erx_xhci_core:step(expired, 3500, S2),
    ?assertEqual(4500, erx_xhci_core:next_deadline(S3)),
    %% An interrupt's read fails the controller on the same bits.
    {S4, [{read, [usbsts, iman]}]} = erx_xhci_core:step(interrupt, 0, S0),
    [?assertMatch({_, [{fail, Reason}]}, erx_xhci_core:step({read, #{usbsts => Word, iman => 3}}, 0, S4))
     || {Word, Reason} <- Stopped],
    %% Before the controller runs, USBSTS is not read on a deadline.
    ?assertEqual(none, erx_xhci_core:next_deadline(handoff_started())).

%% A pass reads at most 1024 events, two wraps of the 512-entry event ring: batches of
%% 32 port events ask for more until the 32nd, which acknowledges the line.
an_interrupt_pass_is_bounded_test() ->
    {S1, _} = erx_xhci_core:step(interrupt, 0, running()),
    {S2, _} = erx_xhci_core:step({read, #{usbsts => 16#8, iman => 3}}, 0, S1),
    Batch = {completed, {ok, lists:duplicate(32, {port, 1})}},
    S33 = lists:foldl(fun(_, S) ->
                              {Sn, Actions} = erx_xhci_core:step(Batch, 0, S),
                              ?assertEqual(complete, lists:last(Actions)),
                              Sn
                      end, S2, lists:seq(1, 31)),
    {S34, Last} = erx_xhci_core:step(Batch, 0, S33),
    ?assertEqual(ack, lists:last(Last)),
    %% The next interrupt begins a new pass.
    ?assertMatch({_, [{read, [usbsts, iman]}]}, erx_xhci_core:step(interrupt, 0, S34)).

%% A level-triggered line, the Pi 4's INTx (docs/design-usb.md, "Interrupts" and "Events"),
%% explored to a fixed point: the line is asserted while IMAN.IP is set (xHCI 4.17.2, p.
%% 296), each event the controller writes to the ring sets IP and USBSTS.EINT (interrupt
%% moderation and IMAN.IE left out, and ERDP's event handler busy bit too, so IP is set
%% more often than a controller sets it), and the platform's interrupt controller delivers
%% an asserted line only while it is unmasked, masking it until the core's ack. The
%% process's order is kept (erx_xhci's moduledoc): a step's actions are performed in order and their answers
%% stepped before the answers still waiting, and an interrupt is taken only when nothing is
%% left to perform or step. The controller writes an event at any point between two
%% actions, ?LEVEL_EVENTS of them in all. At every interrupt no more interrupts have been
%% taken than events written, or the line storms; and once nothing is left to do and no
%% event is still to come, the ring is empty and the line unmasked, or an event is lost.
%% Its passes stay under xhci_events_per_interrupt, whose bound
%% an_interrupt_pass_is_bounded_test covers.
-define(LEVEL_EVENTS, 3).

a_level_line_neither_storms_nor_loses_an_event_test() ->
    Start = #{core => running(), ip => 0, ring => 0, masked => false, todo => [], answers => [], queue => [],
              left => ?LEVEL_EVENTS, made => 0, taken => 0},
    Seen = level_explore([Start], #{}),
    ?assert(lists:any(fun(#{taken := Taken}) -> Taken =:= ?LEVEL_EVENTS end, maps:keys(Seen))).

level_explore([], Seen) ->
    Seen;
level_explore([M | More], Seen) when is_map_key(M, Seen) ->
    level_explore(More, Seen);
level_explore([M | More], Seen) ->
    level_explore(level_next(M) ++ More, Seen#{M => true}).

%% The model's next states: an event written, while one is still to come, and the
%% process's own next move.
level_next(M = #{left := Left, ring := Ring, made := Made}) ->
    [M#{ring := Ring + 1, ip := 1, left := Left - 1, made := Made + 1} || Left > 0] ++ level_move(M).

level_move(M = #{todo := [Action | Rest], answers := Answers}) ->
    {Next, Answer} = level_perform(Action, M#{todo := Rest}),
    [Next#{answers := Answers ++ Answer}];
level_move(M = #{todo := [], answers := Answers, queue := Queue}) when Answers =/= []; Queue =/= [] ->
    [Event | Rest] = Answers ++ Queue,
    [level_step(Event, M#{answers := [], queue := Rest})];
level_move(M = #{ip := 1, masked := false, made := Made, taken := Taken}) ->
    Taken < Made orelse error({line_storm, M}),
    [level_step(interrupt, M#{masked := true, taken := Taken + 1})];
level_move(#{left := 0, ring := 0, masked := false}) ->
    [];
level_move(M = #{left := 0}) ->
    error({event_lost_or_line_masked, M});
level_move(_M) ->
    [].

level_step(Event, M = #{core := Core}) ->
    {Next, Actions} = erx_xhci_core:step(Event, 0, Core),
    M#{core := Next, todo := Actions}.

%% Performs Action against the controller and its line, with the answers it gives.
level_perform({read, [usbsts, iman]}, M = #{ip := Ip}) ->
    {M, [{read, #{usbsts => Ip * 16#8, iman => 16#2 bor Ip}}]};
level_perform({write, iman, Word}, M) when Word band 16#1 =:= 16#1 ->
    {M#{ip := 0}, []};
level_perform({write, _Register, _Word}, M) ->
    {M, []};
level_perform(complete, M = #{ring := Ring}) ->
    {M#{ring := 0}, [{completed, {ok, lists:duplicate(Ring, {port, 1})}}]};
level_perform(ack, M) ->
    {M#{masked := false}, []};
level_perform({bus, _Answer}, M) ->
    {M, []};
level_perform(Action, M) ->
    error({unexpected_action, Action, M}).

%% An interrupt before the controller runs is held: no ack until the bus starts, or the
%% controller fails, and then exactly one.
an_interrupt_before_running_is_held_test() ->
    {S1, []} = erx_xhci_core:step(interrupt, 0, handoff_started()),
    ?assertEqual({S1, []}, erx_xhci_core:step(interrupt, 0, S1)),
    {S2, [negotiate]} = erx_xhci_core:step({read, #{{legacy, bios_owned} => 0}}, 0, S1),
    {S3, [{bus, {root_ports, 4}}, ack]} = erx_xhci_core:step({negotiated, ok}, 0, S2),
    ?assertMatch({_, [{read, [usbsts, iman]}]}, erx_xhci_core:step(interrupt, 0, S3)),
    ?assertMatch({_, [{fail, {install, eio}}]}, erx_xhci_core:step({negotiated, {error, eio}}, 0, S2)).

%% The start explored: from {start, Bound} with and without a legacy capability, every
%% answer the environment may give in every reachable state (the BIOS's byte owned or
%% released at each read; the install ok, ebusy or failed at each call; an interrupt at
%% any time from the capabilities read on), the clock moving only to next_deadline/1.
%% Checked at each step: the install
%% is called only once the BIOS released the controller or 5 s passed; the bus starts
%% only on the install's ok; an install still busy 3 s after its first call fails;
%% expired a millisecond before the deadline changes nothing; an interrupt before the
%% controller runs is held, not acknowledged, and its one ack goes out with the bus's
%% start, never with a failure; a run that has not ended always has a next step,
%% an answer it awaits or a deadline. Each world ends running or failed.
the_start_is_explored_to_a_fixed_point_test_() ->
    {timeout, 300, fun() ->
        [begin
             {S1, _} = erx_xhci_core:step({start, Bound}, 0, new(attached)),
             {S2, Actions} = erx_xhci_core:step({read, capability_words()}, 0, S1),
             W = #{legacy => maps:get(legacy, Bound), released => false, installing => none, awaits => none,
                   last => none, held => false},
             {Ends, _} = explore_start([{S2, Actions, 0, W}], #{}, #{}),
             ?assertEqual(lists:sort(maps:keys(Ends)), [failed, running])
         end || Bound <- [?BOUND, #{legacy => false, protocols => 2}]]
    end}.

explore_start([], Seen, Ends) -> {Ends, Seen};
explore_start([{S, Actions, Now, W} | Rest], Seen, Ends) ->
    case check_start(Actions, Now, W) of
        {ended, How} ->
            explore_start(Rest, Seen, Ends#{How => true});
        W1 when is_map_key({S, Now, W1}, Seen) ->
            explore_start(Rest, Seen, Ends);
        W1 ->
            Next = [{S2, A2, At, answered(Event, W1)}
                    || {Event, At} <- start_events(S, Now, W1), {S2, A2} <- [erx_xhci_core:step(Event, At, S)]],
            explore_start(Next ++ Rest, Seen#{{S, Now, W1} => true}, Ends)
    end.

%% The answers the environment may give to what the core last asked, the clock moved to
%% the next deadline, where expired a millisecond earlier must change nothing, and an
%% interrupt. A run with neither an answer awaited nor a deadline, or with a deadline
%% that does nothing when it comes, has stalled.
start_events(S, Now, W = #{awaits := Awaits}) ->
    Expired = case erx_xhci_core:next_deadline(S) of
                  none -> [];
                  At ->
                      ?assertEqual({S, []}, erx_xhci_core:step(expired, At - 1, S)),
                      ?assertNotEqual({S, []}, erx_xhci_core:step(expired, At, S)),
                      [{expired, At}]
              end,
    Answers = case Awaits of
                  bios -> [{read, #{{legacy, bios_owned} => B}} || B <- [0, 1]];
                  install -> [{negotiated, R} || R <- [ok, {error, ebusy}, {error, eio}]];
                  none -> []
              end,
    Expired =/= [] orelse Answers =/= [] orelse error({stalled, Now, W}),
    [{interrupt, Now} | Expired ++ [{Answer, Now} || Answer <- Answers]].

%% An interrupt leaves what the core awaits; an answer or a deadline ends the wait.
answered(interrupt, W) -> W#{held := true};
answered(Event = {read, #{{legacy, bios_owned} := 0}}, W) -> W#{released := true, last := Event, awaits := none};
answered(Event, W) -> W#{last := Event, awaits := none}.

check_start([], _Now, W) -> W;
check_start([{write, {legacy, os_owned}, 1} | Rest], Now, W) -> check_start(Rest, Now, W);
check_start([{read, [{legacy, bios_owned}]} | Rest], Now, W) -> check_start(Rest, Now, W#{awaits := bios});
check_start([{log, bios_handoff_timeout} | Rest], Now, W) ->
    ?assert(Now >= 5000),
    check_start(Rest, Now, W#{released := true});
check_start([negotiate | Rest], Now, W = #{legacy := Legacy, released := Released, installing := none}) ->
    ?assert(Released orelse not Legacy),
    check_start(Rest, Now, W#{awaits := install, installing := Now});
check_start([{negotiate, continue} | Rest], Now, W = #{installing := Since}) when Since =/= none ->
    check_start(Rest, Now, W#{awaits := install});
check_start(Actions = [{bus, {root_ports, 4}} | _], _Now, #{last := {negotiated, ok}, held := Held}) ->
    ?assertEqual([{bus, {root_ports, 4}} | [ack || Held]], Actions),
    {ended, running};
check_start([{fail, install_timeout}], Now, #{installing := Since}) ->
    ?assert(Now >= Since + 3000),
    {ended, failed};
check_start([{fail, {install, eio}}], _Now, _W) -> {ended, failed}.
