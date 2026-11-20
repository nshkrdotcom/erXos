%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_xhci_core's decoders (docs/design-usb.md, "Fuzz targets"): the
%% completion code, a command completion's answer and a transfer completion's result,
%% over codes and values around and past each field's range, values of other types
%% included, as a controller or a fault in the NIF's reading could hand them over; the
%% capability registers, as any words or a well-formed set; and a root-port operation on
%% any PORTSC word. A round fails with a marker the runner looks for: `crash` when a
%% decoder raises or answers outside its spec; `out_of_bounds` when an answer differs
%% from the reference written here from the design: a slot outside 1 to usb_devices_max
%% (16) or an address outside 1 to 127 accepted, a code named other than its ABI name, a
%% result other than the one its code gives, capabilities accepted or refused other than
%% as the reference decides, or a PORTSC write setting a bit its operation does not mean.
-module(erx_xhci_core_fuzz).

-export([run/1]).

-include("generated/erx_abi.hrl").

-define(ROUNDS, 20000).
-define(SLOTS_MAX, 16).
-define(ADDRESS_MAX, 127).

run([Seed]) ->
    S = list_to_integer(Seed),
    _ = rand:seed(exsss, {S, S, S}),
    Accepted = lists:sum([round() || _ <- lists:seq(1, ?ROUNDS)]),
    io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Accepted]).

round() ->
    Code = value(),
    Extra = value(),
    Kind = pick([enable_slot, address_device, stop_endpoint, set_tr_dequeue, configure_endpoints]),
    completion(Code) + command_answer(Kind, Code, Extra) + transfer_result(Code, bytes_or_value())
        + capabilities() + port_operation().

completion(Code) when is_integer(Code) ->
    Answer = call(fun() -> erx_xhci_core:completion(Code) end, Code),
    sound(Answer =:= reference_completion(Code), {Code, Answer}),
    0;
completion(_Code) ->
    0.

reference_completion(Code) ->
    case [Name || {Name, Value} <- ?ERX_XHCI_COMPLETION_MEMBERS, Value =:= Code] of
        [Name] -> Name;
        [] -> {unknown, Code}
    end.

command_answer(Kind, Code, Extra) ->
    Answer = call(fun() -> erx_xhci_core:command_answer(Kind, Code, Extra) end, {Kind, Code, Extra}),
    sound(Answer =:= reference_answer(Kind, Code, Extra), {Kind, Code, Extra, Answer}),
    case Answer of
        {ok, _} -> 1;
        _ -> 0
    end.

reference_answer(_Kind, Code, _Extra) when not is_integer(Code) -> malformed;
reference_answer(enable_slot, 1, Slot) -> in_range(Slot, ?SLOTS_MAX);
reference_answer(address_device, 1, Address) -> in_range(Address, ?ADDRESS_MAX);
reference_answer(_Kind, 1, _Extra) -> ok;
reference_answer(address_device, Code, _Extra) -> {error, {address, reference_completion(Code)}};
reference_answer(_Kind, Code, _Extra) -> {error, reference_completion(Code)}.

in_range(Value, Max) when is_integer(Value), Value >= 1, Value =< Max -> {ok, Value};
in_range(_Value, _Max) -> malformed.

transfer_result(Code, Bytes) ->
    Answer = call(fun() -> erx_xhci_core:transfer_result(Code, Bytes) end, {Code, Bytes}),
    sound(Answer =:= reference_result(Code, Bytes), {Code, Bytes, Answer}),
    0.

%% Success (1) and short packet (13) carry the bytes; STALL (6) is a stall; the three
%% stop codes (26, 27, 28) a dropped transfer; any other code the controller's.
reference_result(Code, Bytes) when not is_integer(Code); not is_binary(Bytes) -> malformed;
reference_result(Code, Bytes) when Code =:= 1; Code =:= 13 -> {ok, Bytes};
reference_result(6, _Bytes) -> {error, stall};
reference_result(Code, _Bytes) when Code >= 26, Code =< 28 -> {error, stopped};
reference_result(Code, _Bytes) -> {error, {controller, reference_completion(Code)}}.

