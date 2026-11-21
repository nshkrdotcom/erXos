%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of the Bluetooth store (docs/design-bluetooth.md, "Bonds and the store" and
%% "Host tests of the cores"): erx_bt_state's layout, erx_bt_state_file over a directory
%% of its own, and erx_bt_store against a scripted backend, a process that holds the
%% medium's blob and answers each get and put as the case scripts it (read or write,
%% unavailable, a blob that does not decode, a put that reaches the medium and answers
%% unavailable, no answer at all). Processes registered as the window (erx_bt_fs) and
%% spawned as links forward what the store sends them. The store's table is explored
%% over every start state, request, put answer and read answer.

-module(erx_bt_store_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(ADDRESS, <<2#11:2, 7:46>>).

%% ---------------------------------------------------------------- erx_bt_state

bond(N) ->
    #{identity => {public, <<0, 0, 0, 0, 0, N>>}, irk => <<(16#1000 + N):128>>, ltk => <<(16#2000 + N):128>>,
      level => authenticated, hash => <<>>, subscriptions => #{}}.

state(Bonds) -> #{address => ?ADDRESS, bonds => Bonds}.

blob(Bonds) ->
    {ok, Blob} = erx_bt_state:encode(state(Bonds)),
    Blob.

state_round_trips_test() ->
    Full = (bond(1))#{identity := {random, <<2#11:2, 5:46>>}, level := unauthenticated, hash := <<9:256>>,
                      subscriptions := #{{<<"nus">>, <<"tx">>} => notify, {<<"hid">>, <<"report_1">>} => indicate}},
    State = state([Full, bond(2)]),
    {ok, Blob} = erx_bt_state:encode(State),
    ?assertEqual({ok, State}, erx_bt_state:decode(Blob)),
    ?assertEqual({ok, state([])}, erx_bt_state:decode(blob([]))).

state_refuses_another_version_test() ->
    <<_, Rest/binary>> = blob([bond(1)]),
    ?assertEqual({error, {version, 2}}, erx_bt_state:decode(<<2, Rest/binary>>)),
    ?assertEqual({error, empty}, erx_bt_state:decode(<<>>)).

state_refuses_every_truncation_and_trailing_octet_test() ->
    Blob = blob([(bond(1))#{hash := <<1:256>>, subscriptions := #{{<<"nus">>, <<"tx">>} => notify}}, bond(2)]),
    [?assertMatch({error, _}, erx_bt_state:decode(binary:part(Blob, 0, N))) || N <- lists:seq(0, byte_size(Blob) - 1)],
    ?assertEqual({error, trailing}, erx_bt_state:decode(<<Blob/binary, 0>>)).

state_refuses_oversized_count_test() ->
    Nine = [bond(N) || N <- lists:seq(1, 9)],
    Blob = iolist_to_binary([1, ?ADDRESS, 9, [binary:part(B, 8, byte_size(B) - 8) || B <- [blob([Bd]) || Bd <- Nine]]]),
    ?assertEqual({error, {too_many_bonds, 9}}, erx_bt_state:decode(Blob)),
    ?assertEqual({error, too_large}, erx_bt_state:encode(state(Nine))).

state_refuses_malformed_fields_test() ->
    One = blob([bond(1)]),
    Field = fun(Offset, Octet) -> <<Head:Offset/binary, _, Tail/binary>> = One, <<Head/binary, Octet, Tail/binary>> end,
    ?assertEqual({error, {identity_type, 2}}, erx_bt_state:decode(Field(8, 2))),
    ?assertEqual({error, {level, 2}}, erx_bt_state:decode(Field(8 + 39, 2))),
    ?assertEqual({error, {hash_length, 31}}, erx_bt_state:decode(Field(8 + 40, 31))),
    ?assertEqual({error, header}, erx_bt_state:decode(<<1, 0:48, 0>>)),
    ?assertEqual({error, duplicate_identity}, erx_bt_state:decode(blob([bond(1), bond(1)]))),
    Two = blob([(bond(1))#{subscriptions := #{{<<"a">>, <<"x">>} => notify, {<<"b">>, <<"y">>} => notify}}]),
    Swapped = binary:replace(Two, <<1, 1, $a, 1, $x, 1, 1, $b, 1, $y>>, <<1, 1, $b, 1, $y, 1, 1, $a, 1, $x>>),
    ?assertEqual({error, subscription_order}, erx_bt_state:decode(Swapped)),
    Bad = (bond(1))#{subscriptions := #{{<<"Nus">>, <<"tx">>} => notify}},
    ?assertEqual({error, name}, erx_bt_state:decode(blob([Bad]))),
    ?assertEqual({error, too_large}, erx_bt_state:decode(<<One/binary, 0:(8 * ?ERX_BT_STATE_MAX)>>)).

%% Eight bonds, each with a hash and three subscriptions of the longest names, fit.
state_largest_fits_test() ->
    Long = fun(C) -> binary:copy(<<C>>, 63) end,
    Subs = #{{Long($a), Long($b)} => notify, {Long($c), Long($d)} => indicate, {Long($e), Long($f)} => notify},
    Bonds = [(bond(N))#{hash := <<N:256>>, subscriptions := Subs} || N <- lists:seq(1, 8)],
    {ok, Blob} = erx_bt_state:encode(state(Bonds)),
    ?assert(byte_size(Blob) =< ?ERX_BT_STATE_MAX).

%% ---------------------------------------------------------------- erx_bt_state_file

state_file_test() ->
    Root = string:trim(os:cmd("mktemp -d")),
    Dir = filename:join(Root, "bt"),
    ?assertEqual({error, unavailable}, erx_bt_state_file:get(filename:join([Root, "absent", "bt"]))),
    ?assertEqual(none, erx_bt_state_file:get(Dir)),
    ?assertEqual(ok, erx_bt_state_file:put(Dir, <<"one">>)),
    ?assertEqual({ok, <<"one">>}, erx_bt_state_file:get(Dir)),
    ?assertEqual(ok, erx_bt_state_file:put(Dir, <<"two">>)),
    ?assertEqual({ok, <<"two">>}, erx_bt_state_file:get(Dir)),
    ok = file:write_file(filename:join(Dir, "state"), binary:copy(<<0>>, 2 * ?ERX_BT_STATE_MAX)),
    {ok, Big} = erx_bt_state_file:get(Dir),
    ?assertEqual(?ERX_BT_STATE_MAX + 1, byte_size(Big)),
    ?assertEqual({error, unavailable}, erx_bt_state_file:put(filename:join([Root, "absent", "bt"]), <<"x">>)),
    {ok, Left} = file:list_dir(Dir),
    ?assertEqual(["state"], Left),
    os:cmd("rm -rf " ++ Root).

%% ---------------------------------------------------------------- the store

%% The scripted backend: Gets and Puts are the answers in order, then `read` and `ok`.
script(Medium, Gets, Puts) ->
    spawn(fun() -> script_loop(Medium, Gets, Puts) end).

script_loop(Medium, Gets, Puts) ->
    receive
        {get, From} ->
            {Step, Rest} = next(Gets, read),
            case Step of
                read when Medium =:= none -> From ! {script, none};
                read -> From ! {script, {ok, Medium}};
                unavailable -> From ! {script, {error, unavailable}};
                garbage -> From ! {script, {ok, <<"not a state">>}};
                hang -> ok
            end,
            script_loop(Medium, Rest, Puts);
        {put, Blob, From} ->
            {Step, Rest} = next(Puts, ok),
            {Answer, Kept} = case Step of
                                 ok -> {ok, Blob};
                                 lost -> {{error, unavailable}, Medium};
                                 landed -> {{error, unavailable}, Blob};
                                 too_large -> {{error, too_large}, Medium};
                                 hang -> {hang, Medium}
                             end,
            Answer =:= hang orelse (From ! {script, Answer}),
            script_loop(Kept, Gets, Rest);
        {medium, From} ->
            From ! {script, Medium},
            script_loop(Medium, Gets, Puts)
    end.

next([Step | Rest], _Default) -> {Step, Rest};
next([], Default) -> {Default, []}.

ask(Script, Message) ->
    Script ! Message,
    receive {script, Answer} -> Answer end.

medium(Script) ->
    case ask(Script, {medium, self()}) of
        none -> none;
        Blob -> {ok, State} = erx_bt_state:decode(Blob), State
    end.

start(Medium, Gets, Puts) -> start(Medium, Gets, Puts, 500).

start(Medium, Gets, Puts, Timeout) ->
    Script = script(Medium, Gets, Puts),
    Backend = #{get => fun() -> ask(Script, {get, self()}) end, put => fun(Blob) -> ask(Script, {put, Blob, self()}) end},
    Test = self(),
    is_pid(whereis(erx_bt_fs)) andalso exit(whereis(erx_bt_fs), kill),
    wait_unregistered(erx_bt_fs),
    register(erx_bt_fs, spawn(fun() -> forward(Test, window) end)),
    {ok, Store} = erx_bt_store:start_link(#{backend => Backend, timeout => Timeout}),
    unlink(Store),
    {Store, Script}.

stop(Store) ->
    Monitor = monitor(process, Store),
    exit(Store, kill),
    receive {'DOWN', Monitor, _, _, _} -> ok end,
    flush().

flush() -> receive _ -> flush() after 0 -> ok end.

forward(Test, Tag) ->
    receive Message -> Test ! {Tag, self(), Message}, forward(Test, Tag) end.

%% A link stand-in that forwards what the store sends it.
fake_link() ->
    Test = self(),
    spawn(fun() -> forward(Test, link) end).

paired(N) -> maps:with([identity, irk, ltk, level], bond(N)).

keep(Link, N) ->
    erx_bt_store ! {erx_bt_link, Link, {keep, 7, paired(N), #{{nus, tx} => notify, {nus, rx} => none}}}.

kept(Link) ->
    receive {link, Link, {store, {kept, Answer}}} -> Answer after 7000 -> no_answer end.

outcome(Link) ->
    receive {window, _, {outcome, Link, 7, Outcome}} -> Outcome after 1000 -> no_outcome end.

identities(none) -> [];
identities(#{bonds := Bonds}) -> [Identity || #{identity := Identity} <- Bonds].

start_reading_none_makes_the_address_test() ->
    {Store, Script} = start(none, [], []),
    #{store := read, reason := none, bonds := [], address := <<2#11:2, _:46>> = Address} = erx_bt_store:facts(),
    ?assertEqual(Address, erx_bt_store:address()),
    Link = fake_link(),
    keep(Link, 1),
    ?assertEqual(ok, kept(Link)),
    ?assertEqual(#{address => Address, bonds => [(bond(1))#{subscriptions := #{{<<"nus">>, <<"tx">>} => notify}}]},
                 medium(Script)),
    stop(Store).

start_reading_a_state_takes_its_address_and_bonds_test() ->
    {Store, _} = start(blob([bond(1)]), [], []),
    ?assertMatch(#{store := read, address := ?ADDRESS, bonds := [{{public, <<0, 0, 0, 0, 0, 1>>}, authenticated}]},
                 erx_bt_store:facts()),
    stop(Store).

%% A start that cannot read runs without bonds and refuses every change but `forget all`,
%% which replaces the blob under the address in use.
start_unreadable_refuses_changes_until_forget_all_test_() ->
    [fun() -> start_unread(Get, Reason) end || {Get, Reason} <- [{unavailable, store_unavailable},
                                                                {garbage, store_unreadable}]].

start_unread(Get, Reason) ->
    {Store, Script} = start(blob([bond(1)]), [Get], []),
    #{store := unknown, reason := Reason, bonds := [], address := Address} = erx_bt_store:facts(),
    ?assertNotEqual(?ADDRESS, Address),
    ?assertEqual(none, erx_bt_store:resolve({public, <<0, 0, 0, 0, 0, 1>>})),
    Link = fake_link(),
    keep(Link, 2),
    ?assertEqual({error, unavailable}, kept(Link)),
    ?assertEqual({failed, unavailable}, outcome(Link)),
    ?assertEqual({error, eio}, erx_bt_store:forget(<<0, 0, 0, 0, 0, 1>>)),
    ?assertEqual([{public, <<0, 0, 0, 0, 0, 1>>}], identities(medium(Script))),
    ?assertEqual(ok, erx_bt_store:forget(all)),
    ?assertEqual(#{address => Address, bonds => []}, medium(Script)),
    ?assertMatch(#{store := read, reason := none}, erx_bt_store:facts()),
    stop(Store).

%% A put that reached the medium and answered unavailable fails its pairing; the next
%% pairing reads first and keeps both bonds.
unconfirmed_put_reads_before_the_next_change_test() ->
    {Store, Script} = start(blob([]), [], [landed]),
    First = fake_link(),
    keep(First, 1),
    ?assertEqual({error, unavailable}, kept(First)),
    ?assertEqual({failed, unavailable}, outcome(First)),
    ?assertMatch(#{store := unknown, reason := store_unavailable, bonds := []}, erx_bt_store:facts()),
    Second = fake_link(),
    keep(Second, 2),
    ?assertEqual(ok, kept(Second)),
    ?assertEqual([identity(1), identity(2)], identities(medium(Script))),
    ?assertEqual(identities(medium(Script)), [I || {I, _} <- maps:get(bonds, erx_bt_store:facts())]),
    stop(Store).

identity(N) -> maps:get(identity, bond(N)).

keep_of_a_dead_link_still_reaches_the_window_test() ->
    {Store, Script} = start(none, [], []),
    Link = spawn(fun() -> ok end),
    Monitor = monitor(process, Link),
    receive {'DOWN', Monitor, _, _, _} -> ok end,
    keep(Link, 1),
    ?assertEqual({bonded, identity(1), authenticated}, outcome(Link)),
    ?assertEqual([identity(1)], identities(medium(Script))),
    ?assertMatch(#{links := 0}, erx_bt_store:facts()),
    stop(Store).

keep_refuses_a_kept_identity_and_a_ninth_bond_test() ->
    {Store, Script} = start(blob([bond(N) || N <- lists:seq(1, 8)]), [], []),
    Link = fake_link(),
    keep(Link, 3),
    ?assertEqual({error, already_bonded}, kept(Link)),
    ?assertEqual({failed, already_bonded}, outcome(Link)),
    keep(Link, 9),
    ?assertEqual({error, bonds_full}, kept(Link)),
    ?assertEqual({failed, bonds_full}, outcome(Link)),
    ?assertEqual(8, length(identities(medium(Script)))),
    stop(Store).

%% A resolvable private address with the top bits 01, prand above and ah(IRK, prand) below.
private_address(Irk, Prand) ->
    {random, <<Prand/binary, (erx_smp_crypto:ah(Irk, Prand))/binary>>}.

resolve_answers_one_bond_without_any_irk_test() ->
    Zero = (bond(3))#{irk := <<0:128>>},
    Subscribed = (bond(2))#{hash := <<5:256>>, subscriptions := #{{<<"nus">>, <<"tx">>} => indicate,
                                                                  {<<"no_such_service_zz">>, <<"tx">>} => notify}},
    {Store, _} = start(blob([bond(1), Subscribed, Zero]), [], []),
    #{irk := Irk2} = Subscribed,
    Prand = <<2#01:2, 12345:22>>,
    Answer = erx_bt_store:resolve(private_address(Irk2, Prand)),
    ?assertEqual(#{ltk => maps:get(ltk, Subscribed), level => authenticated, identity => identity(2),
                   hash => <<5:256>>, subscriptions => #{{nus, tx} => indicate}}, Answer),
    ?assertEqual(Answer, erx_bt_store:resolve(identity(2))),
    ?assertEqual(none, erx_bt_store:resolve(private_address(<<0:128>>, Prand))),
    ?assertEqual(none, erx_bt_store:resolve({random, <<Prand/binary, 0:24>>})),
    ?assertEqual(none, erx_bt_store:resolve({random, <<0, 0, 0, 0, 0, 2>>})),
    Wire = term_to_binary(Answer),
    [?assertEqual(nomatch, binary:match(Wire, Irk)) || #{irk := Irk} <- [bond(1), Subscribed, Zero], Irk =/= <<0:128>>],
    stop(Store).

%% Forgetting a bond ends the link whose address resolved to it at its start.
forget_ends_the_links_of_that_bond_test() ->
    {Store, Script} = start(blob([bond(1), bond(2)]), [], []),
    Test = self(),
    Resolver = fun(N) -> spawn(fun() -> _ = erx_bt_store:resolve(identity(N)), forward(Test, link) end) end,
    One = Resolver(1),
    Two = Resolver(2),
    wait_links(2),
    ?assertEqual({error, enoent}, erx_bt_store:forget(<<0, 0, 0, 0, 0, 9>>)),
    ?assertEqual(ok, erx_bt_store:forget(<<0, 0, 0, 0, 0, 1>>)),
    receive {link, One, {store, forgotten}} -> ok after 2000 -> error(not_forgotten) end,
    receive {link, Two, {store, forgotten}} -> error(other_forgotten) after 100 -> ok end,
    ?assertEqual([identity(2)], identities(medium(Script))),
    ?assertMatch(#{links := 1}, erx_bt_store:facts()),
    exit(Two, kill),
    wait_links(0),
    stop(Store).

wait_links(N) ->
    case erx_bt_store:facts() of
        #{links := N} -> ok;
        _ -> timer:sleep(10), wait_links(N)
    end.

subscriptions_and_served_change_the_links_bond_test() ->
    {Store, Script} = start(blob([bond(1)]), [], [ok, ok, lost]),
    Test = self(),
    Link = spawn(fun() -> _ = erx_bt_store:resolve(identity(1)), forward(Test, link) end),
    wait_links(1),
    erx_bt_store ! {erx_bt_link, Link, {subscriptions, #{{nus, tx} => indicate}}},
    ?assertEqual(ok, kept(Link)),
    erx_bt_store ! {erx_bt_link, Link, {served, <<3:256>>}},
    #{bonds := [Bond]} = (fun W() -> case medium(Script) of #{bonds := [#{hash := <<3:256>>}]} = M -> M;
                                                            _ -> timer:sleep(10), W() end end)(),
    ?assertEqual(#{{<<"nus">>, <<"tx">>} => indicate}, maps:get(subscriptions, Bond)),
    erx_bt_store ! {erx_bt_link, Link, {subscriptions, #{}}},
    ?assertEqual({error, unavailable}, kept(Link)),
    Stranger = fake_link(),
    erx_bt_store ! {erx_bt_link, Stranger, {subscriptions, #{}}},
    ?assertEqual({error, unavailable}, kept(Stranger)),
    stop(Store).

%% Every backend call ends at bt_store_timeout_ms itself: a get at the start, a put of a
%% pairing, whose window still hears the outcome.
backend_that_never_answers_test_() ->
    {timeout, 30, fun() ->
        T0 = erlang:monotonic_time(millisecond),
        {Hung, _} = start(blob([bond(1)]), [hang], [], ?ERX_BT_STORE_TIMEOUT_MS),
        ?assert(erlang:monotonic_time(millisecond) - T0 >= ?ERX_BT_STORE_TIMEOUT_MS),
        ?assertMatch(#{store := unknown, reason := store_unavailable}, erx_bt_store:facts()),
        stop(Hung),
        {Store, _} = start(blob([]), [], [hang], ?ERX_BT_STORE_TIMEOUT_MS),
        Link = fake_link(),
        keep(Link, 1),
        ?assertEqual({error, unavailable}, kept(Link)),
        ?assertEqual({failed, unavailable}, outcome(Link)),
        ?assertMatch(#{store := unknown, reason := store_unavailable}, erx_bt_store:facts()),
        stop(Store)
    end}.

%% Neither the status nor a raise's reason shows a key.
no_key_in_status_or_crash_test() ->
    {Store, _} = start(blob([bond(1), bond(2)]), [], []),
    Status = term_to_binary(sys:get_status(erx_bt_store)),
    Keys = lists:append([[Irk, Ltk] || #{irk := Irk, ltk := Ltk} <- [bond(1), bond(2)]]),
    [?assertEqual(nomatch, binary:match(Status, Key)) || Key <- Keys],
    Monitor = monitor(process, Store),
    erx_bt_store ! {erx_bt_link, self(), {keep, 1, paired(1), not_a_map}},
    Reason = receive {'DOWN', Monitor, _, _, R} -> R after 2000 -> no_exit end,
    ?assertMatch({shutdown, {raised, error, #{store := read}}}, Reason),
    [?assertEqual(nomatch, binary:match(term_to_binary(Reason), Key)) || Key <- Keys],
    flush().

%% The store's table, explored: every start state, request, put answer and read answer.
%% After each request the answer is the model's, and a read store's bonds are the
%% medium's.
explored_store_table_test_() ->
    {timeout, 120, fun() ->
        [explore(Known, Request, Put, Reread)
         || Known <- [read, unknown_start, unknown_put],
            Request <- [keep_new, keep_kept, forget_one, forget_missing, forget_all],
            Put <- [ok, lost, landed],
            Reread <- [read, unavailable, garbage]]
    end}.

explore(Known, Request, Put, Reread) ->
    {Gets, Puts} = case Known of
                       read -> {[], [Put]};
                       unknown_start -> {[unavailable], [Put]};
                       unknown_put -> {[read, Reread], [lost, Put]}
                   end,
    {Store, Script} = start(blob([bond(1)]), Gets, Puts),
    Known =:= unknown_put andalso begin L = fake_link(), keep(L, 9), {error, unavailable} = kept(L) end,
    Answer = request(Request),
    Expected = model(Known, Request, Put, Reread),
    Case = {Known, Request, Put, Reread},
    ?assertEqual({Case, Expected}, {Case, Answer}),
    #{store := Store1, bonds := Bonds} = erx_bt_store:facts(),
    Store1 =:= read andalso ?assertEqual({Case, identities(medium(Script))}, {Case, [I || {I, _} <- Bonds]}),
    stop(Store).

request(keep_new) -> L = fake_link(), keep(L, 2), {kept(L), outcome(L)};
request(keep_kept) -> L = fake_link(), keep(L, 1), {kept(L), outcome(L)};
request(forget_one) -> erx_bt_store:forget(<<0, 0, 0, 0, 0, 1>>);
request(forget_missing) -> erx_bt_store:forget(<<0, 0, 0, 0, 0, 5>>);
request(forget_all) -> erx_bt_store:forget(all).

%% The model of "Bonds and the store": whether the change may start, its edit, then its put.
model(Known, Request, Put, Reread) ->
    Starts = case Known of
                 _ when Request =:= forget_all -> true;
                 read -> true;
                 unknown_start -> false;
                 unknown_put -> Reread =:= read
             end,
    Edit = case Request of
               keep_kept -> {error, already_bonded};
               forget_missing -> {error, enoent};
               _ -> ok
           end,
    Result = if not Starts -> {error, unavailable};
                Edit =/= ok -> Edit;
                Put =:= ok -> ok;
                true -> {error, unavailable}
             end,
    case Request of
        keep_new -> {Result, outcome(Result, 2)};
        keep_kept -> {Result, outcome(Result, 1)};
        _ -> forget_answer(Result)
    end.

outcome(ok, N) -> {bonded, identity(N), authenticated};
outcome({error, Reason}, _) -> {failed, Reason}.

forget_answer({error, unavailable}) -> {error, eio};
forget_answer(Result) -> Result.

wait_unregistered(Name) ->
    case whereis(Name) of
        undefined -> ok;
        _ -> timer:sleep(1), wait_unregistered(Name)
    end.

%% A forget all that fails after an unread start leaves the store as the start left it:
%% the next pairing is refused rather than read the old bonds under this start's address.
failed_forget_all_after_an_unread_start_changes_nothing_test() ->
    {Store, Script} = start(blob([bond(1)]), [unavailable], [lost]),
    ?assertEqual({error, eio}, erx_bt_store:forget(all)),
    Link = fake_link(),
    keep(Link, 2),
    ?assertEqual({error, unavailable}, kept(Link)),
    ?assertEqual(#{address => ?ADDRESS, bonds => [bond(1)]}, medium(Script)),
    ?assertMatch(#{store := unknown}, erx_bt_store:facts()),
    stop(Store).

%% Kept bonds still resolve after a put the store could not confirm, as on a trial boot.
kept_bonds_resolve_after_an_unconfirmed_put_test() ->
    {Store, _} = start(blob([bond(1)]), [], [lost]),
    Link = fake_link(),
    keep(Link, 2),
    ?assertEqual({error, unavailable}, kept(Link)),
    ?assertMatch(#{store := unknown}, erx_bt_store:facts()),
    ?assertMatch(#{identity := {public, <<0, 0, 0, 0, 0, 1>>}}, erx_bt_store:resolve(identity(1))),
    stop(Store).
