%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the Raspberry Pi 4 Ethernet controller's receive decision,
%% erx_genet_rx:frame/2, over completions as the device NIF hands them up: the
%% descriptor's whole status word and the bytes the controller wrote, none when
%% the status's length passes the buffer. Known answers at every boundary come
%% first, each worked out by hand from FreeBSD's if_genet.c:1406-1409 (start,
%% end and error bits) and :1440-1443 (the padding counted in the length). Then
%% every size up to past the buffer with every combination of the start, end
%% and error bits is judged with judge/2, a restatement of the rules that agrees
%% with the known answers, as the oracle.

-module(erx_genet_rx_tests).
-include_lib("eunit/include/eunit.hrl").

-define(BUFFER, 2048).
-define(SOP, (1 bsl 13)).
-define(EOP, (1 bsl 14)).
-define(ERR, (1 bsl 2)).
%% The five error bits, 0 to 4, each with the reason it drops a frame.
-define(ERRORS, [{1 bsl 0, overflow}, {1 bsl 1, crc_error}, {1 bsl 2, rx_error},
                 {1 bsl 3, non_octet}, {1 bsl 4, length_error}]).
%% The flag bits no rule reads: they never change a decision.
-define(NOISE, (16#ffff band bnot (?SOP bor ?EOP bor 16#1f))).

%% The bytes a buffer holds: byte I is I mod 251, so a frame's offset shows.
buffer(Size) -> list_to_binary([I rem 251 || I <- lists:seq(0, Size - 1)]).

%% A completion as the NIF hands it up: the status, flags and a length of Size,
%% and the bytes, none when Size passes the buffer.
completion(Flags, Size, Whole) when Size > ?BUFFER -> {(Size bsl 16) bor Flags, binary:part(Whole, 0, 0)};
completion(Flags, Size, Whole) -> {(Size bsl 16) bor Flags, binary:part(Whole, 0, Size)}.

%% The oracle: a length past the buffer first, then the lowest error bit, then
%% start and end, then the bytes against an Ethernet header after the padding;
%% a frame is the bytes after the padding.
judge(Status, Bytes) ->
    Size = byte_size(Bytes),
    if
        Status bsr 16 > ?BUFFER -> {drop, too_long};
        Status band 16#1f =/= 0 ->
            {drop, hd([Reason || {Bit, Reason} <- ?ERRORS, Status band Bit =/= 0])};
        Status band (?SOP bor ?EOP) =/= (?SOP bor ?EOP) -> {drop, fragment};
        Size < 2 + 14 -> {drop, runt};
        true -> {frame, list_to_binary(binary:bin_to_list(Bytes, {2, Size - 2}))}
    end.

every_size_and_flag_combination_matches_the_oracle_test_() ->
    {timeout, 120,
     fun() ->
             Whole = buffer(?BUFFER),
             [begin
                  {Status, Bytes} = completion(Flags, Size, Whole),
                  ?assertEqual({Status, judge(Status, Bytes)}, {Status, erx_genet_rx:frame(Status, Bytes)})
              end || Size <- lists:seq(0, ?BUFFER + 64),
                     Base <- [S bor E bor R || S <- [0, ?SOP], E <- [0, ?EOP], R <- [0 | [Bit || {Bit, _} <- ?ERRORS]]],
                     Flags <- [Base, Base bor ?NOISE]]
     end}.

boundaries_have_their_known_answers_test() ->
    Whole = ?SOP bor ?EOP,
    Cases = [{Whole, 15, {drop, runt}},
             {Whole, 16, {frame, binary:part(buffer(16), 2, 14)}},
             {Whole, 17, {frame, binary:part(buffer(17), 2, 15)}},
             {Whole, 600, {frame, binary:part(buffer(600), 2, 598)}},
             {Whole, ?BUFFER, {frame, binary:part(buffer(?BUFFER), 2, 2046)}},
             {Whole, ?BUFFER + 1, {drop, too_long}},
             {Whole, 16#ffff, {drop, too_long}},
             {Whole bor ?ERR, ?BUFFER + 1, {drop, too_long}},
             {?SOP, 64, {drop, fragment}},
             {?EOP, 64, {drop, fragment}},
             {Whole bor ?ERR, 64, {drop, rx_error}},
             {?ERR, 15, {drop, rx_error}}
             | [{Whole bor Bit, 64, {drop, Reason}} || {Bit, Reason} <- ?ERRORS]],
    [begin
         {Status, Bytes} = completion(F, S, buffer(?BUFFER)),
         ?assertEqual({F, S, Want}, {F, S, erx_genet_rx:frame(Status, Bytes)})
     end || {F, S, Want} <- Cases].

the_padding_is_counted_in_the_length_and_skipped_test() ->
    Frame = <<1:48, 2:48, 16#0800:16, "payload">>,
    Bytes = <<16#aa, 16#bb, Frame/binary>>,
    ?assertEqual({frame, Frame}, erx_genet_rx:frame((byte_size(Bytes) bsl 16) bor ?SOP bor ?EOP, Bytes)).

statuses_past_32_bits_are_refused_test() ->
    [?assertError(function_clause, erx_genet_rx:frame(S, buffer(64)))
     || S <- [-1, 1 bsl 32, (1 bsl 32) bor (64 bsl 16) bor ?SOP bor ?EOP]].

%% The three descriptor statuses the Pi 4 showed, end of packet without start of
%% packet and a length past the buffer whichever width the field has (bits 27:16
%% hold 3446, 2965 and 3550; bits 31:16 11638, 7061 and 15838): the device NIF
%% copies no bytes for them, and each is a drop, not a broken queue.
board_statuses_past_the_buffer_are_dropped_as_too_long_test() ->
    [?assertEqual({S, {drop, too_long}}, {S, erx_genet_rx:frame(S, <<>>)})
     || S <- [16#2d764800, 16#1b954000, 16#3dde4800]].
