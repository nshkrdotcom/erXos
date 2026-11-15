%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_usb_desc, the USB descriptor decoder, with the claim property
%% test of docs/design-usb.md, "Host tests of the cores", run by tools/fuzz/erx_usb_desc.rb.
%% Each round decodes one input, drawn as a configuration, a hub descriptor, a string or
%% language table, or a device descriptor: built from descriptors with values around
%% every bound, a fixture with bytes flipped, inserted or cut, or random bytes. Every
%% configuration accepted is then claimed at each speed for a plain device and for hubs
%% of each protocol. A round fails with a marker the runner looks for: `crash` when a
%% decoder or the claim raises or answers something outside its shapes, and
%% `out_of_bounds` when an accepted value breaks a bound the stack relies on: a
%% wTotalLength past 4096 bytes, an endpoint numbered 0, a hub of more than 15 ports, a
%% string that is not UTF-8, an endpoint address claimed twice, more than 7 pipes, or a
%% pipe whose packet size, burst, payload or interval exponent is not the one its speed
%% and type allow, or whose payload does not fit its queue block's buffer.
-module(erx_usb_desc_fuzz).

-export([run/1]).

-import(erx_usb_desc_tests, [configuration/1, interface/5, endpoint/4, companion/3, hid/1, hub/3,
                             string/1, device/3]).

-define(ROUNDS, 20000).
-define(SPEEDS, [low, full, high, super]).

run([Seed]) ->
    S = list_to_integer(Seed),
    _ = rand:seed(exsss, {S, S, S}),
    Accepted = lists:foldl(fun(_, N) -> N + fuzz_round() end, 0, lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Accepted]).

