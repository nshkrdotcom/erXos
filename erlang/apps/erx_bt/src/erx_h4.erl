%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_h4).
-moduledoc """
H4 framing over the controller's line (docs/design-bluetooth.md, "H4 framing"): the
host end of the Bluetooth Core Specification's UART transport, Vol 4 Part A, where a
one-byte packet indicator comes before each HCI packet (section 2, Table 2.1).

`split/1` takes the bytes read so far and returns every whole packet and the rest, an
incomplete packet. The controller may send two kinds: an event, its indicator, code
and one-byte length (Vol 4 Part E, section 5.4.4), and an ACL data packet, its
indicator, a 16-bit word of handle and flags and a two-byte length (5.4.2). Any other
indicator, and an ACL length beyond `bt_acl_rx_max`, is a loss of synchronization
(Part A, section 4), answered `{error, Reason}`; the caller ends and its restart resets
the line. The bound is the host's own, the same before and after the bring-up, so
`split/1` takes no parameter, and `Rest` is at most one packet's bound. Each length is
read against the bytes there, so nothing reads past the input, and no atom is made.

`command/2` and `acl/3` frame what the host sends.
""".

-include("generated/erx_abi.hrl").

-export([split/1, command/2, acl/3]).
-export_type([packet/0, error_reason/0]).

-doc "A whole packet from the controller: an event's code and parameters, or an ACL packet's 12-bit handle, Packet_Boundary_Flag, Broadcast_Flag and data.".
-type packet() :: {event, Code :: byte(), Parameters :: binary()}
                | {acl, Handle :: erx_hci:handle(), Boundary :: 0..3, Broadcast :: 0..3, Data :: binary()}.
-type error_reason() :: {bad_indicator, byte()} | {acl_too_long, non_neg_integer()}.

-doc "Every whole packet in Bytes, in order, and the bytes of the incomplete one after them.".
-spec split(binary()) -> {[packet()], Rest :: binary()} | {error, error_reason()}.
split(Bytes) when is_binary(Bytes) ->
    split(Bytes, []).

split(<<?ERX_H4_INDICATOR_EVENT, Code, Length, Parameters:Length/binary, Rest/binary>>, Packets) ->
    split(Rest, [{event, Code, Parameters} | Packets]);
split(<<?ERX_H4_INDICATOR_ACL, _:16, Length:16/little, _/binary>>, _Packets) when Length > ?ERX_BT_ACL_RX_MAX ->
    {error, {acl_too_long, Length}};
split(<<?ERX_H4_INDICATOR_ACL, Word:16/little, Length:16/little, Data:Length/binary, Rest/binary>>, Packets) ->
    split(Rest, [acl_packet(Word, Data) | Packets]);
split(<<Indicator, _/binary>> = Rest, Packets) when Indicator =:= ?ERX_H4_INDICATOR_EVENT;
                                                    Indicator =:= ?ERX_H4_INDICATOR_ACL ->
    {lists:reverse(Packets), Rest};
split(<<Indicator, _/binary>>, _Packets) ->
    {error, {bad_indicator, Indicator}};
split(<<>>, Packets) ->
    {lists:reverse(Packets), <<>>}.

%% The handle is the word's low 12 bits, then Packet_Boundary_Flag in bits 12-13 and
%% Broadcast_Flag in bits 14-15 (Part E, section 5.4.2).
acl_packet(Word, Data) ->
    <<Broadcast:2, Boundary:2, Handle:?ERX_HCI_HANDLE_BITS>> = <<Word:16>>,
    {acl, Handle, Boundary, Broadcast, Data}.

-doc "A command packet: the indicator, the opcode and the parameters, at most 255 bytes (Part E, section 5.4.1).".
-spec command(0..16#FFFF, binary()) -> binary().
command(Opcode, Parameters) when byte_size(Parameters) =< 255 ->
    <<?ERX_H4_INDICATOR_COMMAND, Opcode:16/little, (byte_size(Parameters)), Parameters/binary>>.

-doc "An ACL data packet to the controller on Handle, with Packet_Boundary_Flag Boundary and no broadcast.".
-spec acl(0..?ERX_HCI_HANDLE_MAX, 0..3, binary()) -> binary().
acl(Handle, Boundary, Data) when Handle =< ?ERX_HCI_HANDLE_MAX, byte_size(Data) =< 16#FFFF ->
    <<?ERX_H4_INDICATOR_ACL, (Handle bor (Boundary bsl ?ERX_HCI_HANDLE_BITS)):16/little, (byte_size(Data)):16/little, Data/binary>>.
