%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_input_follower over model grants and readers (docs/design-display.md, "The display
%% device"): a grant that arrives late is followed once its facet is installed; a grant
%% that ends has its readers stopped, and all of them have ended before its return starts
%% replacements; two trees are followed independently, so one whose server never answers
%% its listing holds up nothing of the other; and a reader that ends by itself is not
%% replaced. A model server is a process that answers a listing with its files, or never;
%% a model reader is a process that ends when told to.
-module(erx_input_follower_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LOOK_MS, 20).
%% Long enough for several looks.
-define(QUIET_MS, 200).

%% The model's state: the granted names, each name's grant as the registry holds it, and
%% every reader started, by device name.
-define(GRANTED, {?MODULE, granted}).
-define(GRANTS, {?MODULE, grants}).

setup() ->
    persistent_term:put(?GRANTED, []),
    persistent_term:put(?GRANTS, #{}),
    Test = self(),
    {ok, Follower} = erx_input_follower:start_link(
                       #{granted => fun() -> persistent_term:get(?GRANTED) end,
                         resolve => fun(Name) ->
                                            case persistent_term:get(?GRANTS) of
                                                #{Name := Server} -> {ok, {Server, atom_to_binary(Name), ro}};
                                                #{} -> {error, enoent}
                                            end
                                    end,
                         list => fun list/1,
                         start => fun(Device, {Server, _, ro}, _File) -> reader(Test, Device, Server) end,
                         look_ms => ?LOOK_MS}),
    unlink(Follower),
    Follower.

%% The follower stopped as its supervisor stops it, which stops its readers, or killed when
%% a seeded fault leaves it waiting on a listing.
cleanup(Follower) ->
    case catch gen_server:stop(Follower, shutdown, 1000) of
        ok -> ok;
        _ -> exit(Follower, kill)
    end,
    persistent_term:erase(?GRANTED),
    persistent_term:erase(?GRANTS),
    persistent_term:erase({?MODULE, readers}).

%% Each case starts its follower in the process that runs it, which the model readers tell
%% of their starts.
follower_test_() ->
    [{Title, fun() -> Follower = setup(), try Case() after cleanup(Follower) end end}
     || {Title, Case} <- [{"a late grant", fun a_grant_that_arrives_late_is_followed_once_installed/0},
                          {"a grant's return", fun a_grant_that_ends_stops_its_readers_before_its_return_starts_more/0},
                          {"two trees", fun two_trees_are_followed_independently/0},
                          {"a reader's end", fun a_reader_that_ends_by_itself_is_not_replaced/0},
                          {"a lister's crash", fun a_lister_that_crashes_is_listed_again/0}]].

%% No name, then a name whose facet is not installed, start nothing; the installed facet
%% starts one reader per file, named Facet/File.
a_grant_that_arrives_late_is_followed_once_installed() ->
    ?assertEqual([], started(?QUIET_MS)),
    persistent_term:put(?GRANTED, [kbd]),
    ?assertEqual([], started(?QUIET_MS)),
    _ = install(kbd, [<<"hid0">>, <<"hid1">>]),
    ?assertEqual([<<"kbd/hid0">>, <<"kbd/hid1">>], devices(started(?QUIET_MS))).

%% The grant's server ends: its readers end. Its return under the same name starts new
%% readers, and when each starts, no reader of the old grant still runs.
a_grant_that_ends_stops_its_readers_before_its_return_starts_more() ->
    persistent_term:put(?GRANTED, [kbd]),
    Server = install(kbd, [<<"hid0">>, <<"hid1">>]),
    Old = started(?QUIET_MS),
    ?assertEqual(2, length(Old)),
    exit(Server, kill),
    New = install(kbd, [<<"hid0">>, <<"hid1">>]),
    Replacements = started(?QUIET_MS),
    ?assertEqual([<<"kbd/hid0">>, <<"kbd/hid1">>], devices(Replacements)),
    ?assertEqual([New, New], [S || {_, _, S, _} <- Replacements]),
    ?assertEqual([[], []], [Live || {_, _, _, Live} <- Replacements]),
    ?assertEqual([], [Pid || {_, Pid, _, _} <- Old, is_process_alive(Pid)]).

%% mouse's server never answers its listing; kbd's readers start all the same, though
%% mouse is looked at first, and the end of mouse's grant leaves them running.
two_trees_are_followed_independently() ->
    persistent_term:put(?GRANTED, [mouse, kbd]),
    Mouse = install(mouse, never),
    _ = install(kbd, [<<"hid0">>]),
    [{<<"kbd/hid0">>, Reader, _, _}] = started(?QUIET_MS),
    exit(Mouse, kill),
    ?assertEqual([], started(?QUIET_MS)),
    ?assert(is_process_alive(Reader)).

%% A reader that ends, at its file's end, is not started again while its grant lasts.
a_reader_that_ends_by_itself_is_not_replaced() ->
    persistent_term:put(?GRANTED, [kbd]),
    _ = install(kbd, [<<"hid0">>, <<"hid1">>]),
    [{_, First, _, _}, {_, Second, _, _}] = started(?QUIET_MS),
    First ! eof,
    ?assertEqual([], started(?QUIET_MS)),
    ?assertNot(is_process_alive(First)),
    ?assert(is_process_alive(Second)).

%% A listing that raises ends its lister without a listing: the tree is looked at again
%% and listed by the next server, and the end of the first grant blocks nothing.
a_lister_that_crashes_is_listed_again() ->
    persistent_term:put(?GRANTED, [kbd]),
    Crashing = install(kbd, crash),
    ?assertEqual([], started(?QUIET_MS)),
    _ = install(kbd, [<<"hid0">>]),
    exit(Crashing, kill),
    ?assertEqual([<<"kbd/hid0">>], devices(started(?QUIET_MS))).

%% A model server of Files, or one that never answers a listing, installed as Name's grant.
install(Name, Files) ->
    Server = spawn(fun() -> serve(Files) end),
    persistent_term:put(?GRANTS, (persistent_term:get(?GRANTS))#{Name => Server}),
    Server.

serve(Files) ->
    receive
        {list, From, Ref} when Files =:= crash -> From ! {Ref, crash}, serve(Files);
        {list, From, Ref} when Files =/= never -> From ! {Ref, Files}, serve(Files);
        {list, _From, _Ref} -> serve(Files)
    end.

list({Server, _Tree, ro}) ->
    Ref = erlang:monitor(process, Server),
    Server ! {list, self(), Ref},
    receive
        {Ref, crash} -> error(crash);
        {Ref, Files} -> erlang:demonitor(Ref, [flush]), {ok, Files};
        {'DOWN', Ref, process, _, Reason} -> {error, Reason}
    end.

%% A model reader of Device, linked to the follower, which tells the test it started, with
%% the readers of the same device that still run as it starts, and ends at eof.
reader(Test, Device, Server) ->
    Live = [Pid || {D, Pid} <- persistent_term:get({?MODULE, readers}, []), D =:= Device, is_process_alive(Pid)],
    Reader = spawn_link(fun() -> receive eof -> ok end end),
    persistent_term:put({?MODULE, readers}, [{Device, Reader} | persistent_term:get({?MODULE, readers}, [])]),
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

devices(Started) -> [Device || {Device, _, _, _} <- Started].
