%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Tests of the device service's PCIe process, erx_devices_pci, applying
%% erx_devices_pci_core (docs/design-pcie.md, "Concurrency"), and of the
%% decoders of its two facets, erx_pci_facet and erx_pci_bus_facet. The
%% module itself stands in for the domain library (devices/0, pci_bridges/0,
%% pci_report/2, pci_mode/2, pci_answered/1), its catalogues kept in persistent_term and every
%% write sent to the test process; a plain process stands in for the
%% enumerator's pcie facet and another for the domain service's await_grant.
-module(erx_devices_pci_tests).

-include_lib("eunit/include/eunit.hrl").

-export([devices/0, pci_bridges/0, pci_report/2, pci_mode/2, pci_answered/1, pci_firmware/1]).

-define(PLACE, {3, 1, 0, 0}).
-define(ROW, 5).
-define(HOLDER, 7).
-define(PCIE, 11).
%% The host bridge's device row, the place's first element.
-define(BRIDGE, 3).

%% The domain library's stand-in.
devices() -> {ok, persistent_term:get({?MODULE, devices})}.
pci_bridges() -> {ok, persistent_term:get({?MODULE, bridges}, [])}.
pci_report(Bridge, Records) -> written({report, Bridge, Records}).
pci_mode(Index, Mode) -> written({mode, Index, Mode}).
%% The write lags, so a reply sent before it reaches the test well before the write.
pci_answered(D) -> timer:sleep(100), written({answered, D}).
%% Runs in the firmware worker: names the process it runs in, then waits for the test's answer.
pci_firmware(Bridge) ->
    written({firmware, Bridge, self()}),
    receive {firmware_answer, Answer} -> Answer end.

written(Write) ->
    persistent_term:get({?MODULE, test}) ! {library, Write},
    ok.

row(Mode) ->
    #{index => ?ROW, holder => ?HOLDER, place => ?PLACE,
      setting => #{mode => Mode, route => none}}.

%% A stand-in serving gen_server calls with Answer(Request), each request also
%% sent to the test process.
server(Answer) ->
    Test = self(),
    spawn_link(fun() -> serve(Test, Answer) end).

serve(Test, Answer) ->
    receive
        {'$gen_call', From, Request} ->
            Test ! {called, self(), Request},
            case Answer(Request) of
                silent -> ok;
                Reply -> gen_server:reply(From, Reply)
            end,
            serve(Test, Answer)
    end.

%% The process over the stand-ins, its pcie facet answering Pcie(Call).
started(Mode, Pcie) ->
    over([row(Mode)], [], Pcie, [?PCIE]).

%% The process over a library of Devices and pci bridge catalogues Bridges, its
%% pcie facet answering Pcie(Call); the domain service answers await_grant with
%% that facet for each incarnation of Live and {error, ended} for any other.
over(Devices, Bridges, Pcie, Live) ->
    flushed(),
    persistent_term:put({?MODULE, test}, self()),
    persistent_term:put({?MODULE, devices}, Devices),
    persistent_term:put({?MODULE, bridges}, Bridges),
    Facet = server(Pcie),
    Domains = server(fun({await_grant, pcie, D}) ->
                             case lists:member(D, Live) of
                                 true -> {ok, Facet};
                                 false -> {error, ended}
                             end
                     end),
    {ok, Pid} = erx_devices_pci:start_link(#{lib => ?MODULE, register => false,
                                             await => fun(Name, Id) ->
                                                              gen_server:send_request(Domains, {await_grant, Name, Id})
                                                      end}),
    unlink(Pid),
    {Pid, Facet}.

%% An earlier case's writes and calls, which may still be in the mailbox.
flushed() ->
    receive {library, _} -> flushed(); {called, _, _} -> flushed() after 0 -> ok end.

stopped(Pid) ->
    exit(Pid, kill),
    persistent_term:erase({?MODULE, devices}),
    persistent_term:erase({?MODULE, bridges}),
    persistent_term:erase({?MODULE, test}).

