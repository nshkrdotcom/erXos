%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_usb_hub_core's decoders (docs/design-usb.md, "Fuzz targets"):
%% the hub's status-change bitmap, the hub's status and change words, and a hub port's
%% and a root port's, each over random bytes of lengths around its format's and over
%% values with every bit set. A round fails with a marker the runner looks for: `crash`
%% when a decoder raises or answers outside its spec; `out_of_bounds` when an answer
%% differs from the reference decoders written here from the design and FreeBSD's
%% speed rule (usb_hub.c:738-752): a bitmap naming a port past the hub's count, a short
%% report accepted or a long enough one refused, a status of a length other than 4
%% bytes accepted or one of 4 refused, or a field or speed decoded otherwise.
-module(erx_usb_hub_core_fuzz).

-export([run/1]).

-define(ROUNDS, 20000).

run([Seed]) ->
    S = list_to_integer(Seed),
    _ = rand:seed(exsss, {S, S, S}),
    Accepted = lists:sum([round() || _ <- lists:seq(1, ?ROUNDS)]),
    io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Accepted]).

round() ->
    Ports = rand:uniform(15),
    Report = bytes(rand:uniform(5) - 1),
    Words = bytes(pick([0, 3, 4, 4, 4, 5])),
    Parent = pick([{hub, full}, {hub, high}, {root, rand:uniform(256) - 1}, {root, rand:uniform(5) - 1}]),
    bitmap(Ports, Report) + hub_status(Words) + port_status(Words, Parent).

bitmap(Ports, Bytes) ->
    Answer = call(fun() -> erx_usb_hub_core:bitmap(Ports, Bytes) end, Bytes),
    sound(Answer =:= reference_bitmap(Ports, Bytes), {Ports, Bytes, Answer}),
    case Answer of
        {ok, _} -> 1;
        _ -> 0
    end.

%% Bit n of the report, in byte n div 8 at position n rem 8, names port n, bit 0 the hub.
reference_bitmap(Ports, Bytes) when bit_size(Bytes) >= Ports + 1 ->
    Bit = fun(N) -> binary:at(Bytes, N div 8) band (1 bsl (N rem 8)) =/= 0 end,
    {ok, [P || P <- lists:seq(1, Ports), Bit(P)] ++ [hub || Bit(0)]};
reference_bitmap(_Ports, _Bytes) ->
    {error, short_bitmap}.

hub_status(Bytes) ->
    case call(fun() -> erx_usb_hub_core:hub_status(Bytes) end, Bytes) of
        {ok, #{local_power := L, over_current := O, changes := C}} when is_boolean(L), is_boolean(O) ->
            sound(byte_size(Bytes) =:= 4 andalso C =:= lists:usort(C)
                      andalso C -- [local_power, over_current] =:= [], {Bytes, C}),
            1;
        {error, malformed_status} ->
            0;
        Other ->
            fail(crash, {Bytes, Other})
    end.

port_status(Bytes, Parent) ->
    Answer = call(fun() -> erx_usb_hub_core:port_status(Bytes, Parent) end, Bytes),
    sound(Answer =:= reference_port(Bytes, Parent), {Bytes, Parent, Answer}),
    case Answer of
        {ok, _} -> 1;
        _ -> 0
    end.

%% USB 2.0's port bits as usb.h:706-741 numbers them, written out here.
reference_port(<<S:16/little, C:16/little>>, Parent) ->
    Bit = fun(Word, N) -> Word band (1 bsl N) =/= 0 end,
    {ok, #{connected => Bit(S, 0), enabled => Bit(S, 1), suspended => Bit(S, 2),
           over_current => Bit(S, 3), reset => Bit(S, 4), powered => Bit(S, 8),
           speed => reference_speed(Bit(S, 9), Bit(S, 10), Parent),
           changes => lists:usort([Name || {Name, N} <- [{connection, 0}, {enabled, 1}, {suspend, 2},
                                                         {over_current, 3}, {reset, 4}],
                                           Bit(C, N)])}};
reference_port(_Bytes, _Parent) ->
    {error, malformed_status}.

reference_speed(_Low, true, {hub, high}) -> high;
reference_speed(true, _High, {hub, _}) -> low;
reference_speed(_Low, _High, {hub, _}) -> full;
reference_speed(_Low, _High, {root, Id}) ->
    proplists:get_value(Id, [{1, full}, {2, low}, {3, high}, {4, super}], unsupported).

call(Decode, Input) ->
    try Decode()
    catch Class:Reason:Stack -> fail(crash, {Input, Class, Reason, Stack})
    end.

sound(true, _Detail) -> ok;
sound(false, Detail) -> fail(out_of_bounds, Detail).

fail(Marker, Detail) ->
    io:format("~s: ~p~n", [Marker, Detail]),
    halt(1).

%% Bytes of Length, all ones one time in four.
bytes(Length) ->
    case rand:uniform(4) of
        1 -> binary:copy(<<255>>, Length);
        _ -> rand:bytes(Length)
    end.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
