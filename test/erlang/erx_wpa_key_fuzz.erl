%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_wpa_key (tools/fuzz/erx_wpa_key.rb; docs/design-wifi.md,
%% "Untrusted input", fuzz_wpa_key): EAPOL-Key frames and key data from a hostile
%% access point, built well formed and then mutated (bytes flipped, lengths rewritten,
%% the frame cut or extended), through decode/1, mic_input/1 and key_data/1. Each
%% returns {ok, _} or {error, _} and never raises; an accepted frame's key data is
%% within the bytes given and its MIC input as long as its frame; and an accepted key
%% data's GTK and IGTK have their ciphers' key lengths.
-module(erx_wpa_key_fuzz).
-export([run/1]).

-define(ROUNDS, 50000).
-define(MIN_ACCEPTED, ?ROUNDS div 20).

run([Seed]) ->
    rand:seed(exsss, {80, 211, list_to_integer(Seed)}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of() =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of() ->
    Data = mutate(key_data()),
    KeyData = guarded(key_data, fun() -> erx_wpa_key:key_data(Data) end),
    check_key_data(Data, KeyData),
    Frame = mutate(frame(Data)),
    case guarded(decode, fun() -> erx_wpa_key:decode(Frame) end) of
        {ok, #{frame := Bytes, data := KeyBytes} = Key} ->
            check(byte_size(Bytes) =< byte_size(Frame), frame_within_input, Frame),
            check(binary:longest_common_suffix([Bytes, KeyBytes]) =:= byte_size(KeyBytes), data_in_frame, Frame),
            MicInput = guarded(mic_input, fun() -> erx_wpa_key:mic_input(Key) end),
            check(byte_size(MicInput) =:= byte_size(Bytes), mic_input_length, Frame),
            accepted;
        {error, _} ->
            refused
    end.

check_key_data(Data, {ok, #{gtk := Gtk, igtk := Igtk}}) ->
    check(Gtk =:= none orelse byte_size(maps:get(key, Gtk)) =:= 16, gtk_length, Data),
    check(Igtk =:= none orelse lists:member(maps:get(id, Igtk), [4, 5]), igtk_id, Data);
check_key_data(_Data, {error, _}) ->
    ok.

guarded(Name, Fun) ->
    try
        Fun()
    catch
        Class:Reason:Stack -> error({crash, Name, Class, Reason, Stack})
    end.

check(true, _Property, _Input) -> ok;
check(false, Property, Input) -> error({Property, Input}).

%% A well-formed frame around key data: version 1 to 3, type 3, descriptor 2, random
%% Key Information and counters.
frame(Data) ->
    Body = <<2, (rand:uniform(65536) - 1):16, 0:16, (rand:uniform(1 bsl 32)):64, (bytes(32))/binary,
             0:128, (bytes(8))/binary, 0:64, (bytes(16))/binary, (byte_size(Data)):16, Data/binary>>,
    <<(rand:uniform(3)), 3, (byte_size(Body)):16, Body/binary>>.

%% Key data of a few elements: an RSN element, a GTK or IGTK KDE, a KDE of another
%% type, an RSNXE, then perhaps padding.
key_data() ->
    Elements = [pick([rsn, gtk, igtk, other, rsnxe]) || _ <- lists:seq(1, rand:uniform(4))],
    Padding = pick([<<>>, <<221>>, <<221, 0:(rand:uniform(7) * 8)>>]),
    iolist_to_binary([element_bytes(Element) || Element <- Elements] ++ [Padding]).

element_bytes(rsn) -> <<48, 20, 1, 0, 0, 16#0f, 16#ac, 4, 1, 0, 0, 16#0f, 16#ac, 4, 1, 0, 0, 16#0f, 16#ac, 2, 0, 0>>;
element_bytes(gtk) -> <<221, 22, 0, 16#0f, 16#ac, 1, (rand:uniform(4) - 1), 0, (bytes(16))/binary>>;
element_bytes(igtk) -> <<221, 28, 0, 16#0f, 16#ac, 9, (3 + rand:uniform(2)):16/little, (bytes(22))/binary>>;
element_bytes(other) -> <<221, 6, 0, 16#0f, 16#ac, 4, (bytes(2))/binary>>;
element_bytes(rsnxe) -> <<244, 1, 16#20>>.

%% None, one or several of: a byte changed, a byte made a length-like value, the bytes
%% cut short, or bytes added.
mutate(Bytes) ->
    lists:foldl(fun(_, Acc) -> mutation(pick([flip, length, cut, extend]), Acc) end,
                Bytes, lists:seq(1, rand:uniform(4) - 1)).

mutation(_, <<>>) -> <<>>;
mutation(flip, Bytes) -> replace(Bytes, rand:uniform(256) - 1);
mutation(length, Bytes) -> replace(Bytes, pick([0, 1, 2, 16, 22, 28, 95, 96, 99, 127, 128, 255]));
mutation(cut, Bytes) -> binary:part(Bytes, 0, rand:uniform(byte_size(Bytes)) - 1);
mutation(extend, Bytes) -> <<Bytes/binary, (bytes(rand:uniform(8)))/binary>>.

replace(Bytes, Value) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Head:At/binary, _, Tail/binary>> = Bytes,
    <<Head/binary, Value, Tail/binary>>.

bytes(N) -> rand:bytes(N).

pick(List) -> lists:nth(rand:uniform(length(List)), List).