%% The PCIe incarnation's report, answered once its facet is known.
synced(Pid) ->
    {ok, #{?PLACE := _}} = gen_server:call(Pid, {pci_bus, ?PCIE, {report, []}}).

library() ->
    receive {library, Write} -> Write after 1000 -> none end.

a_holders_end_lowers_its_rows_in_the_library_between_test() ->
    {Pid, _Facet} = started(mastering, fun(_) -> ok end),
    erx_devices_pci:domain_ended(Pid, ?HOLDER),
    ?assertEqual({mode, ?ROW, off}, library()),
    stopped(Pid).

a_holders_end_is_written_then_sent_when_synced_test() ->
    {Pid, Facet} = started(mastering, fun(_) -> ok end),
    synced(Pid),
    %% The report's empty answer lowers the row the catalogue does not keep.
    ?assertEqual({mode, ?ROW, off}, library()),
    ?assertEqual({answered, ?PCIE}, library()),
    erx_devices_pci:domain_ended(Pid, ?HOLDER),
    ?assertEqual({mode, ?ROW, off}, library()),
    receive {called, Facet, Call} -> ?assertEqual({set, ?PLACE, #{mode => off, route => none}}, Call)
    after 1000 -> ?assert(false)
    end,
    stopped(Pid).

a_request_between_waits_for_the_report_test() ->
    {Pid, Facet} = started(decoding, fun(_) -> ok end),
    Caller = self(),
    spawn_link(fun() -> Caller ! {answer, gen_server:call(Pid, {pci, ?HOLDER, {open, ?PLACE}})} end),
    receive {answer, Early} -> ?assertEqual(early, Early) after 200 -> ok end,
    synced(Pid),
    receive {called, Facet, Call} -> ?assertMatch({set, ?PLACE, #{mode := decoding}}, Call)
    after 1000 -> ?assert(false)
    end,
    receive {answer, Answer} -> ?assertEqual(ok, Answer) after 1000 -> ?assert(false) end,
    stopped(Pid).

a_request_of_another_domains_row_is_not_held_test() ->
    {Pid, _Facet} = started(decoding, fun(_) -> ok end),
    synced(Pid),
    ?assertEqual({error, not_held}, gen_server:call(Pid, {pci, ?HOLDER + 1, {open, ?PLACE}})),
    stopped(Pid).

a_pcie_call_past_its_deadline_answers_unavailable_test_() ->
    {timeout, 10,
     fun() ->
             {Pid, _Facet} = started(decoding, fun(_) -> silent end),
             synced(Pid),
             ?assertEqual({error, unavailable}, gen_server:call(Pid, {pci, ?HOLDER, {master, ?PLACE}}, 5000)),
             stopped(Pid)
     end}.

an_enumerator_answer_outside_the_interface_is_not_passed_on_test() ->
    {Pid, _Facet} = started(decoding, fun(_) -> {surprise, self()} end),
    synced(Pid),
    ?assertEqual({error, failed}, gen_server:call(Pid, {pci, ?HOLDER, {open, ?PLACE}})),
    stopped(Pid).

the_pci_decoder_refuses_what_the_interface_does_not_take_test() ->
    ?assertEqual({ok, {open, ?PLACE}}, erx_pci_facet:decode({open, ?PLACE})),
    ?assertEqual({ok, {reset, {0, 255, 31, 7}}}, erx_pci_facet:decode({reset, {0, 255, 31, 7}})),
    [?assertEqual({error, badarg}, erx_pci_facet:decode(Request))
     || Request <- [{open, {3, 256, 0, 0}}, {open, {3, 1, 32, 0}}, {open, {3, 1, 0, 8}}, {open, {-1, 1, 0, 0}},
                    {open, {1 bsl 32, 1, 0, 0}}, {open, {3, 1, 0}}, {close, ?PLACE}, {open, ?PLACE, extra},
                    open, {open, [3, 1, 0, 0]}]].

the_pci_bus_decoder_refuses_what_the_interface_does_not_take_test() ->
    Record = #{bridge => 3, bus => 1, device => 0, function => 0},
    ?assertEqual({ok, targets}, erx_pci_bus_facet:decode(targets)),
    ?assertEqual({ok, {report, [#{record => Record, kept => true}]}},
                 erx_pci_bus_facet:decode({report, [#{record => Record, kept => true}]})),
    ?assertEqual({ok, {firmware, 3}}, erx_pci_bus_facet:decode({firmware, 3})),
    [?assertEqual({error, badarg}, erx_pci_bus_facet:decode(Request))
     || Request <- [{report, [#{record => Record, kept => perhaps}]}, {report, [#{record => Record}]},
                    {report, [#{record => maps:remove(bus, Record), kept => true}]},
                    {report, [#{record => Record#{device => 32}, kept => true}]}, {report, not_a_list},
                    {report, [#{record => Record, kept => true} | tail]}, {firmware, -1}, {targets, 1}]].

%% The library clears a row's holder at the end before it reports it, so a read
%% between the two must not lose the row: its lowering is still sent.
a_holders_end_after_the_library_cleared_its_row_is_still_sent_test() ->
    {Pid, Facet} = started(mastering, fun(_) -> ok end),
    synced(Pid),
    ?assertEqual({mode, ?ROW, off}, library()),
    persistent_term:put({?MODULE, devices}, [(row(off))#{holder => none}]),
    ?assertEqual({error, not_held}, gen_server:call(Pid, {pci, ?HOLDER, {open, ?PLACE}})),
    erx_devices_pci:domain_ended(Pid, ?HOLDER),
    receive {called, Facet, Call} -> ?assertEqual({set, ?PLACE, #{mode => off, route => none}}, Call)
    after 1000 -> ?assert(false)
    end,
    stopped(Pid).

%% The domain service may give the row to the holder's next incarnation before
%% the process takes the end; a read showing the new holder must not lose the
%% ended one's row.
a_holders_end_after_its_next_incarnation_was_read_is_still_sent_test() ->
    {Pid, Facet} = started(mastering, fun(_) -> ok end),
    synced(Pid),
    ?assertEqual({mode, ?ROW, off}, library()),
    persistent_term:put({?MODULE, devices}, [(row(off))#{holder => ?HOLDER + 1}]),
    ?assertEqual({error, not_held}, gen_server:call(Pid, {pci, ?HOLDER, {open, ?PLACE}})),
    erx_devices_pci:domain_ended(Pid, ?HOLDER),
    receive {called, Facet, Call} -> ?assertEqual({set, ?PLACE, #{mode => off, route => none}}, Call)
    after 1000 -> ?assert(false)
    end,
    stopped(Pid).

%% The library records the answered incarnation before the report's answer is sent.
the_answered_incarnation_is_written_before_the_answer_test() ->
    {Pid, _Facet} = started(mastering, fun(_) -> ok end),
    synced(Pid),
    %% One sender: the write is in the mailbox at the reply only if it came first.
    ?assertEqual({mode, ?ROW, off}, receive {library, M} -> M after 0 -> none end),
    ?assertEqual({answered, ?PCIE}, receive {library, N} -> N after 0 -> none end),
    stopped(Pid).

%% A process its supervisor restarted while the answered incarnation lives: the
%% library's answered names the bridge's living holder, so it begins synced, sends
%% every row the library holds at off (an end forwarded while it restarted is
%% lost), and goes on sending each holder's lowering.
a_restart_while_the_answered_incarnation_lives_keeps_lowering_test() ->
    Ended = (row(off))#{index => ?ROW + 1, holder => none, place => {?BRIDGE, 2, 0, 0}},
    {Pid, Facet} = restarted(?PCIE, ?PCIE, [row(mastering), Ended]),
    receive {called, Facet, First} -> ?assertEqual({set, {?BRIDGE, 2, 0, 0}, #{mode => off, route => none}}, First)
    after 1000 -> ?assert(false)
    end,
    erx_devices_pci:domain_ended(Pid, ?HOLDER),
    ?assertEqual({mode, ?ROW, off}, library()),
    receive {called, Facet, Call} -> ?assertEqual({set, ?PLACE, #{mode => off, route => none}}, Call)
    after 1000 -> ?assert(false)
    end,
    stopped(Pid).

%% An answered incarnation that has ended, its bridge held by its successor or by
%% none: the restarted process begins between, and a holder's end sends nothing.
a_restart_after_the_answered_incarnation_ended_begins_between_test() ->
    [begin
         {Pid, Facet} = restarted(?PCIE, Holder, [row(mastering)]),
         erx_devices_pci:domain_ended(Pid, ?HOLDER),
         ?assertEqual({mode, ?ROW, off}, library()),
         receive {called, Facet, Call} -> ?assertEqual(none, Call) after 200 -> ok end,
         stopped(Pid)
     end || Holder <- [?PCIE + 1, none]].

%% The process started over a library whose bridge ?BRIDGE records Answered as
%% answered and is held by Holder, with the pci rows Rows.
restarted(Answered, Holder, Rows) ->
    over([#{index => ?BRIDGE, holder => Holder, place => none, setting => none} | Rows],
         [#{bridge => #{index => ?BRIDGE}, firmware_lost => false, answered => Answered, layouts => []}],
         fun(_) -> ok end, [Holder]).

%% Firmware requests (docs/design-system.md, "Firmware requests"): the process over
%% one held bridge ?BRIDGE, whose stand-in pci_firmware/1 runs in the firmware worker
%% and waits there for the test's answer.
firmware_started() ->
    over([row(off)], [#{bridge => #{index => ?BRIDGE}, firmware_lost => false, answered => none, layouts => []}],
         fun(_) -> ok end, [?PCIE]).

%% A pci_bus:firmware/1 call sent from a process of its own, its answer sent to the test.
firmware_asked(Pid, Bridge) ->
    Test = self(),
    spawn(fun() -> Test ! {firmware, Bridge, gen_server:call(Pid, {pci_bus, ?PCIE, {firmware, Bridge}}, 5000)} end).

%% The worker the stand-in was called in for Bridge, or none within Timeout.
worker_called(Bridge, Timeout) ->
    receive {library, {firmware, Bridge, Worker}} -> Worker after Timeout -> none end.

firmware_answer(Bridge) ->
    receive {firmware, Bridge, Answer} -> Answer after 1000 -> none end.

%% The notification is made in the worker, not the process, so the process answers
%% other calls while it waits, and the library's answer is the reply.
a_firmware_request_waits_in_the_worker_and_the_process_answers_meanwhile_test() ->
    {Pid, _Facet} = firmware_started(),
    firmware_asked(Pid, ?BRIDGE),
    Worker = worker_called(?BRIDGE, 1000),
    ?assert(is_pid(Worker) andalso Worker =/= Pid),
    ?assertMatch({ok, [#{index := ?BRIDGE}], [], _}, gen_server:call(Pid, {pci_bus, ?PCIE, targets}, 1000)),
    Worker ! {firmware_answer, ok},
    ?assertEqual(ok, firmware_answer(?BRIDGE)),
    stopped(Pid).

%% The library's status other than ok is the answer, a timeout among them.
a_timed_out_notification_answers_its_status_test() ->
    {Pid, _Facet} = firmware_started(),
    firmware_asked(Pid, ?BRIDGE),
    worker_called(?BRIDGE, 1000) ! {firmware_answer, {error, etimedout}},
    ?assertEqual({error, etimedout}, firmware_answer(?BRIDGE)),
    stopped(Pid).

%% A bridge row the library does not hold for the PCIe domain is refused before the
%% worker sees it.
a_firmware_request_for_a_bridge_not_held_is_refused_test() ->
    {Pid, _Facet} = firmware_started(),
    firmware_asked(Pid, ?BRIDGE + 1),
    ?assertEqual(none, worker_called(?BRIDGE + 1, 200)),
    ?assertEqual({error, not_held}, firmware_answer(?BRIDGE + 1)),
    stopped(Pid).

%% One request in flight: a second waits in the queue until the first's answer, then
%% goes to the same worker, and each caller gets its own answer.
the_worker_is_handed_the_next_request_only_after_the_last_answer_test() ->
    {Pid, _Facet} = firmware_started(),
    firmware_asked(Pid, ?BRIDGE),
    First = worker_called(?BRIDGE, 1000),
    Test = self(),
    spawn(fun() -> Test ! {second, gen_server:call(Pid, {pci_bus, ?PCIE, {firmware, ?BRIDGE}}, 5000)} end),
    ?assertEqual(none, worker_called(?BRIDGE, 200)),
    %% The second waits in the process, not in the worker's mailbox.
    ?assertEqual({message_queue_len, 0}, process_info(First, message_queue_len)),
    First ! {firmware_answer, {error, ebusy}},
    ?assertEqual({error, ebusy}, firmware_answer(?BRIDGE)),
    ?assertEqual(First, worker_called(?BRIDGE, 1000)),
    First ! {firmware_answer, ok},
    receive {second, Answer} -> ?assertEqual(ok, Answer) after 1000 -> ?assert(false) end,
    stopped(Pid).

%% The worker's end ends the process by their link, so their supervisor restarts both.
the_workers_end_ends_the_process_test() ->
    {Pid, _Facet} = firmware_started(),
    Ref = monitor(process, Pid),
    firmware_asked(Pid, ?BRIDGE),
    exit(worker_called(?BRIDGE, 1000), kill),
    receive {'DOWN', Ref, process, Pid, Reason} -> ?assertEqual(killed, Reason) after 1000 -> ?assert(false) end,
    stopped(Pid).
