%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_usb_bot_core's readers of what a mass-storage device sends
%% (docs/design-usb.md, "Fuzz targets"): the CSW, Get Max LUN's answer, and the INQUIRY,
%% REQUEST SENSE and READ CAPACITY(10) and (16) decoders, each over random bytes of
%% lengths around its format's and over structured values with each field at and around
%% its bounds. A round fails with a marker the runner looks for: `crash` when a reader
%% raises; `out_of_bounds` when an answer differs from the reference readers written here
%% from BOT 1.0 (6.3) and FreeBSD's SCSI layouts (sys/cam/scsi/scsi_all.h, as
%% abi/formats/usb.txt cites them).
-module(erx_usb_bot_core_fuzz).

-export([run/1]).

-define(ROUNDS, 20000).

run([Seed]) ->
    S = list_to_integer(Seed),
    _ = rand:seed(exsss, {S, S, S}),
    Accepted = lists:sum([round() || _ <- lists:seq(1, ?ROUNDS)]),
    io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Accepted]).

round() ->
    csw() + max_lun() + decoder(inquiry, bytes(rand:uniform(41) - 1))
        + decoder(sense, sense_input()) + decoder(read_capacity_10, bytes(rand:uniform(11) - 1))
        + decoder(read_capacity_16, bytes(rand:uniform(15) - 1)).

csw() ->
    Tag = pick([0, 1, 16#ffffffff, rand:uniform(1 bsl 32) - 1]),
    Length = pick([0, 18, 36, 512, 32768, rand:uniform(1 bsl 32) - 1]),
    Bytes = case rand:uniform(3) of
                1 -> bytes(pick([0, 12, 13, 13, 14, 31]));
                _ -> <<(pick([<<"USBS">>, <<"USBC">>, bytes(4)]))/binary,
                       (pick([Tag, Tag, Tag bxor 1, rand:uniform(1 bsl 32) - 1])):32/little,
                       (pick([0, Length, Length + 1, rand:uniform(1 bsl 32) - 1]) band 16#ffffffff):32/little,
                       (pick([0, 1, 2, 3, rand:uniform(256) - 1])),
                       (pick([<<>>, <<>>, <<>>, bytes(rand:uniform(3))]))/binary>>
            end,
    Answer = call(fun() -> erx_usb_bot_core:csw(Bytes, Tag, Length) end, Bytes),
    sound(Answer =:= reference_csw(Bytes, Tag, Length), {Bytes, Tag, Length, Answer}),
    case Answer of
        {_Status, _Residue} -> 1;
        _Refused -> 0
    end.

%% Valid: 13 bytes, signature 53425355h ("USBS" on the wire), the CBW's tag; meaningful:
%% status 0 or 1 with a residue no larger than the length, or 2.
reference_csw(<<"USBS", Tag:32/little, Residue:32/little, Status>>, Tag, Length) ->
    case Status of
        2 -> phase_error;
        _ when Residue > Length -> not_meaningful;
        0 -> {good, Residue};
        1 -> {failed, Residue};
        _ -> not_meaningful
    end;
reference_csw(_Bytes, _Tag, _Length) ->
    invalid.

max_lun() ->
    Answer = pick([{ok, bytes(rand:uniform(4) - 1)}, {ok, <<(rand:uniform(256) - 1)>>}, {error, stall}]),
    Units = call(fun() -> erx_usb_bot_core:max_lun(Answer) end, Answer),
    Expected = case Answer of
                   {ok, <<Max>>} when Max =< 15 -> {ok, Max + 1};
                   {ok, <<Max>>} -> {error, {max_lun, Max}};
                   _Failure -> {ok, 1}
               end,
    sound(Units =:= Expected, {Answer, Units}),
    1.

decoder(Name, Bytes) ->
    Answer = call(fun() -> erx_usb_bot_core:Name(Bytes) end, Bytes),
    sound(Answer =:= reference(Name, Bytes), {Name, Bytes, Answer}),
    case Answer of
        {ok, _} -> 1;
        {error, _} -> 0
    end.

%% INQUIRY: at least its 5-byte header; the device type in bits 4:0 and the qualifier in
%% bits 7:5 of byte 0, the removable bit 7 of byte 1; vendor[8] at byte 8 and product[16]
%% at byte 16 when 32 bytes are there.
reference(inquiry, Bytes) when byte_size(Bytes) < 5 ->
    {error, short};
reference(inquiry, Bytes) ->
    Device = binary:at(Bytes, 0),
    Unit = #{type => Device band 16#1f, qualifier => Device bsr 5, removable => binary:at(Bytes, 1) >= 16#80},
    case byte_size(Bytes) >= 32 of
        true -> {ok, Unit#{vendor => binary:part(Bytes, 8, 8), product => binary:part(Bytes, 16, 16)}};
        false -> {ok, Unit}
    end;
%% Fixed-format sense: 14 bytes; response code 70h or 71h in bits 6:0 of byte 0; the key
%% in bits 3:0 of byte 2; the additional sense code and qualifier in bytes 12 and 13.
reference(sense, Bytes) when byte_size(Bytes) < 14 ->
    {error, short};
reference(sense, Bytes) ->
    case binary:at(Bytes, 0) band 16#7f of
        Code when Code =:= 16#70; Code =:= 16#71 ->
            {ok, {binary:at(Bytes, 2) band 16#0f, binary:at(Bytes, 12), binary:at(Bytes, 13)}};
        _Other ->
            {error, unknown_format}
    end;
%% READ CAPACITY: the last block's big-endian address, 4 or 8 bytes, then the 4-byte block
%% length.
reference(read_capacity_10, Bytes) -> capacity(Bytes, 4);
reference(read_capacity_16, Bytes) -> capacity(Bytes, 8).

capacity(Bytes, AddressSize) when byte_size(Bytes) < AddressSize + 4 ->
    {error, short};
capacity(Bytes, AddressSize) ->
    {ok, #{last_block => binary:decode_unsigned(binary:part(Bytes, 0, AddressSize)),
           block_length => binary:decode_unsigned(binary:part(Bytes, AddressSize, 4))}}.

%% Sense data whose first byte is one of the codes around the fixed formats'.
sense_input() ->
    case bytes(rand:uniform(21) - 1) of
        <<_Code, Rest/binary>> -> <<(pick([16#70, 16#71, 16#f0, 16#f1, 16#72, rand:uniform(256) - 1])), Rest/binary>>;
        <<>> -> <<>>
    end.

call(Read, Input) ->
    try Read()
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
