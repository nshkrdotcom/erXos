%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_xhci_core's decoders (docs/design-usb.md, "Fuzz targets"): the
%% completion code, a command completion's answer and a transfer completion's result,
%% over codes and values around and past each field's range, values of other types
%% included, as a controller or a fault in the NIF's reading could hand them over. A
%% round fails with a marker the runner looks for: `crash` when a decoder raises or
%% answers outside its spec; `out_of_bounds` when an answer differs from the reference
%% written here from the design: a slot outside 1 to usb_devices_max (16) or an address
%% outside 1 to 127 accepted, a code named other than its ABI name, or a result other than
%% the one its code gives.
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
    completion(Code) + command_answer(Kind, Code, Extra) + transfer_result(Code, bytes_or_value()).

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
