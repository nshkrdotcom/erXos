%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The bus process, its supervision tree and the hub function (docs/design-usb.md,
%% "The process tree", "Ports, hubs and devices: the bus core", "Hubs"), run whole
%% under erx_usb's top supervisor against erx_usb_fake_xhci, a controller that speaks the design's
%% controller-to-bus protocol over a world each case changes, with a stand-in HID
%% function the case can end at will. Each case reads what the controller was asked,
%% in order, from the fake's log, and which function instances run from the stand-in's
%% and the function supervisor's reports.

-module(erx_usb_bus_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(FAKE, erx_usb_fake_xhci_under_test).
%% How long a case waits for each thing it expects. A case whose expectation never
%% comes usually fails on its own assertion, within EUnit's 5 s; one that chains
%% waits may time out instead, which the runner counts as a failure too.
-define(WAIT_MS, 2500).

%% ---------------------------------------------------------------------------
%% Cases
%% ---------------------------------------------------------------------------

a_keyboard_on_a_root_port_runs_its_function_test() ->
    with_bus(#{[1] => keyboard}, fun() ->
        Ref = configured([1]),
        {hid_started, _Pid, Args} = next_hid(),
        ?assertMatch(#{device := Ref, run := 1, function := #{interface := 0}}, Args),
        ?assertEqual([{Ref, 16#81}], [erx_usb_pipe:endpoint(P) || P <- maps:get(pipes, Args)]),
        ?assertEqual({Ref, 0}, erx_usb_pipe:endpoint(maps:get(control, Args))),
        ?assert(is_pid(maps:get(places, Args)))
    end).

%% A function that finds its interface unusable ends for good, as a FreeBSD probe's
%% ENXIO does: it is not started again, its pipes are not reset, and the device's
%% other function keeps running.
an_unusable_interface_leaves_the_others_running_test() ->
    persistent_term:put(erx_usb_hid_stand_in, {unusable, 1}),
    try
        with_bus(#{[1] => composite}, fun() ->
            Ref = configured([1]),
            {hid_started, Running, #{function := #{interface := 0}}} = next_hid(),
            Gone = receive {hid_unusable, Pid, #{function := #{interface := 1}}} -> Pid
                   after ?WAIT_MS -> error(no_unusable_start)
                   end,
            settled(),
            ?assertNot(is_process_alive(Gone)),
            ?assert(is_process_alive(Running)),
            ?assertEqual(0, count({reset_pipe, Ref, 1, 16#82})),
            ?assertEqual([], [D || D = {detach, _} <- log()]),
            ?assertEqual(none, next_hid(200)),
            ?assertEqual(none, receive Again = {hid_unusable, _, _} -> Again after 0 -> none end)
        end)
    after
        persistent_term:erase(erx_usb_hid_stand_in)
    end.

%% A function's end while its device stays resets its pipes and starts it again with
%% the next run number, at most usb_function_restarts_max times in the window; the end
%% past them disables the port and detaches the device.
a_function_ends_and_restarts_within_its_bounds_test() ->
    with_bus(#{[1] => keyboard}, fun() ->
        Ref = configured([1]),
        Runs = [begin
                    {hid_started, Pid, #{run := Run}} = next_hid(),
                    exit(Pid, kill),
                    Run
                end || _ <- lists:seq(0, ?ERX_USB_FUNCTION_RESTARTS_MAX)],
        ?assertEqual(lists:seq(1, ?ERX_USB_FUNCTION_RESTARTS_MAX + 1), Runs),
        wait(fun() -> lists:member({detach, Ref}, log()) end),
        ?assertEqual(?ERX_USB_FUNCTION_RESTARTS_MAX, count({reset_pipe, Ref, 0, 16#81})),
        ?assert(lists:member({port, root, 1, disable}, log())),
        ?assertEqual(none, next_hid(200))
    end).

%% A start that fails is an end too, so the function is retried within the same
%% bounds and then given up, rather than left counted as running with nothing behind.
a_function_whose_start_fails_ends_test() ->
    persistent_term:put(erx_usb_hid_stand_in, fail),
    try
        with_bus(#{[1] => keyboard}, fun() ->
            Ref = configured([1]),
            wait(fun() -> lists:member({detach, Ref}, log()) end),
            ?assertEqual(?ERX_USB_FUNCTION_RESTARTS_MAX, count({reset_pipe, Ref, 0, 16#81})),
            ?assert(lists:member({port, root, 1, disable}, log()))
        end)
    after
        persistent_term:erase(erx_usb_hid_stand_in)
    end.

%% A start that fails as unusable, as a HID function's with no free input number, is
%% final too: its pipes are not reset, it is not started again, and the device's other
%% function keeps running.
an_unusable_start_is_final_test() ->
    persistent_term:put(erx_usb_hid_stand_in, {unusable_start, 1}),
    try
        with_bus(#{[1] => composite}, fun() ->
            Ref = configured([1]),
            {hid_started, Running, #{function := #{interface := 0}}} = next_hid(),
            settled(),
            ?assert(is_process_alive(Running)),
            ?assertEqual(0, count({reset_pipe, Ref, 1, 16#82})),
            ?assertEqual([], [D || D = {detach, _} <- log()]),
            ?assertEqual(1, refusals(0))
        end)
    after
        persistent_term:erase(erx_usb_hid_stand_in)
    end.

%% A hub's ports are powered and read with the hub class's requests on its EP0; a
%% device plugged in behind it is reported on the hub's status pipe, its connection
%% change cleared, and it enumerates through the address-zero turn with its route.
a_hub_with_a_child_enumerates_it_test() ->
    with_bus(#{[1] => {hub, 2}}, fun() ->
        Hub = configured([1]),
        settled(),
        ok = erx_usb_fake_xhci:plug(?FAKE, [1, 2], keyboard),
        Keyboard = configured([1, 2]),
        Log = log(),
        ?assert(lists:member({port, 1, power_on}, hub_ops(Hub, Log))),
        ?assert(lists:member({port, 2, power_on}, hub_ops(Hub, Log))),
        ?assert(lists:member({port, 2, reset}, hub_ops(Hub, Log))),
        ?assertMatch([#{root_port := 1, route := [2]}], [P || {address, R, _, P} <- Log, R =:= Keyboard]),
        ?assertMatch([_], hub_functions()),
        {hid_started, _Pid, #{device := Keyboard}} = next_hid()
    end).

%% A hub's removal detaches the devices below it first and ends every function of each.
a_hub_removed_detaches_below_it_first_test() ->
    with_bus(#{[1] => {hub, 2}, [1, 2] => keyboard}, fun() ->
        Hub = configured([1]),
        Keyboard = configured([1, 2]),
        {hid_started, HidPid, _} = next_hid(),
        [HubPid] = hub_functions(),
        ok = erx_usb_fake_xhci:unplug(?FAKE, [1]),
        wait(fun() -> lists:member({detach, Hub}, log()) end),
        ?assertEqual([{detach, Keyboard}, {detach, Hub}], [D || D = {detach, _} <- log()]),
        ?assertNot(is_process_alive(HidPid)),
        ?assertNot(is_process_alive(HubPid)),
        ?assertEqual(none, next_hid(200))
    end).

%% A device replaced before its port is read is detached and the new one enumerated
%% under a new reference, never under the old one's.
a_device_replaced_unseen_gets_a_new_reference_test() ->
    with_bus(#{[1] => keyboard}, fun() ->
        Old = configured([1]),
        {hid_started, _, #{device := Old}} = next_hid(),
        ok = erx_usb_fake_xhci:replace(?FAKE, [1], keyboard),
        wait(fun() -> length(references([1], log())) =:= 2 end),
        [Old, New] = references([1], log()),
        wait(fun() -> lists:member(New, configured_references(log())) end),
        ?assert(lists:member({detach, Old}, log())),
        {hid_started, _, #{device := New, run := 1}} = next_hid()
    end).

%% A hub function that fails is restarted after its pipe's reset; the new instance's
%% first report reads every port again, and the device behind the hub stays.
a_hub_function_restart_reads_every_port_again_test() ->
    with_bus(#{[1] => {hub, 2}, [1, 2] => keyboard}, fun() ->
        Hub = configured([1]),
        _Keyboard = configured([1, 2]),
        {hid_started, HidPid, _} = next_hid(),
        [Old] = hub_functions(),
        settled(),
        Reads = count_hub_op(Hub, {port, 1, get_status}),
        ok = erx_usb_fake_xhci:fail_status_transfer(?FAKE, Hub),
        wait(fun() -> hub_functions() =/= [] andalso hub_functions() =/= [Old] end),
        wait(fun() -> count_hub_op(Hub, {port, 1, get_status}) > Reads end),
        ?assertEqual(1, count({reset_pipe, Hub, 0, 16#81})),
        ?assert(is_process_alive(HidPid)),
        ?assertEqual([], [D || D = {detach, _} <- log()])
    end).

%% A report from a hub function instance that has ended is dropped: it names no
%% instance the bus process holds, so it reads no port and is answered to no one.
a_report_from_an_ended_hub_instance_is_dropped_test() ->
    with_bus(#{[1] => {hub, 2}}, fun() ->
        Hub = configured([1]),
        [Old] = hub_functions(),
        ok = erx_usb_fake_xhci:fail_status_transfer(?FAKE, Hub),
        wait(fun() -> hub_functions() =/= [] andalso hub_functions() =/= [Old] end),
        settled(),
        Reads = count_hub_op(Hub, {port, 1, get_status}),
        erx_usb_fake_xhci:bus(?FAKE) ! {changed, Hub, [1], Old},
        settled(),
        ?assertEqual(Reads, count_hub_op(Hub, {port, 1, get_status}))
    end).

%% A controller that fails at every start is restarted with its bus group at most
%% usb_bus_restarts_max times, then given up, while the places keep running.
a_controller_failing_at_every_reset_is_given_up_test() ->
    register(erx_usb_bus_tests, self()),
    process_flag(trap_exit, true),
    {ok, Sup} = erx_usb:start_link(),
    try
        ok = erx_usb:start_controllers([{erx_usb_fake_xhci, start_link, [{?FAKE, 1, fails_at_start}]}]),
        {places, Places, _, _} = lists:keyfind(places, 1, supervisor:which_children(Sup)),
        Starts = fake_starts(0),
        ?assertEqual(?ERX_USB_BUS_RESTARTS_MAX + 1, Starts),
        ?assertMatch({{controller, 0}, undefined, _, _}, lists:keyfind({controller, 0}, 1, supervisor:which_children(Sup))),
        ?assertMatch({places, Places, _, _}, lists:keyfind(places, 1, supervisor:which_children(Sup))),
        ?assert(is_process_alive(Places))
    after
        stop(Sup)
    end.

%% A controller's failure restarts its bus group, which enumerates every port again
%% and starts every function afresh, at run 1; the places are untouched. A reference
%% names a device within one bus process's life, so the new bus may reuse old ones.
a_controller_failure_restarts_the_bus_not_the_places_test() ->
    with_bus(#{[1] => keyboard}, fun() ->
        Sup = whereis(erx_usb),
        {places, Places, _, _} = lists:keyfind(places, 1, supervisor:which_children(Sup)),
        _ = configured([1]),
        {hid_started, HidPid, _} = next_hid(),
        exit(whereis(?FAKE), host_controller_error),
        {hid_started, NewPid, #{run := 1}} = next_hid(),
        ?assertNotEqual(HidPid, NewPid),
        ?assertNot(is_process_alive(HidPid)),
        ?assertMatch({places, Places, _, _}, lists:keyfind(places, 1, supervisor:which_children(Sup)))
    end).

%% The application's top supervisor runs the places, and one bus group for each
%% controller start, here one fake's, whose keyboard's function starts below it; and a
%% bus group that ends abnormally ends the top supervisor, intensity 0, and so the
%% application and the domain (docs/design-usb.md, "Failure handling").
the_application_runs_one_bus_group_per_controller_test() ->
    register(erx_usb_bus_tests, self()),
    process_flag(trap_exit, true),
    {ok, Top} = erx_usb:start_link(),
    try
        ok = erx_usb:start_controllers([{erx_usb_fake_xhci, start_link, [{?FAKE, 2, #{[1] => keyboard}}]}]),
        [places, {controller, 0}] = lists:sort([Id || {Id, _, supervisor, _} <- supervisor:which_children(Top)]),
        {{controller, 0}, Group, _, _} = lists:keyfind({controller, 0}, 1, supervisor:which_children(Top)),
        _ = configured([1]),
        ?assertMatch({hid_started, _, #{run := 1}}, next_hid()),
        exit(Group, kill),
        receive {'EXIT', Top, Reason} -> ?assertEqual(shutdown, Reason)
        after ?WAIT_MS -> error(top_supervisor_lives)
        end
    after
        true = unregister(erx_usb_bus_tests),
        flush()
    end.

%% The places start with the application, from the boot script, and their mint names
%% itself usb_input's mint before init's ready report; the row's -eval starts the
%% controllers after it, when erx_facet:provide/2 answers {error, reported}.
the_mint_provides_before_the_report_and_the_controllers_start_after_test() ->
    register(erx_usb_bus_tests, self()),
    process_flag(trap_exit, true),
    persistent_term:erase({erx, provides}),
    {ok, Top} = erx_usb:start_link(),
    try
        {places, Places, _, _} = lists:keyfind(places, 1, supervisor:which_children(Top)),
        [Mint] = [Pid || {mint, Pid, _, _} <- supervisor:which_children(Places)],
        ?assertEqual(#{usb_input => Mint}, persistent_term:get({erx, provides})),
        persistent_term:put({erx, provides}, reported),
        ok = erx_usb:start_controllers([{erx_usb_fake_xhci, start_link, [{?FAKE, 2, #{[1] => keyboard}}]}]),
        _ = configured([1]),
        ?assertMatch({hid_started, _, #{run := 1}}, next_hid())
    after
        persistent_term:erase({erx, provides}),
        stop(Top)
    end.

%% ---------------------------------------------------------------------------
%% The fixture
%% ---------------------------------------------------------------------------

%% Runs Case against a bus of two root ports holding World, under erx_usb's top
%% supervisor.
with_bus(World, Case) ->
    register(erx_usb_bus_tests, self()),
    process_flag(trap_exit, true),
    {ok, Sup} = erx_usb:start_link(),
    try
        ok = erx_usb:start_controllers([{erx_usb_fake_xhci, start_link, [{?FAKE, 2, World}]}]),
        Case()
    after
        stop(Sup)
    end.

stop(Sup) ->
    unlink(Sup),
    Monitor = monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Monitor, process, Sup, _} -> ok end,
    true = unregister(erx_usb_bus_tests),
    flush().

flush() ->
    receive _ -> flush() after 0 -> ok end.

fake_starts(Count) ->
    receive {fake_started, _} -> fake_starts(Count + 1) after 1000 -> Count end.

%% The stand-in's refused starts, counted from its reports.
refusals(Count) ->
    receive {hid_refused, _} -> refusals(Count + 1) after 0 -> Count end.

next_hid() ->
    case next_hid(?WAIT_MS) of
        none -> error(no_hid_start);
        Started -> Started
    end.

next_hid(Timeout) ->
    receive Started = {hid_started, _, _} -> Started after Timeout -> none end.

%% The fake's log once it has stood still for a moment, so every answer in flight
%% has been taken.
settled() -> settled(?WAIT_MS div 100).

settled(0) ->
    error({unsettled, log()});
settled(Tries) ->
    Before = log(),
    timer:sleep(100),
    case log() of
        Before -> ok;
        _Moved -> settled(Tries - 1)
    end.

log() -> erx_usb_fake_xhci:log(?FAKE).

count(Request) -> length([R || R <- log(), R =:= Request]).

%% Hub's port operations, as the bus process tagged its control requests.
hub_ops(Hub, Log) -> [Tag || {control, R, Tag = {port, _, _}, _, _} <- Log, R =:= Hub].

count_hub_op(Hub, {port, N, Op}) -> length([T || T = {port, M, O} <- hub_ops(Hub, log()), M =:= N, O =:= Op]).

%% The references addressed at Place, oldest first.
references([Root | Tiers], Log) ->
    [R || {address, R, _, #{root_port := Rp, route := T}} <- Log, Rp =:= Root, T =:= Tiers].

configured_references(Log) -> [R || {configure_endpoints, R, _, _} <- Log].

%% The reference of the device at Place, once its endpoints are configured.
configured(Place) ->
    wait(fun() ->
             case references(Place, log()) of
                 [] -> false;
                 Refs -> lists:member(lists:last(Refs), configured_references(log()))
             end
         end),
    lists:last(references(Place, log())).

hub_functions() ->
    Bus = erx_usb_fake_xhci:bus(?FAKE),
    {dictionary, Dictionary} = process_info(Bus, dictionary),
    {_, Parent} = lists:keyfind('$ancestors', 1, Dictionary),
    [Group | _] = Parent,
    {functions, Functions, _, _} = lists:keyfind(functions, 1, supervisor:which_children(Group)),
    [Pid || {_, Pid, _, [erx_usb_bus_sup]} <- supervisor:which_children(Functions), is_pid(Pid),
            is_hub(Pid)].

is_hub(Pid) ->
    case proc_lib:initial_call(Pid) of
        {erx_usb_hub, init, _} -> true;
        _ -> false
    end.

wait(Condition) -> wait(Condition, erlang:monotonic_time(millisecond) + ?WAIT_MS).

wait(Condition, Deadline) ->
    case Condition() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(20), wait(Condition, Deadline);
                false -> error({timeout, log()})
            end
    end.

%% A domain given no xHCI function record starts no controller, and says so: a VL805
%% its PCIe report held back or never found is otherwise silent.
a_domain_given_no_xhci_function_says_it_starts_no_controller_test() ->
    ?assertEqual({ok, ["usb: no xhci function record; no controller started"]},
                 erx_pcie_log_capture:logged(fun() -> erx_usb:start_controllers([]) end)).
