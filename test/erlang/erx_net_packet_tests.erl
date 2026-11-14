%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_packet_tests).
-moduledoc """
The packet framing of a TCP socket process (docs/design-network-stack.md, "The socket
process"): erx_net_packet's decode/3 and encode/2, and the socket process's core
presenting a byte stream in a packet mode as stock's gen_tcp presents it. The second is
differential: each case's bytes are sent, in the same pieces, to a stock gen_tcp socket
on the host's loopback and pushed to an erx_gen_tcp_core, and what each owner gets, in
passive and in active mode, must be the same packets and the same end.
""".

-include_lib("eunit/include/eunit.hrl").

-define(SOCK, {'$inet', erx_gen_tcp, self()}).
%% How long the stock side waits between pieces, so each is read on its own, and for its end.
-define(GAP, 20).
-define(WAIT, 2000).

limits(Longest, Buffer) -> #{longest => Longest, buffer => Buffer}.

decode_test_() ->
    D = fun erx_net_packet:decode/3,
    [{"a line without its newline waits for one, or for the bytes that cut it",
      [?_assertEqual({more, {line, 100}}, D(line, <<"ab">>, limits(1000, 100))),
       ?_assertEqual({more, {line, 5}}, D(line, <<"ab">>, limits(4, 100)))]},
     {"a line ends at its newline, the rest left",
      ?_assertEqual({ok, <<"abc\n">>, <<"de">>}, D(line, <<"abc\nde">>, limits(1000, 100)))},
     {"a line of the longest packet's bytes, its newline included, is taken",
      ?_assertEqual({ok, <<"abc\n">>, <<>>}, D(line, <<"abc\n">>, limits(4, 100)))},
     {"a line longer than the longest packet is emsgsize",
      ?_assertEqual({error, emsgsize}, D(line, <<"abcd\n">>, limits(4, 100)))},
     {"more than the longest packet's bytes without a newline is emsgsize",
      [?_assertEqual({more, {line, 5}}, D(line, <<"abcd">>, limits(4, 100))),
       ?_assertEqual({error, emsgsize}, D(line, <<"abcde">>, limits(4, 100)))]},
     {"a line is cut at the buffer",
      [?_assertEqual({ok, <<"abcdefgh">>, <<"ij">>}, D(line, <<"abcdefghij">>, limits(1000, 8))),
       ?_assertEqual({ok, <<"abcd">>, <<"efgh\n">>}, D(line, <<"abcdefgh\n">>, limits(1000, 4)))]},
     {"a line is looked for in the first buffer bytes only", fun line_window/0},
     {"a length mode's packet follows its header, an empty one included",
      [?_assertEqual({ok, <<"abc">>, <<2>>}, D(1, <<3, "abc", 2>>, limits(1000, 1))),
       ?_assertEqual({ok, <<>>, <<0, 1, "x">>}, D(2, <<0, 0, 0, 1, "x">>, limits(1000, 1))),
       ?_assertEqual({ok, <<"ab">>, <<>>}, D(4, <<0, 0, 0, 2, "ab">>, limits(1000, 1)))]},
     {"a length mode needs its whole header, then its whole packet",
      [?_assertEqual({more, {length, 3}}, D(4, <<0, 0>>, limits(1000, 1))),
       ?_assertEqual({more, {length, 9}}, D(4, <<0, 0, 0, 5, "ab">>, limits(1000, 1)))]},
     {"a length over the longest packet is emsgsize",
      [?_assertEqual({error, emsgsize}, D(4, <<0, 0, 0, 5>>, limits(4, 1))),
       ?_assertEqual({error, emsgsize}, D(2, <<0, 2>>, limits(1, 1)))]},
     {"a waiting line stops waiting once a push brings a newline, a length never",
      [?_assertEqual(none, erx_net_packet:arrived({line, 9}, [<<"ab">>, <<"c\nd">>])),
       ?_assertEqual({line, 9}, erx_net_packet:arrived({line, 9}, [<<"ab">>, <<"cd">>])),
       ?_assertEqual({length, 9}, erx_net_packet:arrived({length, 9}, [<<"\n">>]))]},
     {"a send gets its length's header, its low bits as stock writes them",
      [?_assertEqual(<<0, 0, 0, 3, "hey">>, erx_net_packet:encode(4, <<"hey">>)),
       ?_assertEqual(<<44, 0:2400>>, erx_net_packet:encode(1, <<0:2400>>)),
       ?_assertEqual(<<"hey">>, erx_net_packet:encode(line, <<"hey">>))]}].

