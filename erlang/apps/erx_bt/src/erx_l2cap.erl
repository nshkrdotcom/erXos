%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_l2cap).
-moduledoc """
L2CAP's basic frames on an LE-U link's fixed channels (docs/design-bluetooth.md, "Links:
the fixed channels"), from the Bluetooth Core Specification 6.3, Vol 3 Part A, whose codes
abi/formats/bluetooth.txt holds.

`reassemble/3` joins the ACL packets of one handle into frames as their Packet_Boundary_Flag
marks them (Vol 4 Part E, 5.4.2): a frame starts with `first_flushable` and continues with
`continuing`, and its PDU Length (Part A, 3.1) says where it ends. The caller, the link,
holds the frame in progress between packets. A frame longer than its channel's bound, a
continuation without a start, a start inside a frame, more bytes than the frame's length
and a flag the controller does not send on LE-U are each an error, which ends the link; the
bound, `bound/1`, is ATT's MTU on the ATT channel, SMP's on the SMP channel and ATT's MTU,
the longest frame the link takes, on any other, so no frame in progress holds more.

`fragments/3` cuts a frame the host sends into ACL packets of at most the controller's
length, and `signal/1` answers a frame on LE signaling: Command Reject, "Command not
understood", for every command but a response, as erXos asks for nothing and offers no
credit-based channel, and "Signaling MTU exceeded" for a frame longer than MTUsig (Part A,
4 and 4.1). Nothing here makes an atom.
""".

-include("generated/erx_abi.hrl").

-export([reassemble/3, fragments/3, signal/1, bound/1, att_mtu/0]).
-export_type([partial/0, cid/0, error/0]).

%% The responses LE signaling carries (Part A, Table 4.2), Command Reject among them.
-define(IS_RESPONSE(Code), (Code =:= ?ERX_L2CAP_SIGNAL_COMMAND_REJECT orelse Code =:= ?ERX_L2CAP_SIGNAL_DISCONNECTION_RSP
                           orelse Code =:= ?ERX_L2CAP_SIGNAL_CONNECTION_PARAMETER_UPDATE_RSP
                           orelse Code =:= ?ERX_L2CAP_SIGNAL_LE_CREDIT_BASED_CONNECTION_RSP
                           orelse Code =:= ?ERX_L2CAP_SIGNAL_CREDIT_BASED_CONNECTION_RSP
                           orelse Code =:= ?ERX_L2CAP_SIGNAL_CREDIT_BASED_RECONFIGURE_RSP)).

-doc "A channel identifier (Part A, 2.1).".
-type cid() :: 0..16#FFFF.
-doc "The frame in progress: none, or its bytes so far, header included, shorter than the frame.".
-type partial() :: none | binary().
-type error() :: {too_long, cid(), Length :: 0..16#FFFF} | continuation_without_start | start_inside_frame
               | overrun | {bad_boundary, 0..3}.

-doc """
ATT's MTU on the fixed channel, the server's Rx MTU: what is left of the longest ACL packet
the host takes, `bt_acl_rx_max`, after the L2CAP header, so one ACL packet holds the
largest ATT PDU whole.
""".
-spec att_mtu() -> pos_integer().
att_mtu() -> ?ERX_BT_ACL_RX_MAX - ?ERX_L2CAP_HEADER.

-doc "The longest payload the link reassembles on channel `Cid`.".
-spec bound(cid()) -> pos_integer().
bound(?ERX_L2CAP_CID_SMP) -> ?ERX_SMP_MTU;
bound(_Cid) -> att_mtu().

-doc """
Adds one ACL packet's `Data`, with its boundary flag, to the frame in progress: `{frame, Cid,
Payload}` when it completes one, `{more, Partial}` when the frame goes on, or `{error,
Reason}`.
""".
-spec reassemble(0..3, binary(), partial()) ->
          {frame, cid(), binary()} | {more, partial()} | {error, error()}.
reassemble(?ERX_HCI_ACL_BOUNDARY_FIRST_FLUSHABLE, Data, none) -> frame(Data);
reassemble(?ERX_HCI_ACL_BOUNDARY_FIRST_FLUSHABLE, _Data, _Partial) -> {error, start_inside_frame};
reassemble(?ERX_HCI_ACL_BOUNDARY_CONTINUING, _Data, none) -> {error, continuation_without_start};
reassemble(?ERX_HCI_ACL_BOUNDARY_CONTINUING, Data, Partial) -> frame(<<Partial/binary, Data/binary>>);
reassemble(Boundary, _Data, _Partial) -> {error, {bad_boundary, Boundary}}.

%% The bytes of a frame so far, judged once its header is whole.
frame(<<Length:16/little, Cid:16/little, Payload/binary>> = Bytes) ->
    case bound(Cid) of
        Bound when Length > Bound -> {error, {too_long, Cid, Length}};
        _ when byte_size(Payload) =:= Length -> {frame, Cid, Payload};
        _ when byte_size(Payload) < Length -> {more, Bytes};
        _ -> {error, overrun}
    end;
frame(Bytes) ->
    {more, Bytes}.

-doc """
Cuts a frame on `Cid` into ACL packets of at most `AclMax` octets of data each, the first
flagged `first_non_flushable` and the rest `continuing`, as the host sends them (Vol 4
Part E, 5.4.2).
""".
-spec fragments(cid(), binary(), pos_integer()) -> [{0..3, binary()}].
fragments(Cid, Payload, AclMax) ->
    <<First:(min(AclMax, ?ERX_L2CAP_HEADER + byte_size(Payload)))/binary, Rest/binary>> =
        <<(byte_size(Payload)):16/little, Cid:16/little, Payload/binary>>,
    [{?ERX_HCI_ACL_BOUNDARY_FIRST_NON_FLUSHABLE, First} | continuing(Rest, AclMax)].

continuing(<<>>, _AclMax) ->
    [];
continuing(Bytes, AclMax) ->
    <<Piece:(min(AclMax, byte_size(Bytes)))/binary, Rest/binary>> = Bytes,
    [{?ERX_HCI_ACL_BOUNDARY_CONTINUING, Piece} | continuing(Rest, AclMax)].

-doc """
The answer to `Frame`, one frame on LE signaling: `{reply, Frame}` to send back on the same
channel, or `drop` for a response, which is never answered, and for a frame too short to
carry a command's code, identifier and Data Length, or whose Data Length disagrees with it,
which Part A, 4 calls not correctly formed and which has no identifier to answer.
""".
-spec signal(binary()) -> {reply, binary()} | drop.
signal(<<Code, _/binary>>) when ?IS_RESPONSE(Code) ->
    drop;
signal(<<_Code, Identifier, _/binary>> = Frame) when byte_size(Frame) > ?ERX_L2CAP_LE_MTU_SIG ->
    {reply, reject(Identifier, ?ERX_L2CAP_REJECT_REASON_MTU_EXCEEDED, <<?ERX_L2CAP_LE_MTU_SIG:16/little>>)};
signal(<<_Code, Identifier, Length:16/little, Data/binary>>) when byte_size(Data) =:= Length ->
    {reply, reject(Identifier, ?ERX_L2CAP_REJECT_REASON_NOT_UNDERSTOOD, <<>>)};
signal(_Frame) ->
    drop.

reject(Identifier, Reason, ReasonData) ->
    <<?ERX_L2CAP_SIGNAL_COMMAND_REJECT, Identifier, (2 + byte_size(ReasonData)):16/little, Reason:16/little,
      ReasonData/binary>>.