%% The capability registers as a controller may fill them: any 32-bit words with up to
%% eight supported-protocol capabilities, or a well-formed set. The decoder accepts
%% exactly what the reference accepts, 4 KiB pages and protocols naming non-empty,
%% disjoint port ranges within 1..MaxPorts, and gives each such port its protocol's major
%% revision, its controller MaxPorts ports and at most 1023 scratchpads.
capabilities() ->
    {Words, Count} = (pick([fun any_capabilities/0, fun well_formed_capabilities/0]))(),
    Decoded = call(fun() -> erx_xhci_core:decode_capabilities(Words, #{legacy => false, protocols => Count}) end,
                   Words),
    case {Decoded, reference_protocols(Words, Count)} of
        {{ok, #{ports := Ports, protocols := Protocols, scratchpads := Scratchpads}}, {ok, Protocols}} ->
            sound(Ports =:= maps:get(hcsparams1, Words) bsr 24 andalso Scratchpads =< 1023, {Words, Ports}),
            1;
        {{error, _Refused}, refused} ->
            0;
        Mismatch ->
            fail(out_of_bounds, {Words, Mismatch})
    end.

any_capabilities() ->
    Count = rand:uniform(9) - 1,
    {maps:from_list([{Register, word()} || Register <- [hcsparams1, hcsparams2, hccparams1, pagesize]]
                    ++ [{{protocol, I, Word}, protocol_word(Word)} || I <- lists:seq(1, Count),
                                                                      Word <- [revision, ports]]),
     Count}.

%% 4 KiB pages among others, and protocols on runs of ports from port 1 up, a gap of up
%% to two ports before each, while they fit in MaxPorts.
well_formed_capabilities() ->
    Ports = rand:uniform(255),
    Ranges = ranges(1, Ports, 8),
    {maps:from_list([{hcsparams1, Ports bsl 24 bor (word() band 16#ffffff)}, {hcsparams2, word()},
                     {hccparams1, word()}, {pagesize, word() band 16#ffff bor 1}]
                    ++ lists:append([[{{protocol, I, revision}, word()},
                                      {{protocol, I, ports}, Count bsl 8 bor First}]
                                     || {I, {First, Count}} <- lists:enumerate(Ranges)])),
     length(Ranges)}.

ranges(_From, _Ports, 0) -> [];
ranges(From, Ports, Left) ->
    First = From + rand:uniform(3) - 1,
    Count = rand:uniform(4),
    case First + Count - 1 =< Ports of
        true -> [{First, Count} | ranges(First + Count, Ports, Left - 1)];
        false -> []
    end.

%% Each port's major revision, or refused: pages other than 4 KiB, or a protocol naming
%% no port, a port past MaxPorts or a port an earlier protocol named.
reference_protocols(#{pagesize := PageSize}, _Count) when PageSize band 1 =:= 0 -> refused;
reference_protocols(Words = #{hcsparams1 := Params1}, Count) ->
    reference_protocols(Words, Params1 bsr 24, lists:seq(1, Count), #{}).

reference_protocols(_Words, _Ports, [], Named) -> {ok, Named};
reference_protocols(Words, Ports, [I | Rest], Named) ->
    #{{protocol, I, revision} := Revision, {protocol, I, ports} := PortWord} = Words,
    {First, Count} = {PortWord band 255, (PortWord bsr 8) band 255},
    Range = lists:seq(First, First + Count - 1),
    case First >= 1 andalso Count >= 1 andalso First + Count - 1 =< Ports
         andalso not lists:any(fun(Port) -> is_map_key(Port, Named) end, Range) of
        true -> reference_protocols(Words, Ports, Rest, maps:merge(Named, maps:from_keys(Range, Revision bsr 24)));
        false -> refused
    end.

%% A supported-protocol word whose ports are often near the edges of the port count.
protocol_word(revision) -> word();
protocol_word(ports) -> (rand:uniform(256) - 1) bsl 8 bor pick([0, 1, 2, 254, 255, rand:uniform(256) - 1]).

%% A root-port operation on any PORTSC word writes the enable bit only to disable, a
%% change bit only when clearing, and never the link state strobe or a warm reset; a
%% status read gives two 16-bit words and a 4-bit speed ID.
port_operation() ->
    Word = word(),
    Op = pick([get_status, power_on, reset, disable, {clear, connection}, {clear, enabled},
               {clear, suspend}, {clear, over_current}, {clear, reset}]),
    case call(fun() -> erx_xhci_core:port_operation(Op, Word) end, {Op, Word}) of
        {[], {ok, <<_:32>>, Speed}} ->
            sound(Op =:= get_status andalso Speed =< 15, {Op, Word, Speed});
        {[Written], ok} ->
            Changes = Written band 16#fe0000,
            sound(Written band 16#80010000 =:= 0
                  andalso (Written band 2 =:= 0 orelse Op =:= disable)
                  andalso (Changes =:= 0 orelse is_tuple(Op))
                  andalso Written < 1 bsl 32,
                  {Op, Word, Written})
    end,
    0.

word() -> rand:uniform(1 bsl 32) - 1.

%% A value around the fields' ranges: an 8-bit code or slot, a 7-bit address, the
%% 24-bit parameter, negative and huge integers, and values of other types.
value() ->
    case rand:uniform(6) of
        1 -> rand:uniform(40) - 1;
        2 -> pick([-1, 0, 1, 16, 17, 126, 127, 128, 255, 256]);
        3 -> rand:uniform(256) - 1;
        4 -> rand:uniform(1 bsl 24) - 1;
        5 -> pick([-(1 bsl 64), 1 bsl 64, 1.0, none, <<1>>, [], {1}]);
        6 -> pick([1, 1, 4, 6, 13, 19, 26, 27, 28])
    end.

bytes_or_value() ->
    case rand:uniform(4) of
        1 -> value();
        _ -> rand:bytes(rand:uniform(9) - 1)
    end.

call(Decode, Input) ->
    try Decode()
    catch Class:Reason:Stack -> fail(crash, {Input, Class, Reason, Stack})
    end.

sound(true, _Detail) -> ok;
sound(false, Detail) -> fail(out_of_bounds, Detail).

fail(Marker, Detail) ->
    io:format("~s: ~p~n", [Marker, Detail]),
    halt(1).

pick(List) -> lists:nth(rand:uniform(length(List)), List).
