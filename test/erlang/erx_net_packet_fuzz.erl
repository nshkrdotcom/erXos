%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_packet_fuzz).
-moduledoc """
The fuzz target of a TCP socket process's packet framing, the peer's bytes as the owner's
domain frames them (docs/design-network-stack.md, "The socket process"), driven by
tools/fuzz/erx_net_packet.rb. Two targets, over every packet mode the options offer
(`1`, `2`, `4`, `line`), with `packet_size` and `buffer` at, near and far from the
packets' sizes:

* `decode`: erx_net_packet:decode/3 on byte strings built of headers and lines near
  their limits and mutated. Its answer must equal this module's own reading of stock's
  framing (packet_parser.c's packet_get_length, as inet_drv calls it): a line looked for
  in the first `buffer` bytes, cut there, and over `packet_size` with its newline an
  error; a length mode's packet after its whole header, and over `packet_size`, or over
  64 MiB when that is 0, an error. A disagreement prints `decode_differs`.
* `core`: erx_gen_tcp_core presenting such a stream, pushed in random pieces within the
  credit it grants, then the peer's FIN, to an owner in active or passive mode. What the
  owner gets must be the stream framed whole by the same reading, then the end:
  `tcp_closed` or `closed` after the last whole packet, or `emsgsize` where the first
  packet over its bound would be. A disagreement prints `core_differs`, and a recv the
  core never answers `core_stalled`.

A call that raises prints `raised`. Prints `fuzz: N inputs ok` when every input passed.
""".

-export([run/1]).

-define(INPUTS, 4000).
-define(MAX_PACKET, 67108864).
-define(SOCK, {'$inet', erx_gen_tcp, self()}).

run([Target, Seed]) ->
    _ = rand:seed(exsss, {list_to_integer(Seed), 11, 17}),
    Check = check(list_to_atom(Target)),
    Failures = lists:filtermap(fun(_) -> Check() end, lists:seq(1, ?INPUTS)),
    case Failures of
        [] -> io:format("fuzz: ~b inputs ok~n", [?INPUTS]);
        [First | _] ->
            Tags = lists:usort([element(1, Failure) || Failure <- Failures]),
            io:format("fuzz: ~b failed, tags ~p, first ~P~n", [length(Failures), Tags, First, 20])
    end.

check(decode) -> fun decode/0;
check(core) -> fun core/0.

%% One input: Actual must not raise and must give Expected.
judge(Tag, Actual, Expected, Input) ->
    try Actual() of
        Expected -> false;
        Got -> {true, {Tag, Input, Got, Expected}}
    catch
        Class:Reason:Stack -> {true, {raised, Input, Class, Reason, hd(Stack)}}
    end.

%% --- Inputs --------------------------------------------------------------------------

pick(List) -> lists:nth(rand:uniform(length(List)), List).

type() -> pick([1, 2, 4, line, line]).

%% A limit near Near, at it, or far from it.
near(Near) -> max(0, Near + rand:uniform(5) - 3).

limits(Stream) ->
    Typical = rand:uniform(max(1, byte_size(Stream))),
    #{packet_size => pick([0, 0, near(Typical), 16#ffffffff, near(4)]),
      buffer => max(1, pick([near(Typical), 65536, near(8), 255]))}.

%% A stream of packets of Type, each well formed or not, the last perhaps partial.
stream(Type) ->
    Packets = [packet(Type) || _ <- lists:seq(1, rand:uniform(6) - 1)],
    mutate(iolist_to_binary(Packets)).

packet(line) ->
    Body = rand:bytes(rand:uniform(12) - 1),
    case rand:uniform(4) of
        1 -> Body;
        _ -> <<(binary:replace(Body, <<"\n">>, <<"x">>, [global]))/binary, "\n">>
    end;
packet(Header) ->
    Body = rand:bytes(rand:uniform(12) - 1),
    Length = case rand:uniform(8) of
                 1 -> rand:uniform(1 bsl (Header * 8)) - 1;
                 2 -> pick([?MAX_PACKET, ?MAX_PACKET + 1]) band ((1 bsl (Header * 8)) - 1);
                 _ -> byte_size(Body)
             end,
    <<Length:(Header * 8), Body/binary>>.

mutate(Bytes) ->
    case rand:uniform(6) of
        1 when byte_size(Bytes) > 0 ->
            At = rand:uniform(byte_size(Bytes)) - 1,
            <<Head:At/binary, _, Tail/binary>> = Bytes,
            <<Head/binary, (rand:uniform(256) - 1), Tail/binary>>;
        2 -> <<Bytes/binary, (rand:bytes(rand:uniform(4)))/binary>>;
        3 when byte_size(Bytes) > 0 -> binary:part(Bytes, 0, rand:uniform(byte_size(Bytes)) - 1);
        _ -> Bytes
    end.

%% --- The reading of stock's framing ----------------------------------------------------

