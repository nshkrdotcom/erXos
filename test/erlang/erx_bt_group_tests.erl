%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of the controller group (docs/design-bluetooth.md, "Verification": the
%% controller group's row, the link's backlog through the group and the identity
%% address's), over erx_bt_line_model, the real store and no GATT table, and of erx_bt_adv. test/host/erx_bt_group_test.rb runs them on
%% stock's emulator, with erx_bytes's host stand-in, and seeds the rows' faults.
-module(erx_bt_group_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(WAIT_MS, 3000).

%% The group reaches ready from its start and again after the controller process is
%% killed; each start's first read of data comes after ctl's answer; the identity address
%% LE Set Random Address writes is the same before and after the restart.
group_reaches_ready_and_keeps_the_address_test() ->
    with_group(#{}, fun(Model) ->
        First = await_address(Model, 1),
        Hci = whereis(erx_bt_hci),
        exit(Hci, kill),
        await(fun() -> is_ready() andalso whereis(erx_bt_hci) =/= Hci end),
        ?assertEqual(First, await_address(Model, 2)),
        Log = erx_bt_line_model:log(Model),
        ?assertNot(lists:member(read_at_reset, Log)),
        ?assertEqual(lists:duplicate(2, [reset, reset_done, read]), starts(Log))
    end).

%% A link process killed while connected is its disconnect: one HCI_Disconnect of its
%% handle with reason 0x13 on data.
a_killed_link_is_disconnected_test() ->
    with_group(#{}, fun(Model) ->
        Link = connect(Model, 16#40),
        exit(Link, kill),
        Disconnect = disconnect(16#40, 16#13),
        await(fun() -> lists:member({write, Disconnect}, erx_bt_line_model:log(Model)) end),
        timer:sleep(50),
        ?assertEqual(1, length([W || {write, W} <- erx_bt_line_model:log(Model), W =:= Disconnect]))
    end).

%% A link_down ends the link process and nothing after it reaches a process.
link_down_ends_the_link_test() ->
    with_group(#{}, fun(Model) ->
        Link = connect(Model, 16#40),
        Monitor = monitor(process, Link),
        erx_bt_line_model:inject(Model, <<4, 16#05, 4, 0, 16#40, 0, 16#13>>),
        receive {'DOWN', Monitor, process, Link, _} -> ok after ?WAIT_MS -> error(link_not_ended) end,
        erx_bt_line_model:inject(Model, <<2, 16#40, 16#20, 1, 0, 7>>),
        timer:sleep(50),
        ?assertEqual([], supervisor:which_children(erx_bt_link_sup)),
        ?assert(is_ready())
    end).

%% Each live handle's completions reach its link: with a share of one, the link hands
%% its second packet over only once Number Of Completed Packets returns the first. Two
%% LE signaling commands, Information Requests (L2CAP 4.10), each make one packet, the
%% link's Command Reject (4.1).
completions_reach_the_link_test() ->
    with_group(#{credits => 1}, fun(Model) ->
        _Link = connect(Model, 16#40),
        erx_bt_line_model:inject(Model, binary:copy(information_request(16#40), 2)),
        await(fun() -> acl_writes(Model) =:= 1 end),
        timer:sleep(50),
        ?assertEqual(1, acl_writes(Model)),
        erx_bt_line_model:inject(Model, <<4, 16#13, 5, 1, 16#40, 0, 1, 0>>),
        await(fun() -> acl_writes(Model) =:= 2 end)
    end).

%% A link held at its start, inside its resolve call to a store that never answers, is
%% sent its backlog, bt_link_backlog (32) of the controller's messages, and no more: the
%% next of 8 ACL packets beyond it cuts it off, HCI_Disconnect with 0x14 (Low Resources) is written once, and
%% the model's Disconnection Complete ends the link at link_down. Tracing what enters
%% the link's mailbox counts the messages whether or not the link takes them.
a_link_held_at_its_start_is_cut_at_its_backlog_test() ->
    with_store(fun holding_store/0, fun() ->
        with_controller_group(#{}, fun(Model) ->
            Link = connect(Model, 16#40),
            Monitor = monitor(process, Link),
            1 = erlang:trace(Link, true, ['receive']),
            erx_bt_line_model:inject(Model, binary:copy(information_request(16#40), ?ERX_BT_LINK_BACKLOG + 8)),
            receive {'DOWN', Monitor, process, Link, Reason} -> ?assertEqual(shutdown, Reason)
            after ?WAIT_MS -> error(link_not_ended)
            end,
            ?assertEqual([disconnect(16#40, 16#14)],
                         [W || {write, <<1, 16#0406:16/little, _/binary>> = W} <- erx_bt_line_model:log(Model)]),
            ?assertEqual(?ERX_BT_LINK_BACKLOG, received_from_controller(Link))
        end)
    end).

%% A ctl that answers eio ends the writer at every start, so the group ends at its
%% intensity.
a_failing_reset_ends_the_group_test() ->
    with_store(fun() ->
        Model = erx_bt_line_model:start(#{ctl => eio}),
        {ok, Group} = erx_bt_host_sup:start_link(erx_bt_line_model:open(Model)),
        unlink(Group),
        Monitor = monitor(process, Group),
        receive {'DOWN', Monitor, process, Group, Reason} -> ?assertEqual(shutdown, Reason)
        after ?WAIT_MS -> error(group_not_ended)
        end,
        erx_bt_line_model:stop(Model)
    end).

%% Ending the group leaves none of its registered processes behind: the helper returns
%% only once the supervisor, the link supervisor, the line's reader and writer and the
%% controller process are gone, so the next start never finds one registered. Checked
%% straight after each of many starts, with a link connected so the link supervisor has a
%% child to end.
group_teardown_leaves_nothing_registered_test() ->
    Names = [erx_bt_host_sup, erx_bt_link_sup, erx_bt_line_rx, erx_bt_line_tx, erx_bt_hci],
    with_store(fun() ->
        [begin
             with_controller_group(#{}, fun(Model) -> connect(Model, 16#40) end),
             ?assertEqual([], [Name || Name <- Names, whereis(Name) =/= undefined])
         end || _ <- lists:seq(1, 50)]
    end).

%% The identity address: 10,000 drawn from the generator all have the static form.
static_addresses_test() ->
    [begin
         {ok, <<2#11:2, Random:46>>} = erx_bt_store:static_address(<<(rand:uniform(1 bsl 48) - 1):48>>),
         ?assert(Random =/= 0 andalso Random =/= 1 bsl 46 - 1)
     end || _ <- lists:seq(1, 10000)],
    ?assertEqual(retry, erx_bt_store:static_address(<<0:48>>)),
    ?assertEqual(retry, erx_bt_store:static_address(<<16#3F, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF>>)).

%% erx_bt_adv: the Flags alone with no UUIDs; the lists of each width; the name whole or
%% shortened at a character boundary; the appearance only where it fits.
advertising_data_test() ->
    ?assertEqual(#{advertising_data => <<2, 1, 6>>, scan_response_data => <<3, 9, "bt", 3, 16#19, 16#C1, 3>>},
                 erx_bt_adv:data(#{uuids => [], name => <<"bt">>, appearance => 16#03C1})),
    #{advertising_data := Data} = erx_bt_adv:data(#{uuids => [16#180F, 1 bsl 127 + 5], name => <<>>, appearance => 0}),
    ?assertEqual(<<2, 1, 6, 3, 3, 16#0F, 16#18, 17, 7, 5, 0:112, 16#80>>, Data),
    Long = binary:copy(<<"a">>, 28),
    #{scan_response_data := Short} = erx_bt_adv:data(#{uuids => [], name => <<Long/binary, "\xc3\xa9\xc3\xa9">>,
                                                       appearance => 0}),
    ?assertEqual(<<29, 8, Long/binary>>, Short),
    ?assertError(badarg, erx_bt_adv:data(#{uuids => [1 bsl 127, 1 bsl 126], name => <<>>, appearance => 0})).

%% Helpers.

%% Runs Case with the store, the group over a fresh model, ready, then ends them.
with_group(Options, Case) ->
    with_store(fun() -> with_controller_group(Options, Case) end).

%% Runs Case with the controller group (erx_bt_host_sup) over a fresh model, ready, then
%% ends both.
with_controller_group(Options, Case) ->
    Model = erx_bt_line_model:start(Options),
    {ok, Group} = erx_bt_host_sup:start_link(erx_bt_line_model:open(Model)),
    unlink(Group),
    try
        await(fun is_ready/0),
        Case(Model)
    after
        end_group(Group),
        erx_bt_line_model:stop(Model)
    end.

%% Kills the group's supervisor and returns once it and every process under it have
%% exited: killing it ends its children only as each receives the signal, and the link
%% supervisor ends its own children before it exits, so a next start races the names.
end_group(Group) ->
    Monitors = [monitor(process, Pid) || Pid <- [Group | group_processes(Group)]],
    exit(Group, kill),
    [receive {'DOWN', Monitor, process, _, _} -> ok after ?WAIT_MS -> error(group_not_ended) end
     || Monitor <- Monitors],
    ok.

%% The group's children (a child the group is restarting has no pid), and the links
%% under the link supervisor.
group_processes(Group) ->
    Children = [Pid || {_, Pid, _, _} <- supervisor:which_children(Group), is_pid(Pid)],
    Links = [Pid || {_, Pid, _, _} <- supervisor:which_children(erx_bt_link_sup), is_pid(Pid)],
    Children ++ Links.

%% The store, and a stand-in for the registry, which answers each link's `join` with the
%% GAP and GATT services alone and takes what the links send it.
with_store(Case) -> with_store(fun erx_bt_store:start_link/0, Case).

%% The same with the store StartStore starts, which registers it as erx_bt_store and
%% answers {ok, Pid}.
with_store(StartStore, Case) ->
    application:set_env(erx_bt, name, "erxos-test"),
    {ok, Store} = StartStore(),
    unlink(Store),
    Registry = spawn(fun registry/0),
    true = register(erx_gatt_srv, Registry),
    try Case()
    after
        exit(Registry, kill),
        exit(Store, kill),
        wait_unregistered(erx_gatt_srv),
        wait_unregistered(erx_bt_store)
    end.

registry() ->
    receive
        {'$gen_call', From, {join, _Conn, _Info}} -> gen_server:reply(From, #{table => erx_gatt_db:build([]), values => #{}});
        _ -> ok
    end,
    registry().

%% A stand-in for the store that answers the identity address and holds every link's
%% resolve call unanswered.
holding_store() ->
    {ok, Address} = erx_bt_store:static_address(<<16#C1, 2, 3, 4, 5, 6>>),
    Store = spawn(fun() -> holding_store(Address) end),
    true = register(erx_bt_store, Store),
    {ok, Store}.

holding_store(Address) ->
    receive
        {'$gen_call', From, address} -> gen_server:reply(From, Address);
        _ -> ok
    end,
    holding_store(Address).

%% The controller's messages traced entering Link's mailbox, once every trace message of
%% Link's has been delivered; the case has traced Link's 'receive' before the first.
received_from_controller(Link) ->
    Ref = erlang:trace_delivered(Link),
    receive {trace_delivered, Link, Ref} -> received_from_controller(Link, 0) end.

received_from_controller(Link, Count) ->
    receive
        {trace, Link, 'receive', {hci, _}} -> received_from_controller(Link, Count + 1);
        {trace, Link, 'receive', _} -> received_from_controller(Link, Count)
    after 0 -> Count
    end.

wait_unregistered(Name) -> await(fun() -> whereis(Name) =:= undefined end).

is_ready() ->
    try erx_bt_hci:facts() of #{ready := Ready} -> Ready =/= none
    catch exit:_ -> false
    end.

%% The address the Nth LE Set Random Address wrote.
await_address(Model, N) ->
    Addresses = fun() -> [A || {write, <<1, 16#2005:16/little, 6, A:6/binary>>} <- erx_bt_line_model:log(Model)] end,
    await(fun() -> length(Addresses()) >= N end),
    lists:nth(N, Addresses()).

%% Each start's line events up to its first read.
starts(Log) ->
    Events = [E || E <- Log, lists:member(E, [reset, reset_done, read, read_at_reset])],
    [lists:sublist(Start, 3) || Start <- split_at_resets(Events)].

split_at_resets([]) -> [];
split_at_resets([reset | Rest]) ->
    {Start, Later} = lists:splitwith(fun(E) -> E =/= reset end, Rest),
    [[reset | Start] | split_at_resets(Later)].

%% A connection on Handle from the model controller, and its link process.
connect(Model, Handle) ->
    erx_bt_line_model:inject(Model, <<4, 16#3E, 19, 1, 0, Handle:16/little, 1, 0, 1, 2, 3, 4, 5, 6,
                                      24:16/little, 0:16, 400:16/little, 0>>),
    await(fun() -> length(supervisor:which_children(erx_bt_link_sup)) =:= 1 end),
    [{_, Link, _, _}] = supervisor:which_children(erx_bt_link_sup),
    Link.

%% An ACL packet for Handle holding one LE signaling Information Request (L2CAP 4.10),
%% which the link answers with one packet, its Command Reject (4.1).
information_request(Handle) ->
    Request = <<6:16/little, 5:16/little, 16#0A, 1, 2:16/little, 1:16/little>>,
    <<2, (Handle bor 16#2000):16/little, (byte_size(Request)):16/little, Request/binary>>.

%% HCI_Disconnect of Handle with Reason as the controller process writes it.
disconnect(Handle, Reason) -> <<1, 16#0406:16/little, 3, Handle:16/little, Reason>>.

acl_writes(Model) -> length([W || {write, <<2, _/binary>> = W} <- erx_bt_line_model:log(Model)]).

await(Done) -> await(Done, ?WAIT_MS div 10).

await(_Done, 0) -> error(timeout);
await(Done, Tries) ->
    case Done() of
        true -> ok;
        false -> timer:sleep(10), await(Done, Tries - 1)
    end.

%% proc_lib's crash report hands format_status/1 the reason alone (docs/design-log.md,
%% "Reports carry no term"), and the controller's and a link's callbacks answer it
%% without crashing, since a crashed callback shows no reason at all. The Bluetooth
%% domain takes the report filter, which hides the reason's terms.
format_status_takes_a_reason_alone_test() ->
    Status = #{reason => {badmatch, <<1, 2, 3>>}},
    [?assertMatch(#{reason := _}, Mod:format_status(Status)) || Mod <- [erx_bt_hci, erx_bt_link]].
