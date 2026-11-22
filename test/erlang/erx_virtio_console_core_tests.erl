%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_virtio_console_core, the transmit side of the virtio-console line
%% driver (docs/design-bluetooth.md, "The line on QEMU `virt`"). The device returns
%% buffers in whatever order it likes, so the last case explores random writes against
%% random return orders, from fixed seeds so a failure repeats.
-module(erx_virtio_console_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SIZE, 4).
-define(PIECE, 8).

a_write_is_cut_into_pieces_in_order_test() ->
    Ref = make_ref(),
    {[], C0} = erx_virtio_console_core:write(Ref, <<"0123456789abcdefXY">>, new()),
    {Posts, _} = erx_virtio_console_core:posts(C0),
    ?assertEqual([<<"01234567">>, <<"89abcdef">>, <<"XY">>], [Piece || {_Tag, Piece} <- Posts]).

posts_never_exceed_the_queue_size_test() ->
    {[], C0} = erx_virtio_console_core:write(make_ref(), binary:copy(<<"z">>, ?PIECE * (?SIZE + 3)), new()),
    {Posts, C1} = erx_virtio_console_core:posts(C0),
    ?assertEqual(?SIZE, length(Posts)),
    ?assertEqual(?SIZE, length(lists:usort([Tag || {Tag, _} <- Posts]))),
    ?assertMatch({[], _}, erx_virtio_console_core:posts(C1)).

a_write_is_answered_once_every_piece_is_back_test() ->
    Ref = make_ref(),
    {[], C0} = erx_virtio_console_core:write(Ref, binary:copy(<<"a">>, ?PIECE * 3), new()),
    {[{T0, _}, {T1, _}, {T2, _}], C1} = erx_virtio_console_core:posts(C0),
    {[], C2} = erx_virtio_console_core:returned([T2, T0], C1),
    ?assertNot(erx_virtio_console_core:idle(C2)),
    {[Ref], C3} = erx_virtio_console_core:returned([T1], C2),
    ?assert(erx_virtio_console_core:idle(C3)).

writes_are_answered_in_the_order_they_came_test() ->
    A = make_ref(),
    B = make_ref(),
    {[], C0} = erx_virtio_console_core:write(A, binary:copy(<<"a">>, ?PIECE * 2), new()),
    {[], C1} = erx_virtio_console_core:write(B, <<"b">>, C0),
    {[{TA0, _}, {TA1, _}, {TB, _}], C2} = erx_virtio_console_core:posts(C1),
    {[], C3} = erx_virtio_console_core:returned([TB, TA1], C2),
    ?assertMatch({[A, B], _}, erx_virtio_console_core:returned([TA0], C3)).

a_write_past_the_queue_waits_for_returned_entries_test() ->
    Ref = make_ref(),
    {[], C0} = erx_virtio_console_core:write(Ref, binary:copy(<<"q">>, ?PIECE * (?SIZE + 1)), new()),
    {Posts, C1} = erx_virtio_console_core:posts(C0),
    {[], C2} = erx_virtio_console_core:returned([Tag || {Tag, _} <- Posts], C1),
    {[{Last, <<"qqqqqqqq">>}], C3} = erx_virtio_console_core:posts(C2),
    ?assertMatch({[Ref], _}, erx_virtio_console_core:returned([Last], C3)).

an_empty_write_is_answered_behind_the_writes_before_it_test() ->
    A = make_ref(),
    E = make_ref(),
    ?assertMatch({[E], _}, erx_virtio_console_core:write(E, <<>>, new())),
    {[], C0} = erx_virtio_console_core:write(A, <<"a">>, new()),
    {[], C1} = erx_virtio_console_core:write(E, <<>>, C0),
    {[{Tag, _}], C2} = erx_virtio_console_core:posts(C1),
    ?assertMatch({[A, E], _}, erx_virtio_console_core:returned([Tag], C2)).

%% Random writes, posted as entries free and returned in random order, a few at a time:
%% every byte is posted once and in order, no more than the queue's size are ever in
%% flight, and every write is answered exactly once, in the order it came.
random_return_orders_answer_every_write_once_in_order_test_() ->
    [?_test(explore(Seed)) || Seed <- lists:seq(1, 200)].

explore(Seed) ->
    rand:seed(exsss, {Seed, Seed * 7, Seed * 13}),
    Writes = [{make_ref(), random_bytes(rand:uniform(?PIECE * 3) - 1)} || _ <- lists:seq(1, rand:uniform(12))],
    {Answers, Posted} = run(Writes, new(), [], #{}, []),
    ?assertEqual([Ref || {Ref, _} <- Writes], Answers),
    ?assertEqual(iolist_to_binary([Bytes || {_, Bytes} <- Writes]), iolist_to_binary(Posted)).

%% Hands the writes over one at a time, between steps that post what may be posted and
%% return a random subset of what is in flight, until every write is answered.
run(Writes, C, Answers, Flight, Posted) ->
    {Pending, C1, Answers1} = hand_over(Writes, C, Answers),
    {Posts, C2} = erx_virtio_console_core:posts(C1),
    Flight1 = maps:merge(Flight, maps:from_list(Posts)),
    ?assert(map_size(Flight1) =< ?SIZE),
    ?assert(lists:all(fun({_, Piece}) -> byte_size(Piece) =< ?PIECE end, Posts)),
    Posted1 = Posted ++ [Piece || {_, Piece} <- Posts],
    Back = [Tag || Tag <- shuffle(maps:keys(Flight1)), rand:uniform(2) =:= 1],
    {Done, C3} = erx_virtio_console_core:returned(Back, C2),
    Answers2 = Answers1 ++ Done,
    case Pending =:= [] andalso erx_virtio_console_core:idle(C3) of
        true -> {Answers2, Posted1};
        false -> run(Pending, C3, Answers2, maps:without(Back, Flight1), Posted1)
    end.

hand_over([], C, Answers) ->
    {[], C, Answers};
hand_over([{Ref, Bytes} | Rest], C, Answers) ->
    {Done, C1} = erx_virtio_console_core:write(Ref, Bytes, C),
    {Rest, C1, Answers ++ Done}.

shuffle(List) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), X} || X <- List])].

random_bytes(N) ->
    << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, N) >>.

new() ->
    erx_virtio_console_core:new(?SIZE, ?PIECE).