%% stock's framing of the first packet of Bytes: packet_get_length over the bytes its
%% driver holds, a line's at most `buffer`, the longest packet the socket's packet_size,
%% bounded at 64 MiB; and what a packet in progress waits for.
reference(line, Bytes, #{buffer := Buffer} = Limits) ->
    Longest = longest(Limits),
    Window = binary:part(Bytes, 0, min(byte_size(Bytes), Buffer)),
    case binary:match(Window, <<"\n">>) of
        {At, 1} when At + 1 > Longest -> {error, emsgsize};
        {At, 1} -> split(At + 1, Bytes);
        nomatch when byte_size(Window) > Longest -> {error, emsgsize};
        nomatch when byte_size(Window) >= Buffer -> split(Buffer, Bytes);
        nomatch -> {more, {line, min(Buffer, Longest + 1)}}
    end;
reference(Header, Bytes, Limits) ->
    Bits = Header * 8,
    case Bytes of
        <<Length:Bits, _/binary>> ->
            case longest(Limits) of
                Longest when Length > Longest -> {error, emsgsize};
                _ when byte_size(Bytes) >= Header + Length -> split(Header, Length, Bytes);
                _ -> {more, {length, Header + Length}}
            end;
        _ -> {more, {length, byte_size(Bytes) + 1}}
    end.

longest(#{packet_size := 0}) -> ?MAX_PACKET;
longest(#{packet_size := Size}) -> min(Size, ?MAX_PACKET).

split(Header, Length, Bytes) ->
    <<_:Header/binary, Body:Length/binary, Rest/binary>> = Bytes,
    {ok, Body, Rest}.

split(Length, Bytes) ->
    <<Packet:Length/binary, Rest/binary>> = Bytes,
    {ok, Packet, Rest}.

%% The whole stream as the reading frames it: its packets, then where it ends.
framed(Type, Bytes, Limits) ->
    case reference(Type, Bytes, Limits) of
        {ok, Packet, Rest} -> [{packet, Packet} | framed(Type, Rest, Limits)];
        {more, _} -> [closed];
        {error, Reason} -> [{error, Reason}]
    end.

%% --- decode ----------------------------------------------------------------------------

decode() ->
    Type = type(),
    Bytes = stream(Type),
    Limits = limits(Bytes),
    Decoded = #{longest => longest(Limits), buffer => maps:get(buffer, Limits)},
    judge(decode_differs, fun() -> erx_net_packet:decode(Type, Bytes, Decoded) end,
          reference(Type, Bytes, Limits), {Type, Bytes, Limits}).

%% --- core ------------------------------------------------------------------------------

core() ->
    Type = type(),
    Bytes = stream(Type),
    Limits = limits(Bytes),
    Active = pick([false, true]),
    Input = {Type, Bytes, Limits, Active},
    try presented(Type, Bytes, Limits, Active) of
        stalled -> {true, {core_stalled, Input}};
        Got -> judge(core_differs, fun() -> Got end, framed(Type, Bytes, Limits), Input)
    catch
        Class:Reason:Stack -> {true, {raised, Input, Class, Reason, hd(Stack)}}
    end.

%% What the owner gets, as framed/3 says it: the packets, then `closed` or the error.
presented(Type, Bytes, #{packet_size := Size, buffer := Buffer}, Active) ->
    {ok, Own, []} = erx_gen_tcp_core:options([binary, {packet, Type}, {packet_size, Size}, {buffer, Buffer},
                                              {active, Active}]),
    {C0, Granted} = erx_gen_tcp_core:new(?SOCK, Own),
    {Conn, Acts} = feed({C0, 0, [Bytes, eof]}, Granted),
    case Active of
        false -> recvs(Conn);
        true -> messages([told(Message) || {tell, Message} <- Acts])
    end.

recvs(Conn) ->
    case recv(Conn) of
        stalled -> stalled;
        {{ok, Packet}, Conn1} -> then({packet, Packet}, recvs(Conn1));
        {{error, closed}, _} -> [closed];
        {{error, Reason}, _} -> [{error, Reason}]
    end.

recv({C, Credit, Pending}) ->
    {C1, Acts} = erx_gen_tcp_core:step({call, f, {recv, 0, infinity}}, C),
    {Conn, All} = feed({C1, Credit, Pending}, Acts),
    case [R || {reply, f, R} <- All] of
        [Reply] -> {Reply, Conn};
        [] -> stalled
    end.

then(_Packet, stalled) -> stalled;
then(Packet, Later) -> [Packet | Later].

%% Every message ends in `tcp_closed`, after a `tcp_error` for an error; one that does
%% not end so stalled.
messages(Told) ->
    case lists:reverse(Told) of
        [closed, {error, _} = Error | Before] -> lists:reverse(Before, [Error]);
        [closed | _] -> Told;
        _ -> stalled
    end.

told({tcp, _, Packet}) -> {packet, Packet};
told({tcp_error, _, Reason}) -> {error, Reason};
told({tcp_closed, _}) -> closed.

%% The connection, `{Core, Credit, Pending}`: the credit it holds and what it has not
%% pushed, the end last, in pieces of random sizes within the credit.
feed({C, Credit0, Pending}, Acts) ->
    Credit = Credit0 + lists:sum([N || {credit, N} <- Acts]),
    case Pending of
        [eof] ->
            {C1, More} = erx_gen_tcp_core:step({push, {ok, eof}}, C),
            {Conn, Rest} = feed({C1, Credit, []}, More),
            {Conn, Acts ++ Rest};
        [<<>>, eof] ->
            feed({C, Credit, [eof]}, Acts);
        [Bytes, eof] when Credit > 0 ->
            Size = min(min(byte_size(Bytes), Credit), rand:uniform(40)),
            <<Push:Size/binary, Left/binary>> = Bytes,
            {C1, More} = erx_gen_tcp_core:step({push, {ok, {data, [Push]}}}, C),
            {Conn, Rest} = feed({C1, Credit - Size, [Left, eof]}, More),
            {Conn, Acts ++ Rest};
        _ ->
            {{C, Credit, Pending}, Acts}
    end.
