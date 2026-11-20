%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_xhci_core (docs/design-usb.md, "The controller process"): the pipe
%% machine and reset_pipe's table, explored to a fixed point against a model of the NIF's
%% queue states; traces of each row of the table and of EP0's reset after a stall; the
%% bus commands, one at a time; and the decoders. Every number is written out here, so a
%% code or request value changed in abi/formats/xhci.txt or usb.txt fails a case instead
%% of moving with the module.
-module(erx_xhci_core_tests).

-include_lib("eunit/include/eunit.hrl").

-export([explore/1]).

-define(SUCCESS, 1).
-define(TRANSACTION_ERROR, 4).
-define(TRB_ERROR, 5).
-define(STALL, 6).
-define(CONTEXT_STATE_ERROR, 19).
-define(STOPPED, 26).

-define(HUB, 1).
-define(DEV, 2).
-define(HUB_EP0, {?HUB, 1}).
-define(DEV_EP0, {?DEV, 1}).
%% Bulk IN endpoint 2: device context index 2 * 2 + 1.
-define(BULK, {?DEV, 5}).
-define(BULK_ADDRESS, 16#82).
-define(HUB_ADDRESS, 5).
-define(DEV_ADDRESS, 6).

-define(GET_STATUS, <<16#80, 0, 0:16, 0:16, 2:16/little>>).

%% The devices the cases address: a full-speed device behind the hub's single
%% translator at port 2, a low-speed one behind a multi-TT hub's port 3, and a
%% high-speed one with no translator.
devices() ->
    [#{speed => full, tt => #{hub_slot => ?HUB, port => 2, multi => false}},
     #{speed => low, tt => #{hub_slot => ?HUB, port => 3, multi => true}},
     #{speed => high, tt => none}].

%% Explored from a hub and a device with one bulk-IN endpoint, for each device, over
%% every event the model allows: a caller's post on each pipe and reset_pipe on the
%% device's, at most one of each outstanding, with the queue state the model's NIF
%% reports; each answer a posted transfer can get (success, STALL, transaction error)
%% while its queue runs; and each answer the command in flight can get (success, a TRB
%% error, a context state error for a stop that finds the queue halted). At every state
%% the model checks that each command is one the NIF accepts in its queue's state (so a
%% Reset Endpoint on a stopped queue or a drop of EP0 fails), that at most one command
%% and one EP0 request are in flight, that each caller is answered once, that a reset
%% answered ok left the queue open with both toggles reset and, after a halt behind a
%% translator, the translator's buffer cleared; and that from every state the callers
%% are all answered when every later answer succeeds.
the_pipe_machine_is_explored_to_a_fixed_point_test_() ->
    {timeout, 600, [?_assertMatch({ok, _}, explore(Device)) || Device <- devices()]}.

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
%% configured, with the slot's hub fields.
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
                 step({complete, T3, ?SUCCESS, none}, S3)).

%% A failed step halts the pipe and answers the step's error; the pipe then refuses
%% posts until another reset succeeds.
a_failed_step_halts_the_pipe_test() ->
    {S0, _} = addressed(lists:last(devices())),
    {S1, [{command, T1, {reset_endpoint, ?DEV, 5}}]} = step({reset_pipe, me, ?BULK, halted}, S0),
    {S2, [{reply, me, {error, trb_error}}]} = step({complete, T1, ?TRB_ERROR, none}, S1),
    ?assertMatch({_, [{reply, you, {error, halted}}]}, step({post, you, ?BULK, {normal, {in, 64}}}, S2)),
    ?assertMatch({_, [{command, _, {reset_endpoint, ?DEV, 5}}]}, step({reset_pipe, me, ?BULK, halted}, S2)).

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

%% Bus commands run one at a time, and each success records what it adds; a refused
%% transfer is answered with the NIF's reason.
bus_commands_run_one_at_a_time_test() ->
    S0 = erx_xhci_core:new(),
    {S1, [{command, T1, enable_slot}]} = step({command, bus, enable_slot}, S0),
    {S2, []} = step({command, bus, {address_device, ?DEV, lists:last(devices())}}, S1),
    {S3, [{reply, bus, {ok, ?DEV}}, {command, T2, {address_device, ?DEV, _}}]} =
        step({complete, T1, ?SUCCESS, ?DEV}, S2),
    ?assertMatch({_, [{reply, me, {error, gone}}]}, step({post, me, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S3)),
    {S4, [{reply, bus, {ok, 9}}]} = step({complete, T2, ?SUCCESS, 9}, S3),
    {S5, [{transfer, ?DEV_EP0, T3, _}]} = step({post, me, ?DEV_EP0, {control, ?GET_STATUS, {in, 2}}}, S4),
    ?assertMatch({_, [{reply, me, {error, full}}]}, step({refused, T3, full}, S5)),
    ?assertMatch({_, [{reply, bus, {error, {address, transaction_error}}}]},
                 step({complete, T2, ?TRANSACTION_ERROR, 0}, S3)).

%% The controller fails on an answer it cannot trust or a command it never gets.
the_controller_fails_on_a_malformed_answer_or_a_lost_command_test() ->
    S0 = erx_xhci_core:new(),
    {S1, [{command, T1, enable_slot}]} = erx_xhci_core:step({command, bus, enable_slot}, 1000, S0),
    ?assertMatch({_, [{fail, {malformed_answer, enable_slot}}]}, step({complete, T1, ?SUCCESS, 0}, S1)),
    ?assertMatch({_, [{fail, {malformed_answer, enable_slot}}]}, step({complete, T1, ?SUCCESS, 17}, S1)),
    ?assertMatch({_, [{fail, {unknown_tag, 99}}]}, step({complete, 99, ?SUCCESS, <<>>}, S1)),
    {S2, []} = step({command, bus, enable_slot}, S1),
    ?assertMatch({_, [{fail, {malformed_answer, enable_slot}}]}, step({complete, T1, ?SUCCESS, 0}, S2)),
    ?assertEqual(6000, erx_xhci_core:next_deadline(S1)),
    ?assertEqual({S1, []}, erx_xhci_core:step(expired, 5999, S1)),
    ?assertMatch({_, [{fail, {command_timeout, enable_slot}}]}, erx_xhci_core:step(expired, 6000, S1)),
    ?assertEqual(none, erx_xhci_core:next_deadline(S0)).

completion_codes_are_named_from_the_abi_test() ->
    ?assertEqual(success, erx_xhci_core:completion(1)),
    ?assertEqual(stall, erx_xhci_core:completion(6)),
    ?assertEqual(context_state_error, erx_xhci_core:completion(19)),
    ?assertEqual(stopped_short_packet, erx_xhci_core:completion(28)),
    ?assertEqual({unknown, 30}, erx_xhci_core:completion(30)),
    ?assertEqual({unknown, 255}, erx_xhci_core:completion(255)),
    ?assertEqual({unknown, -1}, erx_xhci_core:completion(-1)).

command_answers_are_bounded_test() ->
    A = fun erx_xhci_core:command_answer/3,
    ?assertEqual({ok, 1}, A(enable_slot, 1, 1)),
    ?assertEqual({ok, 16}, A(enable_slot, 1, 16)),
    [?assertEqual(malformed, A(enable_slot, 1, Bad)) || Bad <- [0, 17, -1, 255, none, <<1>>]],
    ?assertEqual({error, no_slots}, A(enable_slot, 9, 0)),
    ?assertEqual({ok, 127}, A(address_device, 1, 127)),
    [?assertEqual(malformed, A(address_device, 1, Bad)) || Bad <- [0, 128, 255, none]],
    ?assertEqual({error, {address, transaction_error}}, A(address_device, 4, 0)),
    ?assertEqual({error, {address, {unknown, 200}}}, A(address_device, 200, 0)),
    ?assertEqual(ok, A(stop_endpoint, 1, none)),
    ?assertEqual({error, context_state_error}, A(stop_endpoint, 19, none)),
    ?assertEqual(malformed, A(stop_endpoint, none, none)).

transfer_results_name_the_caller_answer_test() ->
    R = fun erx_xhci_core:transfer_result/2,
    ?assertEqual({ok, <<1, 2>>}, R(1, <<1, 2>>)),
    ?assertEqual({ok, <<1>>}, R(13, <<1>>)),
    ?assertEqual({error, stall}, R(6, <<>>)),
    [?assertEqual({error, stopped}, R(Code, <<>>)) || Code <- [26, 27, 28]],
    ?assertEqual({error, {controller, babble}}, R(3, <<>>)),
    ?assertEqual({error, {controller, {unknown, 99}}}, R(99, <<>>)),
    ?assertEqual(malformed, R(1, none)),
    ?assertEqual(malformed, R(x, <<>>)).

%% Helpers

step(Event, State) -> erx_xhci_core:step(Event, 0, State).

setup(Type, Request, Value, Index) -> <<Type, Request, Value:16/little, Index:16/little, 0:16>>.

%% The core with the hub at slot 1 and Device at slot 2, its bulk-IN endpoint
%% configured; and the device.
addressed(Device) ->
    Hub = #{speed => high, tt => none},
    Commands = [{{address_device, ?HUB, Hub}, ?HUB_ADDRESS},
                {{configure_endpoints, ?HUB, #{add => [], drop => [], hub => #{ports => 4}}}, none},
                {{address_device, ?DEV, Device}, ?DEV_ADDRESS},
                {{configure_endpoints, ?DEV, #{add => [#{address => ?BULK_ADDRESS, type => bulk, packet_size => 512}],
                                               drop => [], hub => none}}, none}],
    State = lists:foldl(fun({Command, Extra}, S) ->
                                {S1, [{command, Tag, Command}]} = step({command, bus, Command}, S),
                                {S2, [{reply, bus, _}]} = step({complete, Tag, ?SUCCESS, Extra}, S1),
                                S2
                        end,
                        erx_xhci_core:new(), Commands),
    {State, Device}.

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

%% The exploration

%% The model beside the core: each queue's state as the NIF keeps it (open, stopping,
%% stopped, halted), the transfers posted on each, the command in flight, the callers
%% not yet answered, and for each pipe a caller is resetting, what the reset has done.
explore(Device) ->
    {Core, _} = addressed(Device),
    M0 = #{core => Core, device => Device,
           queues => #{?HUB_EP0 => open, ?DEV_EP0 => open, ?BULK => open},
           posted => #{}, command => none, callers => #{}, done => #{}},
    explore([M0], #{M0 => true}).

explore([], Seen) ->
    {ok, map_size(Seen)};
explore([M | Rest], Seen) ->
    Next = [follow(Event, M) || Event <- events(M)],
    case [Why || {error, Why} <- Next] ++ drained(M) of
        [] ->
            New = lists:usort([N || {ok, N} <- Next, not is_map_key(N, Seen)]),
            explore(New ++ Rest, maps:merge(Seen, maps:from_keys(New, true)));
        [Why | _] ->
            {error, Why}
    end.

%% The events the model allows in M.
events(M = #{posted := Posted, command := Command, callers := Callers, queues := Queues}) ->
    Posts = [{caller_post, P} || P <- [?HUB_EP0, ?DEV_EP0, ?BULK], not is_map_key({post, P}, Callers)],
    Resets = [{caller_reset, P} || P <- [?DEV_EP0, ?BULK], not is_map_key({reset, P}, Callers)],
    Transfers = [{transfer_answer, Tag, Code} || {Tag, {P, _}} <- maps:to_list(Posted),
                                                 running(maps:get(P, Queues)),
                                                 Code <- [?SUCCESS, ?STALL, ?TRANSACTION_ERROR]],
    Posts ++ Resets ++ Transfers ++ command_answers(Command, M).

running(Queue) -> Queue =:= open orelse Queue =:= stopping.

command_answers(none, _M) ->
    [];
command_answers({_Tag, {stop_endpoint, Slot, Dci}}, #{queues := Queues}) ->
    case maps:get({Slot, Dci}, Queues) of
        halted -> [{command_answer, ?CONTEXT_STATE_ERROR}];
        stopping -> [{command_answer, ?SUCCESS}, {command_answer, ?TRB_ERROR}]
    end;
command_answers({_Tag, _Command}, _M) ->
    [{command_answer, ?SUCCESS}, {command_answer, ?TRB_ERROR}].

follow(Event, M) ->
    try {ok, apply_event(Event, M)}
    catch throw:Why -> {error, {Event, Why}}
    end.

apply_event({caller_post, Pipe}, M = #{callers := Callers}) ->
    Transfer = case Pipe of
                   ?BULK -> {normal, {in, 64}};
                   _ -> {control, ?GET_STATUS, {in, 2}}
               end,
    run({post, {post, Pipe}, Pipe, Transfer}, M#{callers := Callers#{{post, Pipe} => true}});
apply_event({caller_reset, Pipe}, M = #{callers := Callers, done := Done, queues := Queues, posted := Posted}) ->
    Report = case maps:get(Pipe, Queues) of
                 halted -> halted;
                 stopped -> stopped;
                 _Running -> case [T || T := {P, _} <- Posted, P =:= Pipe] of [] -> idle; _ -> busy end
             end,
    Facts = [halted || Report =:= halted],
    run({reset_pipe, {reset, Pipe}, Pipe, Report},
        M#{callers := Callers#{{reset, Pipe} => true}, done := Done#{Pipe => Facts}});
apply_event({transfer_answer, Tag, Code}, M = #{posted := Posted, queues := Queues}) ->
    #{Tag := {Pipe, Purpose}} = Posted,
    M1 = M#{posted := maps:remove(Tag, Posted)},
    M2 = case Code of
             ?SUCCESS -> record(Purpose, M1);
             _Halts -> halt_queue(Pipe, M1#{queues := Queues#{Pipe := halted}})
         end,
    run({complete, Tag, Code, <<>>}, M2);
apply_event({command_answer, Code}, M = #{command := {Tag, Command}}) ->
    {M1, Stopped} = command_done(Command, Code, M#{command := none}),
    M2 = lists:foldl(fun(T, Acc) -> run({complete, T, ?STOPPED, <<>>}, Acc) end, M1, Stopped),
    run({complete, Tag, Code, none}, M2).

%% A queue that halts records the halt for a reset in progress on it.
halt_queue(Pipe, M = #{done := Done}) ->
    case Done of
        #{Pipe := Facts} -> M#{done := Done#{Pipe := lists:usort([halted | Facts])}};
        #{} -> M
    end.

record(none, M) -> M;
record({Fact, Pipe}, M = #{done := Done}) ->
    case Done of
        #{Pipe := Facts} -> M#{done := Done#{Pipe := lists:usort([Fact | Facts])}};
        #{} -> M
    end.

%% The NIF's state changes on a command's answer, and the transfers a successful restart
%% of the ring answers `stopped`.
command_done({stop_endpoint, Slot, Dci}, Code, M = #{queues := Queues}) ->
    Pipe = {Slot, Dci},
    case {maps:get(Pipe, Queues), Code} of
        {halted, ?CONTEXT_STATE_ERROR} -> {M, []};
        {stopping, ?SUCCESS} -> {M#{queues := Queues#{Pipe := stopped}}, []};
        {stopping, _Failed} -> {M#{queues := Queues#{Pipe := open}}, []}
    end;
command_done({reset_endpoint, Slot, Dci}, ?SUCCESS, M = #{queues := Queues}) ->
    {record({host_toggle, {Slot, Dci}}, M#{queues := Queues#{{Slot, Dci} := stopped}}), []};
command_done({set_tr_dequeue, Slot, Dci}, ?SUCCESS, M) ->
    restarted({Slot, Dci}, M);
command_done({configure_endpoints, Slot, #{drop := [Dci]}}, ?SUCCESS, M) ->
    restarted({Slot, Dci}, record({host_toggle, {Slot, Dci}}, M));
command_done(_Command, _Failed, M) ->
    {M, []}.

restarted(Pipe, M = #{queues := Queues, posted := Posted}) ->
    Stopped = lists:sort([T || T := {P, _} <- Posted, P =:= Pipe]),
    {M#{queues := Queues#{Pipe := open}, posted := maps:without(Stopped, Posted)}, Stopped}.

%% Runs one event through the core and applies its actions to the model; a transfer the
%% model's NIF refuses is fed back as refused.
run(Event, M = #{core := Core}) ->
    {Core1, Actions} = erx_xhci_core:step(Event, 0, Core),
    {M1, Refused} = lists:foldl(fun act/2, {M#{core := Core1}, []}, Actions),
    lists:foldl(fun(Tag, Acc) -> run({refused, Tag, halted}, Acc) end, M1, lists:reverse(Refused)).

act({command, _Tag, _Command}, {#{command := {_, _}}, _}) ->
    throw(two_commands_in_flight);
act({command, Tag, Command}, {M, Refused}) ->
    {accept_command(Command, M#{command := {Tag, Command}}), Refused};
act({transfer, Pipe, Tag, Transfer}, {M = #{queues := Queues, posted := Posted}, Refused}) ->
    Ep0Busy = element(2, Pipe) =:= 1 andalso [T || T := {P, _} <- Posted, P =:= Pipe] =/= [],
    case maps:get(Pipe, Queues) of
        _ when Ep0Busy -> throw({two_requests_on, Pipe});
        open -> {M#{posted := Posted#{Tag => {Pipe, purpose(Pipe, Transfer, M)}}}, Refused};
        _NotOpen -> {M, [Tag | Refused]}
    end;
act({reply, From, Answer}, {M = #{callers := Callers}, Refused}) ->
    case Callers of
        #{From := _} -> {answered(From, Answer, M#{callers := maps:remove(From, Callers)}), Refused};
        #{} -> throw({answered_twice, From, Answer})
    end;
act({fail, Reason}, _Acc) ->
    throw({failed, Reason}).

%% The commands the NIF accepts in each queue state (design-usb.md, "Queues and their
%% states"), and the state a stop moves its queue to.
accept_command(Command = {stop_endpoint, Slot, Dci}, M = #{queues := Queues}) ->
    case maps:get({Slot, Dci}, Queues) of
        open -> M#{queues := Queues#{{Slot, Dci} := stopping}};
        Other -> throw({refused_by_nif, Command, Other})
    end;
accept_command(Command = {reset_endpoint, Slot, Dci}, M) ->
    accept_in([halted], {Slot, Dci}, Command, M);
accept_command(Command = {set_tr_dequeue, Slot, Dci}, M) ->
    accept_in([stopped], {Slot, Dci}, Command, M);
accept_command(Command = {configure_endpoints, _Slot, #{drop := [1]}}, _M) ->
    throw({refused_by_nif, Command, ep0_dropped});
accept_command(Command = {configure_endpoints, Slot, #{drop := [Dci], add := [_]}}, M = #{posted := Posted}) ->
    Pipe = {Slot, Dci},
    case [T || T := {P, _} <- Posted, P =:= Pipe] of
        [] -> accept_in([stopped, open], Pipe, Command, M);
        _ -> accept_in([stopped], Pipe, Command, M)
    end.

accept_in(States, Pipe, Command, M = #{queues := Queues}) ->
    case lists:member(maps:get(Pipe, Queues), States) of
        true -> M;
        false -> throw({refused_by_nif, Command, maps:get(Pipe, Queues)})
    end.

%% What a request the core posts is for: a caller's own transfer, the device's side of
%% a pipe's reset, or the translator's buffer for a pipe; a CLEAR_TT_BUFFER is checked
%% against the device and the endpoint it names.
purpose(_Pipe, {control, <<16#02, 1, 0:16, EpAddress:16/little, 0:16>>, none}, _M) ->
    {device_toggle, {?DEV, endpoint_dci(EpAddress)}};
purpose(?HUB_EP0, {control, <<16#23, 8, Value:16/little, Index:16/little, 0:16>>, none}, #{device := Device}) ->
    #{tt := #{port := Port, multi := Multi}} = Device,
    EpAddress = (Value band 16#f) bor ((Value bsr 8) band 16#80),
    %% USB 2.0, Table 11-18: the endpoint type is bits 12..11.
    Type = case (Value bsr 11) band 3 of 0 -> control; 2 -> bulk end,
    Expected = case Multi of true -> Port; false -> 1 end,
    case {(Value bsr 4) band 16#7f, Index, {endpoint_dci(EpAddress), Type}} of
        {?DEV_ADDRESS, Expected, {1, control}} -> {tt_cleared, ?DEV_EP0};
        {?DEV_ADDRESS, Expected, {5, bulk}} -> {tt_cleared, ?BULK};
        Wrong -> throw({wrong_tt_clear, Wrong})
    end;
purpose(_Pipe, _Transfer, _M) ->
    none.

endpoint_dci(0) -> 1;
endpoint_dci(EpAddress) -> 2 * (EpAddress band 16#f) + (EpAddress bsr 7).

%% A reset answered ok left the queue open; a bulk pipe's reset reset both toggles; and
%% one that met a halt cleared the translator's buffer for an endpoint behind one.
answered({reset, Pipe}, ok, M = #{queues := Queues, done := Done, device := Device}) ->
    Facts = maps:get(Pipe, Done),
    Needed = [host_toggle || Pipe =:= ?BULK] ++ [device_toggle || Pipe =:= ?BULK]
        ++ [tt_cleared || Pipe =/= ?HUB_EP0, lists:member(halted, Facts), maps:get(tt, Device) =/= none,
                          maps:get(speed, Device) =/= high],
    case {maps:get(Pipe, Queues), Needed -- Facts} of
        {open, []} -> M#{done := maps:remove(Pipe, Done)};
        Wrong -> throw({reset_answered_ok, Pipe, Wrong})
    end;
answered({reset, Pipe}, _Failed, M = #{done := Done}) ->
    M#{done := maps:remove(Pipe, Done)};
answered({post, _Pipe}, _Answer, M) ->
    M.

%% From M, with every later answer a success, every caller is answered within 60
%% events. A transfer still posted on a ring that does not run, a caller's or a reset's
%% request, waits for the pipe's next reset, which a caller's failure brings in the
%% system (the bus detaches a device whose control pipe fails), so the drain resets each
%% pipe that holds one, or holds a caller's post, and has no caller's reset outstanding.
drained(M) -> drained(M, 60).

drained(#{callers := Callers}, _Budget) when map_size(Callers) =:= 0 ->
    [];
drained(M, 0) ->
    [{callers_never_answered, maps:keys(maps:get(callers, M))}];
drained(M = #{callers := Callers, posted := Posted, queues := Queues}, Budget) ->
    Successes = [E || E = {transfer_answer, _, ?SUCCESS} <- events(M)]
        ++ [E || E = {command_answer, Code} <- events(M), Code =/= ?TRB_ERROR],
    Holding = [P || {post, P} <- maps:keys(Callers)]
        ++ [P || {P, _} <- maps:values(Posted), not running(maps:get(P, Queues))],
    Resets = [{caller_reset, P} || P <- lists:usort(Holding), not is_map_key({reset, P}, Callers)],
    case Successes ++ Resets of
        [] -> [{callers_never_answered, maps:keys(Callers)}];
        [Event | _] ->
            case follow(Event, M) of
                {ok, Next} -> drained(Next, Budget - 1);
                {error, Why} -> [Why]
            end
    end.

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

%% A controller started to its BIOS handoff at time 0, the core's first actions checked.
handoff_started() ->
    Regs = [hcsparams1, hcsparams2, hccparams1, pagesize,
            {protocol, 1, revision}, {protocol, 1, ports}, {protocol, 2, revision}, {protocol, 2, ports}],
    {S1, [{read, Regs}]} = erx_xhci_core:step({start, ?BOUND}, 0, erx_xhci_core:new()),
    {S2, [{write, {legacy, os_owned}, 1}, {read, [{legacy, bios_owned}]}]} =
        erx_xhci_core:step({read, capability_words()}, 0, S1),
    S2.

%% A running controller of capability_words(), its bus started.
running() ->
    {S1, [negotiate]} = erx_xhci_core:step({read, #{{legacy, bios_owned} => 0}}, 0, handoff_started()),
    {S2, [{start_bus, 4}]} = erx_xhci_core:step({negotiated, ok}, 0, S1),
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
    {S5, [negotiate]} = erx_xhci_core:step(expired, 22, S4),
    ?assertMatch({_, [{start_bus, 4}]}, erx_xhci_core:step({negotiated, ok}, 23, S5)),
    ?assertMatch({_, [{fail, {install, eio}}]}, erx_xhci_core:step({negotiated, {error, eio}}, 23, S5)),
    %% Without a legacy support capability the install follows the capabilities.
    {N1, _} = erx_xhci_core:step({start, #{legacy => false, protocols => 0}}, 0, erx_xhci_core:new()),
    ?assertMatch({_, [negotiate]},
                 erx_xhci_core:step({read, maps:with([hcsparams1, hcsparams2, hccparams1, pagesize],
                                                     capability_words())}, 0, N1)).

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
                               {Sc, [negotiate]} = erx_xhci_core:step(expired, At + 10, Sb),
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
    ?assertMatch({_, [{reply, bus, {error, halted}}]}, erx_xhci_core:step({port, bus, 1, get_status}, 0, S1)).

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
         {[Written], ok} = erx_xhci_core:port_operation(Op, Word),
         ?assertEqual({Op, Word, Set band ?PS_CHANGES}, {Op, Word, Written band ?PS_CHANGES}),
         ?assertEqual({Op, Word, Set band ?PS_PED}, {Op, Word, Written band ?PS_PED}),
         ?assertEqual({Op, Word, Set band ?PS_PR}, {Op, Word, Written band ?PS_PR}),
         ?assertEqual({Op, Word, (Word band ?PS_KEPT) bor (Set band ?PS_PP)}, {Op, Word, Written band ?PS_KEPT}),
         ?assertEqual({Op, Word, 0}, {Op, Word, Written band (?PS_LWS bor ?PS_WPR)})
     end || Word <- Words, {Op, Set} <- Ops],
    ?assertEqual({[], {error, badarg}}, erx_xhci_core:port_operation({clear, test}, 0)).

%% xHCI 4.19.2 (p. 322): a root port raises no further event until every change bit is
%% clear, so each one shows in wPortChange and the clear of the name it shows as clears it.
every_change_bit_can_be_cleared_test() ->
    Names = [{1, connection}, {2, enabled}, {4, suspend}, {8, over_current}, {16, reset}],
    [begin
         {[], {ok, <<0:16, Change:16/little>>, 0}} = erx_xhci_core:port_operation(get_status, Bit),
         {Change, Name} = lists:keyfind(Change, 1, Names),
         {[Written], ok} = erx_xhci_core:port_operation({clear, Name}, Bit),
         ?assertEqual({Bit, Bit}, {Bit, Written band Bit})
     end || Bit <- [?PS_CSC, ?PS_PEC, ?PS_WRC, ?PS_OCC, ?PS_PRC, ?PS_PLC, ?PS_CEC]].

root_ports_answer_from_portsc_test() ->
    S0 = running(),
    %% Connected, enabled, powered, high speed (3), with a connection and a link state change.
    Word = 16#1 bor ?PS_PED bor ?PS_PP bor (3 bsl 10) bor ?PS_CSC bor ?PS_PLC,
    {S1, [{read, [{portsc, 2}]}]} = erx_xhci_core:step({port, bus, 2, get_status}, 0, S0),
    ?assertMatch({_, [{reply, bus, {ok, <<16#103:16/little, 16#5:16/little>>, 3}}]},
                 erx_xhci_core:step({read, #{{portsc, 2} => Word}}, 0, S1)),
    %% Suspended: the U3 link state, 3 in PLS.
    ?assertMatch({_, [{reply, bus, {ok, <<16#5:16/little, 0:16>>, 0}}]},
                 erx_xhci_core:step({read, #{{portsc, 2} => 16#1 bor (3 bsl 5)}}, 0, S1)),
    {S2, [{read, [{portsc, 3}]}]} = erx_xhci_core:step({port, bus, 3, power_on}, 0, S0),
    ?assertMatch({_, [{write, {portsc, 3}, ?PS_PP}, {reply, bus, ok}]},
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
    {S3, [{port_event, 2}, complete]} = erx_xhci_core:step({completed, {ok, [{port, 2}]}}, 0, S2),
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

%% An interrupt before the controller runs is held: no ack until the bus starts, or the
%% controller fails, and then exactly one.
an_interrupt_before_running_is_held_test() ->
    {S1, []} = erx_xhci_core:step(interrupt, 0, handoff_started()),
    ?assertEqual({S1, []}, erx_xhci_core:step(interrupt, 0, S1)),
    {S2, [negotiate]} = erx_xhci_core:step({read, #{{legacy, bios_owned} => 0}}, 0, S1),
    {S3, [{start_bus, 4}, ack]} = erx_xhci_core:step({negotiated, ok}, 0, S2),
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
             {S1, _} = erx_xhci_core:step({start, Bound}, 0, erx_xhci_core:new()),
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
check_start([negotiate | Rest], Now, W = #{legacy := Legacy, released := Released, installing := Since}) ->
    ?assert(Released orelse not Legacy),
    check_start(Rest, Now, W#{awaits := install, installing := case Since of none -> Now; _ -> Since end});
check_start(Actions = [{start_bus, 4} | _], _Now, #{last := {negotiated, ok}, held := Held}) ->
    ?assertEqual([{start_bus, 4} | [ack || Held]], Actions),
    {ended, running};
check_start([{fail, install_timeout}], Now, #{installing := Since}) ->
    ?assert(Now >= Since + 3000),
    {ended, failed};
check_start([{fail, {install, eio}}], _Now, _W) -> {ended, failed}.
