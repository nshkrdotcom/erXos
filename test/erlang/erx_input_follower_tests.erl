%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_input_follower over model grants and readers (docs/design-display.md, "The display
%% device"; docs/design-system.md, "Waiting for a grant"): a grant that arrives late is
%% followed at the installation of its facet, with no look on a timer; a grant that ends
%% has its readers stopped, and all of them have ended before its re-grant starts
%% replacements, whether the end comes before or after the re-grant's installation; an
%% ended facet is not followed again at the installation of another name; a ready answer
%% that lands between the follower's reads is not missed; two trees are followed
%% independently, so one whose server never answers its listing holds up nothing of the
%% other; a listing that fails is tried again on the same grant; and a reader that ends
%% by itself is not replaced. A model server is a process that answers a listing with its
%% files, or never; a model reader is a process that ends when told to; the model agent
%% answers a request for word of an installation as the connection agent does, a second
%% request of the same process answering its first.
-module(erx_input_follower_tests).

-include_lib("eunit/include/eunit.hrl").

%% Long enough for the follower to act on what it was told.
-define(QUIET_MS, 200).
%% Long enough for the follower's retry of a failed listing, a second.
-define(RETRY_WAIT_MS, 1500).

%% The model's state: the granted names, each name's grant as the registry holds it, the
%% registry's generation, the model agent, and every reader started, by device name.
-define(GRANTED, {?MODULE, granted}).
-define(GRANTS, {?MODULE, grants}).
-define(GENERATION, {?MODULE, generation}).
-define(AGENT, {?MODULE, agent}).
-define(READERS, {?MODULE, readers}).
-define(FOLLOWER, {?MODULE, follower}).

setup() ->
    %% What an earlier case's follower told the process that runs the cases.
    _ = {listings(), started(0)},
    persistent_term:put(?GRANTED, []),
    persistent_term:put(?GRANTS, #{}),
    persistent_term:put(?GENERATION, 0),
    Agent = spawn(fun() -> agent(#{}, 0) end),
    persistent_term:put(?AGENT, Agent),
    Test = self(),
    {ok, Follower} = erx_input_follower:start_link(
                       #{generation => fun() -> read(?GENERATION, after_generation) end,
                         granted => fun() -> read(?GRANTED, after_names) end,
                         changed => fun(Generation) -> gen:send_request(Agent, '$gen_call', {changed, Generation}) end,
                         resolve => fun(Name) ->
                                            case persistent_term:get(?GRANTS) of
                                                #{Name := Server} -> {ok, {Server, atom_to_binary(Name), ro}};
                                                #{} -> {error, enoent}
                                            end
                                    end,
                         list => fun(Grant) -> list(Test, Grant) end,
                         start => fun(Device, {Server, _, ro}, _File) -> reader(Test, Device, Server) end}),
    unlink(Follower),
    persistent_term:put(?FOLLOWER, Follower),
    Follower.

%% The follower stopped as its supervisor stops it, which stops its readers, or killed when
%% a seeded fault leaves it waiting on a listing.
cleanup(Follower) ->
    case catch gen_server:stop(Follower, shutdown, 1000) of
        ok -> ok;
        _ -> exit(Follower, kill)
    end,
    exit(persistent_term:get(?AGENT), kill),
    [persistent_term:erase(Key) || Key <- [?GRANTED, ?GRANTS, ?GENERATION, ?AGENT, ?READERS, ?FOLLOWER,
                                           {?MODULE, after_generation}, {?MODULE, after_names}]].

%% Each case starts its follower in the process that runs it, which the model readers and
%% listings tell of their starts.
follower_test_() ->
    [{Title, fun() -> Follower = setup(), try Case() after cleanup(Follower) end end}
     || {Title, Case} <- [{"a late grant", fun a_grant_that_arrives_late_is_followed_once_installed/0},
                          {"a grant's return", fun a_grant_that_ends_stops_its_readers_before_its_return_starts_more/0},
                          {"a re-grant before the end", fun a_re_grant_installed_before_the_end_replaces_the_readers/0},
                          {"an ended facet", fun an_ended_facet_is_not_followed_again/0},
                          {"the ready answer between reads", fun a_ready_answer_between_the_reads_is_not_missed/0},
                          {"two trees", fun two_trees_are_followed_independently/0},
                          {"a reader's end", fun a_reader_that_ends_by_itself_is_not_replaced/0},
                          {"a lister's crash", fun a_lister_that_crashes_is_listed_again/0},
                          {"a listing retried", fun a_failed_listing_is_retried_on_the_same_grant/0}]].

%% No name, then a name whose facet is not installed, start nothing; the installed facet
%% starts one reader per file, named Facet/File.
a_grant_that_arrives_late_is_followed_once_installed() ->
    ?assertEqual([], started(?QUIET_MS)),
    ready([kbd]),
    ?assertEqual([], started(?QUIET_MS)),
    _ = install(kbd, [<<"hid0">>, <<"hid1">>]),
    ?assertEqual([<<"kbd/hid0">>, <<"kbd/hid1">>], devices(started(?QUIET_MS))).

%% The grant's server ends: its readers end. Its return under the same name starts new
%% readers, and when each starts, no reader of the old grant still runs.
a_grant_that_ends_stops_its_readers_before_its_return_starts_more() ->
    ready([kbd]),
    Server = install(kbd, [<<"hid0">>, <<"hid1">>]),
    Old = started(?QUIET_MS),
    ?assertEqual(2, length(Old)),
    exit(Server, kill),
    ?assertEqual([], started(?QUIET_MS)),
    New = install(kbd, [<<"hid0">>, <<"hid1">>]),
    Replacements = started(?QUIET_MS),
    ?assertEqual([<<"kbd/hid0">>, <<"kbd/hid1">>], devices(Replacements)),
    ?assertEqual([New, New], [S || {_, _, S, _} <- Replacements]),
    ?assertEqual([[], []], [Live || {_, _, _, Live} <- Replacements]),
    ?assertEqual([], [Pid || {_, Pid, _, _} <- Old, is_process_alive(Pid)]).

%% The re-grant is installed while the old server still runs: the old readers are stopped
%% before the new ones start, and the old server's end afterwards starts nothing.
a_re_grant_installed_before_the_end_replaces_the_readers() ->
    ready([kbd]),
    Server = install(kbd, [<<"hid0">>]),
    [{_, OldReader, Server, []}] = started(?QUIET_MS),
    New = install(kbd, [<<"hid0">>]),
    ?assertEqual([{<<"kbd/hid0">>, New, []}], [{D, S, L} || {D, _, S, L} <- started(?QUIET_MS)]),
    ?assertNot(is_process_alive(OldReader)),
    exit(Server, kill),
    ?assertEqual([], started(?QUIET_MS)).

%% The followed server ends and no re-grant comes: the installation of another name lists
%% that one alone, never the ended facet again, which the follower keeps as the one it
%% last followed. A listing of the ended facet may be stopped before it tells the test,
%% so the case reads the kept facet in the follower's state.
an_ended_facet_is_not_followed_again() ->
    ready([kbd, mouse]),
    Server = install(kbd, [<<"hid0">>]),
    [_] = started(?QUIET_MS),
    ?assertEqual([Server], listings()),
    exit(Server, kill),
    ?assertEqual([], started(?QUIET_MS)),
    Mouse = install(mouse, [<<"hid0">>]),
    ?assertEqual([<<"mouse/hid0">>], devices(started(?QUIET_MS))),
    ?assertEqual([Mouse], listings()),
    #{trees := #{kbd := Kbd}} = sys:get_state(persistent_term:get(?FOLLOWER)),
    ?assertEqual(#{grant => {Server, <<"kbd">>, ro}, phase => ended}, Kbd).

%% The ready answer, its names and the input facet, installed after the follower read the
%% generation and then after it read the names, each woken by another installation: the
%% tree is followed either way.
a_ready_answer_between_the_reads_is_not_missed() ->
    lists:foreach(fun({Point, Name, Names}) ->
                          persistent_term:put({?MODULE, Point}, fun() -> ready(Names), install(Name, [<<"hid0">>]) end),
                          _ = install(other, never),
                          Device = <<(atom_to_binary(Name))/binary, "/hid0">>,
                          ?assertEqual({Point, [Device]}, {Point, devices(started(?QUIET_MS))})
                  end, [{after_generation, kbd, [kbd]}, {after_names, mouse, [kbd, mouse]}]).

%% mouse's server never answers its listing; kbd's readers start all the same, though
%% mouse is looked at first, and the end of mouse's grant leaves them running.
two_trees_are_followed_independently() ->
    ready([mouse, kbd]),
    Mouse = install(mouse, never),
    _ = install(kbd, [<<"hid0">>]),
    [{<<"kbd/hid0">>, Reader, _, _}] = started(?QUIET_MS),
    exit(Mouse, kill),
    ?assertEqual([], started(?QUIET_MS)),
    ?assert(is_process_alive(Reader)).

%% A reader that ends, at its file's end, is not started again while its grant lasts; and
%% the follower asks the agent once as it starts and at most once after each
%% installation, whatever else it hears, so it keeps one request outstanding.
a_reader_that_ends_by_itself_is_not_replaced() ->
    ready([kbd]),
    _ = install(kbd, [<<"hid0">>, <<"hid1">>]),
    [{_, First, _, _}, {_, Second, _, _}] = started(?QUIET_MS),
    First ! eof,
    ?assertEqual([], started(?QUIET_MS)),
    ?assertNot(is_process_alive(First)),
    ?assert(is_process_alive(Second)),
    ?assert(requests() =< persistent_term:get(?GENERATION) + 1).

%% A listing that raises ends its lister without a listing: the tree is listed again and
%% listed by the next server, and the end of the first grant blocks nothing.
a_lister_that_crashes_is_listed_again() ->
    ready([kbd]),
    Crashing = install(kbd, crash),
    ?assertEqual([], started(?QUIET_MS)),
    _ = install(kbd, [<<"hid0">>]),
    exit(Crashing, kill),
    ?assertEqual([<<"kbd/hid0">>], devices(started(?QUIET_MS))).

%% A server that fails its first listing and answers the next: the tree is listed again a
%% second later on the same grant, with no installation, and its readers start.
a_failed_listing_is_retried_on_the_same_grant() ->
    ready([kbd]),
    Server = install(kbd, {fail_once, [<<"hid0">>]}),
    ?assertEqual([], started(?QUIET_MS)),
    ?assertEqual([{<<"kbd/hid0">>, Server}], [{D, S} || {D, _, S, _} <- started(?RETRY_WAIT_MS)]),
    ?assertEqual([Server, Server], listings()).

%% The ready answer naming Names: the granted names written, then the generation raised
%% and its waiters answered, as the connection agent does.
ready(Names) ->
    persistent_term:put(?GRANTED, Names),
    installed().

%% A model server of Files, or one that never answers a listing, installed as Name's grant.
install(Name, Files) ->
    Server = spawn(fun() -> serve(Files) end),
    persistent_term:put(?GRANTS, (persistent_term:get(?GRANTS))#{Name => Server}),
    installed(),
    Server.

installed() ->
    persistent_term:put(?GENERATION, persistent_term:get(?GENERATION) + 1),
    persistent_term:get(?AGENT) ! installed.

%% The model agent: answers each request once the generation is past the one it names,
%% at once when it already is, and a second request of the same process answers its
%% first; counts the requests.
agent(Waiting, Requests) ->
    receive
        {'$gen_call', {Pid, _} = From, {changed, Generation}} ->
            case persistent_term:get(?GENERATION) > Generation of
                true ->
                    gen:reply(From, ok),
                    agent(Waiting, Requests + 1);
                false ->
                    _ = [gen:reply(Older, ok) || #{Pid := Older} <- [Waiting]],
                    agent(Waiting#{Pid => From}, Requests + 1)
            end;
        installed ->
            _ = [gen:reply(From, ok) || _ := From <- Waiting],
            agent(#{}, Requests);
        {requests, Test} ->
            Test ! {requests, Requests},
            agent(Waiting, Requests)
    end.

requests() ->
    persistent_term:get(?AGENT) ! {requests, self()},
    receive {requests, Requests} -> Requests end.

%% A model value read by the follower, then the case's one-shot hook at Point, if any.
read(Key, Point) ->
    Value = persistent_term:get(Key),
    case persistent_term:get({?MODULE, Point}, none) of
        none -> ok;
        Hook -> persistent_term:erase({?MODULE, Point}), Hook()
    end,
    Value.

serve(Files) ->
    receive
        {list, From, Ref} when Files =:= crash -> From ! {Ref, crash}, serve(Files);
        {list, _From, _Ref} when Files =:= never -> serve(Files);
        {list, From, Ref} ->
            case Files of
                {fail_once, Next} -> From ! {Ref, {error, eagain}}, serve(Next);
                _ -> From ! {Ref, {ok, Files}}, serve(Files)
            end
    end.

%% A listing of the tree on Grant, which tells the test of it first.
list(Test, {Server, _Tree, ro}) ->
    Test ! {listing, Server},
    Ref = erlang:monitor(process, Server),
    Server ! {list, self(), Ref},
    receive
        {Ref, crash} -> error(crash);
        {Ref, Listing} -> erlang:demonitor(Ref, [flush]), Listing;
        {'DOWN', Ref, process, _, Reason} -> {error, Reason}
    end.

%% A model reader of Device, linked to the follower, which tells the test it started, with
%% the readers of the same device that still run as it starts, and ends at eof.
reader(Test, Device, Server) ->
    Live = [Pid || {D, Pid} <- persistent_term:get(?READERS, []), D =:= Device, is_process_alive(Pid)],
    Reader = spawn_link(fun() -> receive eof -> ok end end),
    persistent_term:put(?READERS, [{Device, Reader} | persistent_term:get(?READERS, [])]),
    Test ! {started, Device, Reader, Server, Live},
    Reader.

%% The readers started within Ms, in order of device, each {Device, Pid, Server, Live}.
started(Ms) ->
    lists:sort(started(Ms, [])).

started(Ms, Acc) ->
    receive
        {started, Device, Reader, Server, Live} -> started(Ms, [{Device, Reader, Server, Live} | Acc])
    after Ms ->
            Acc
    end.

%% The servers whose trees were listed since the last call, in order of their listings.
listings() ->
    receive
        {listing, Server} -> [Server | listings()]
    after 0 ->
            []
    end.

devices(Started) -> [Device || {Device, _, _, _} <- Started].