%% More bytes than the buffer are held when the buffer shrinks after they were granted, as
%% ssh's hello shrinks it to 255 bytes: the line is cut at the buffer, not judged whole.
line_window() ->
    ?assertEqual({ok, <<"ab">>, <<"cdefg">>}, erx_net_packet:decode(line, <<"abcdefg">>, limits(5, 2))),
    ?assertEqual({error, emsgsize}, erx_net_packet:decode(line, <<"abcdefg">>, limits(4, 8))).

%% --- Against stock gen_tcp ------------------------------------------------------------

%% Each case: its options and the pieces its peer sends before it closes. The buffer is
%% given wherever a line can reach it, since stock's default buffer is the host's.
cases() ->
    [{line_across_reads, [{packet, line}], [<<"ab">>, <<"c\nde">>, <<"f\n">>, <<"tail">>]},
     {line_list, [{packet, line}, list], [<<"ab\ncd\n">>, <<"e\n">>]},
     {line_crlf, [{packet, line}], [<<"SSH-2.0-peer\r\n">>, <<"\r\nx\n">>]},
     {line_over_size, [{packet, line}, {packet_size, 4}], [<<"abc\nabcdef\nxy\n">>]},
     {line_over_size_no_newline, [{packet, line}, {packet_size, 4}], [<<"abcdefgh">>]},
     {line_at_size, [{packet, line}, {packet_size, 4}], [<<"abc\n">>, <<"abcd">>, <<"\n">>]},
     {line_size_zero, [{packet, line}, {packet_size, 0}, {buffer, 1000}],
      [binary:copy(<<"z">>, 1500), <<"\n">>, binary:copy(<<"y">>, 2500), <<"\n">>]},
     {line_over_buffer, [{packet, line}, {buffer, 8}], [<<"abcdefghijklmn\nxy\n">>]},
     {line_over_buffer_under_size, [{packet, line}, {buffer, 8}, {packet_size, 20}], [<<"abcdefghijklmn\nxy\n">>]},
     {line_cut_before_its_size, [{packet, line}, {buffer, 2}, {packet_size, 5}], [<<"abcdefg\n">>]},
     {packet_1, [{packet, 1}], [<<3, "abc", 2>>, <<"de", 0>>, <<5, "ab">>]},
     {packet_2, [{packet, 2}], [<<0, 3, "abc", 0>>, <<0, 0, 1, "x">>]},
     {packet_4, [{packet, 4}], [<<0, 0, 0, 3, "abc">>, <<0, 0, 0, 5, "ab">>, <<"cde">>, <<0, 0>>]},
     {packet_4_over_size, [{packet, 4}, {packet_size, 4}], [<<0, 0, 0, 3, "abc", 0, 0, 0, 5, "abcde">>]},
     {packet_2_list, [{packet, 2}, list], [<<0, 2, "ab", 0, 1>>, <<"c">>]}].

stock_test_() ->
    {timeout, 120,
     [{atom_to_list(Name) ++ " " ++ atom_to_list(Active),
       fun() -> ?assertEqual(stock(Active, Opts, Pieces), core(Active, Opts, Pieces)) end}
      || {Name, Opts, Pieces} <- cases(), Active <- [false, true]]}.