fuzz_round() ->
    case rand:uniform(10) of
        N when N =< 7 -> decoded(configuration, input(fun built_configuration/0, fixtures()));
        8 -> decoded(hub, input(fun built_hub/0, [hub(4, 0, 50)]));
        9 -> decoded(pick([string, languages]),
                     input(fun built_string/0, [string(<<$a, 0, 16#3d, 16#d8, 16#00, 16#de>>)]));
        10 -> decoded(device, input(fun() -> device(9, 0, rand:uniform(4) - 1) end, [device(0, 0, 0)]))
    end.

input(Build, Fixtures) ->
    case rand:uniform(10) of
        N when N =< 6 -> Build();
        N when N =< 9 -> mutated(lists:nth(rand:uniform(length(Fixtures)), Fixtures));
        _ -> rand:bytes(rand:uniform(64))
    end.

fixtures() ->
    [erx_usb_desc_tests:boot_keyboard(), erx_usb_desc_tests:storage(),
     erx_usb_desc_tests:hub_multi_tt(), erx_usb_desc_tests:ss_interrupt(8)].

decoded(Kind, Bytes) ->
    Answer = try erx_usb_desc:Kind(Bytes)
             catch Class:Reason:Stack -> fail(crash, Bytes, {Class, Reason, Stack})
             end,
    case Answer of
        {ok, Value} ->
            check(Kind, Value, Bytes),
            1;
        {error, Why} ->
            lists:member(Why, [descriptor_too_long, malformed_descriptor, duplicate_interface,
                               endpoint_zero, too_many_ports]) orelse fail(crash, Bytes, Answer),
            0;
        _ ->
            fail(crash, Bytes, Answer)
    end.

fail(Marker, Bytes, Detail) ->
    io:format("~s: ~p~n input ~p~n", [Marker, Detail, Bytes]),
    halt(1).

sound(true, _Bytes, _Detail) -> ok;
sound(false, Bytes, Detail) -> fail(out_of_bounds, Bytes, Detail).

check(configuration, Configuration = #{settings := Settings}, Bytes = <<_:2/binary, Total:16/little, _/binary>>) ->
    Endpoints = [E || #{endpoints := Es} <- maps:values(Settings), E <- Es],
    sound(Total =< 4096 andalso Total =< byte_size(Bytes)
              andalso lists:all(fun(#{address := A}) -> A band 16#0f =/= 0 andalso A band 16#70 =:= 0 end,
                                Endpoints),
          Bytes, Configuration),
    [claimed(Speed, Device, Configuration, Bytes)
     || Speed <- ?SPEEDS, Device <- [device(0, 0, 0), device(9, 0, 0), device(9, 0, 1), device(9, 0, 2)]],
    ok;
check(hub, Hub = #{ports := Ports}, Bytes) ->
    sound(Ports >= 1 andalso Ports =< 15, Bytes, Hub);
check(languages, Table, Bytes) ->
    sound(lists:all(fun(Id) -> Id >= 0 andalso Id =< 16#ffff end, Table), Bytes, Table);
check(string, Text, Bytes) ->
    sound(is_binary(unicode:characters_to_binary(Text)), Bytes, Text);
check(device, Device, Bytes) ->
    sound(byte_size(Bytes) =:= 18 andalso map_size(Device) =:= 12, Bytes, Device).

claimed(Speed, DeviceBytes, Configuration, Bytes) ->
    {ok, Device} = erx_usb_desc:device(DeviceBytes),
    Answer = try erx_usb_claim:functions(Speed, Device, Configuration)
             catch Class:Reason:Stack -> fail(crash, Bytes, {Speed, Class, Reason, Stack})
             end,
    case Answer of
        {ok, Functions} ->
            Addresses = [A || #{setting := #{endpoints := Es}} <- Functions, #{address := A} <- Es],
            Pipes = [P || #{pipes := Ps} <- Functions, P <- Ps],
            sound(length(Addresses) =:= length(lists:usort(Addresses)) andalso length(Pipes) =< 7
                      andalso lists:all(fun(P) -> admissible(Speed, P) end, Pipes),
                  Bytes, {Speed, Functions});
        {error, Why} ->
            lists:member(Why, [missing_setting, missing_companion, duplicate_endpoint, too_many_endpoints,
                               malformed_descriptor, endpoint_too_large, zero_interval_payload])
                orelse fail(crash, Bytes, {Speed, Answer});
        _ ->
            fail(crash, Bytes, {Speed, Answer})
    end.

%% The packet sizes FreeBSD's filter gives, the burst each speed and type allow, the
%% payload rule and xHCI's range of Interval exponents (Table 6-12), written out from the
%% design rather than taken from the module.
admissible(Speed, #{type := Type, packet_size := Size, burst := Burst, payload := Payload,
                    interval_exponent := Exponent}) ->
    Product = Size * (Burst + 1),
    Buffer = case Type of interrupt -> 1024; bulk -> 32768 end,
    lists:member(Size, packet_sizes(Type, Speed))
        andalso lists:member(Burst, bursts(Type, Speed))
        andalso Payload >= 1 andalso Payload =< Buffer
        andalso lists:member(Exponent, case {Type, Speed} of
                                           {bulk, _} -> [0];
                                           {interrupt, low} -> lists:seq(3, 10);
                                           {interrupt, full} -> lists:seq(3, 10);
                                           {interrupt, _} -> lists:seq(0, 15)
                                       end)
        andalso case {Type, Speed} of
                    {interrupt, super} -> Payload =< Product andalso Payload =< 3072;
                    _ -> Payload =:= Product
                end.

packet_sizes(interrupt, low) -> lists:seq(1, 8);
packet_sizes(interrupt, full) -> lists:seq(1, 64);
packet_sizes(interrupt, _) -> lists:seq(1, 1024);
packet_sizes(bulk, low) -> [8];
packet_sizes(bulk, full) -> [8, 16, 32, 64];
packet_sizes(bulk, high) -> [512];
packet_sizes(bulk, super) -> [1024].

bursts(_, super) -> lists:seq(0, 15);
bursts(interrupt, high) -> [0, 1, 2];
bursts(_, _) -> [0].

%% A configuration of up to 24 descriptors, its wTotalLength mostly true; one in eight
%% starts with 16 vendor descriptors of 255 bytes, which carry it near or past 4096.
built_configuration() ->
    Long = case rand:uniform(8) of
               1 -> [<<255, 16#ff, 0:253/unit:8>> || _ <- lists:seq(1, 16)];
               _ -> []
           end,
    Bytes = configuration(Long ++ disordered(lists:append([setting() || _ <- lists:seq(1, rand:uniform(4))]))),
    case rand:uniform(10) of
        1 -> <<(binary:part(Bytes, 0, 2))/binary, (rand:uniform(5000)):16/little,
               (binary:part(Bytes, 4, byte_size(Bytes) - 4))/binary>>;
        2 -> binary:part(Bytes, 0, rand:uniform(byte_size(Bytes)));
        _ -> Bytes
    end.

%% One setting: its interface descriptor, maybe a HID descriptor, and up to three
%% endpoints, each maybe followed by its companion.
setting() ->
    Interface = interface(rand:uniform(4) - 1, pick([0, 0, 1, 2]), pick([3, 8, 9, 16#ff]),
                          pick([0, 1, 6]), pick([0, 1, 2, 16#50])),
    Hid = [pick([hid(rand:uniform(16#ffff)), <<9, 16#21, 16#0b, 16#ff, 0, 0, 4, 16#10, 1>>])
           || rand:uniform(2) =:= 1],
    [Interface | Hid] ++ lists:append([endpoint_with_companion() || _ <- lists:seq(1, rand:uniform(4) - 1)]).

endpoint_with_companion() ->
    Endpoint = endpoint(pick([16#81, 16#82, 16#02, 16#03, 16#83, 16#84, 16#05, 16#00, 16#80]) bxor pick([0, 0, 0, 0, 16#80, 16#10]),
                        pick([2, 3, 3, rand:uniform(4) - 1]), packet(), pick([0, 1, 2, 15, 16, 17, 128, 255, rand:uniform(16)])),
    [Endpoint | [companion(pick([0, 1, 2, 15, 16, 255]), 0,
                           pick([0, 1, 8, 64, 65, 1023, 1024, 1025, 3072, 3073, 16#ffff]))
                 || rand:uniform(3) =/= 1]].

%% One in four lists gets one descriptor out of place: an endpoint, a companion, a
%% vendor descriptor, a long one, or random bytes.
disordered(Descriptors) ->
    case rand:uniform(4) of
        1 ->
            At = rand:uniform(length(Descriptors) + 1) - 1,
            {Before, After} = lists:split(At, Descriptors),
            Stray = pick([endpoint(16#86, 3, 8, 1), companion(0, 0, 8), <<2, 16#ff>>,
                          <<255, 16#ff, 0:253/unit:8>>, rand:bytes(rand:uniform(9))]),
            Before ++ [Stray | After];
        _ ->
            Descriptors
    end.

packet() ->
    pick([0, 1, 7, 8, 9, 16, 31, 63, 64, 65, 511, 512, 513, 1023, 1024, 16#7ff])
        bor (pick([0, 0, 1, 2, 3]) bsl 11).

built_hub() ->
    hub(pick([0, 1, 8, 15, 16, 255]), rand:uniform(16#ffff) - 1, rand:uniform(256) - 1).

built_string() ->
    string(<< <<(pick([$a, 16#d83d, 16#de00, 16#ffff, 0])):16/little>> || _ <- lists:seq(1, rand:uniform(20)) >>).

pick(List) -> lists:nth(rand:uniform(length(List)), List).

mutated(Bytes) ->
    Size = byte_size(Bytes),
    At = rand:uniform(Size) - 1,
    <<Before:At/binary, Byte, After/binary>> = Bytes,
    case rand:uniform(3) of
        1 -> <<Before/binary, (Byte bxor (1 bsl (rand:uniform(8) - 1))), After/binary>>;
        2 -> <<Before/binary, (rand:uniform(256) - 1), Byte, After/binary>>;
        3 -> <<Before/binary, After/binary>>
    end.