%% What a stock gen_tcp owner gets: in passive mode every recv(S, 0) up to its first error
%% and the recv after it; in active mode every message about the socket.
stock(Active, Opts, Pieces) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    {ok, Peer} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    {ok, S} = gen_tcp:accept(L, ?WAIT),
    ok = gen_tcp:close(L),
    ok = inet:setopts(S, options(Active, Opts)),
    lists:foreach(fun(Piece) -> ok = gen_tcp:send(Peer, Piece), timer:sleep(?GAP) end, Pieces),
    ok = gen_tcp:close(Peer),
    Got = case Active of
              false -> stock_recvs(S);
              true -> stock_messages(S)
          end,
    gen_tcp:close(S),
    Got.

stock_recvs(S) ->
    case gen_tcp:recv(S, 0, ?WAIT) of
        {ok, Packet} -> [{ok, Packet} | stock_recvs(S)];
        {error, _} = Error -> [Error, gen_tcp:recv(S, 0, 0)]
    end.

stock_messages(S) ->
    receive
        {tcp, S, Packet} -> [{tcp, Packet} | stock_messages(S)];
        {tcp_error, S, Reason} -> [{tcp_error, Reason} | stock_messages(S)];
        {tcp_closed, S} -> [tcp_closed]
    after ?WAIT ->
        [timeout]
    end.

%% A case's options for its owner: binary unless the case asks for a list. Stock's
%% setopts/2 keeps the first of two modes and erx_gen_tcp's the last, so a case gives one.
options(Active, Opts) ->
    Mode = [binary || not lists:member(list, Opts)],
    Mode ++ Opts ++ [{active, Active}].

%% The same as the socket process's core presents it, the pieces and the peer's FIN pushed
%% as the connection pushes them, within the credit the core grants.
core(Active, Opts, Pieces) ->
    {ok, Own, []} = erx_gen_tcp_core:options(options(Active, Opts)),
    {C0, Granted} = erx_gen_tcp_core:new(?SOCK, Own),
    {Conn, Acts} = feed({C0, 0, Pieces ++ [eof]}, Granted),
    case Active of
        false -> core_recvs(Conn);
        true -> [told(Message) || {tell, Message} <- Acts]
    end.

%% The connection, `{Core, Credit, Pending}`: the credit it holds, and what it has not
%% pushed, the end last. feed/2 takes the credit Acts grant and pushes what it allows,
%% returning every action the core made meanwhile.
feed({C, Credit0, Pending}, Acts) ->
    Credit = Credit0 + lists:sum([N || {credit, N} <- Acts]),
    case Pending of
        [eof] ->
            {C1, More} = erx_gen_tcp_core:step({push, {ok, eof}}, C),
            {Conn, Rest} = feed({C1, Credit, []}, More),
            {Conn, Acts ++ Rest};
        [Piece | Later] when is_binary(Piece), Credit > 0 ->
            Size = min(byte_size(Piece), Credit),
            <<Push:Size/binary, Left/binary>> = Piece,
            {C1, More} = erx_gen_tcp_core:step({push, {ok, {data, [Push]}}}, C),
            {Conn, Rest} = feed({C1, Credit - Size, [Left || Left =/= <<>>] ++ Later}, More),
            {Conn, Acts ++ Rest};
        _ ->
            {{C, Credit, Pending}, Acts}
    end.

core_recvs(Conn) ->
    case recv(Conn) of
        {{ok, Packet}, Conn1} -> [{ok, Packet} | core_recvs(Conn1)];
        {{error, _} = Error, Conn1} -> [Error, element(1, recv(Conn1))]
    end.

%% A recv(S, 0), answered once the connection has pushed what it needs.
recv({C, Credit, Pending}) ->
    {C1, Acts} = erx_gen_tcp_core:step({call, f, {recv, 0, infinity}}, C),
    {Conn, All} = feed({C1, Credit, Pending}, Acts),
    [Reply] = [R || {reply, f, R} <- All],
    {Reply, Conn}.

told({tcp, _Sock, Packet}) -> {tcp, Packet};
told({tcp_error, _Sock, Reason}) -> {tcp_error, Reason};
told({tcp_closed, _Sock}) -> tcp_closed.
