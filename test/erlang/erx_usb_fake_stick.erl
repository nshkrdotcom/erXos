%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_fake_stick).
-moduledoc """
A model USB flash drive for erx_usb_fake_xhci: one logical unit, a fixed,
not removable, 128-sector medium of 512-byte blocks held in memory,
speaking Bulk-Only Transport (BOT 1.0, 5 and 6) and the SCSI commands the
mass-storage function sends.

Its command state is BOT's: waiting for a CBW, in a command's data phase
(bulk-in data to send, or bulk-out data to take), or holding the CSW. A
class reset readies it for a CBW whatever it held, and a transfer out of
turn stalls. A command that fails answers status 1 and keeps the sense
REQUEST SENSE reads next.

The test plants faults, each taken by the next transfer it fits:
`stall_data`, a data phase that stalls and fails its command with MEDIUM
ERROR, as an unreadable sector; `hold_data`, a data phase left
unanswered, so the device can be unplugged mid-transfer; and
`short_csw` and `bad_csw`, a CSW of 12 bytes or with a wrong signature.
""".

-include("generated/erx_abi.hrl").

-export([new/0, fault/2, reset/1, bulk_out/2, bulk_in/2]).

-define(BLOCKS, 128).
-define(BLOCK, 512).
%% MEDIUM ERROR, UNRECOVERED READ ERROR (SPC's sense key 3, ASC 11h).
-define(MEDIUM_ERROR, {3, 16#11, 0}).

new() ->
    #{medium => binary:copy(<<0>>, ?BLOCKS * ?BLOCK), phase => cbw, sense => {0, 0, 0}, faults => []}.

fault(Stick = #{faults := Faults}, Fault) -> Stick#{faults := Faults ++ [Fault]}.

reset(Stick) -> Stick#{phase := cbw}.

%% A bulk-OUT transfer: a CBW, or a write's data; its answer as the controller's.
bulk_out(<<?ERX_USB_BOT_CBW_SIGNATURE:32/little, Tag:32/little, Length:32/little, _Flags, 0, Size, Block:16/binary>>,
         Stick = #{phase := cbw}) when Size >= 1, Size =< 16 ->
    {{ok, <<>>}, command(Tag, Length, binary_part(Block, 0, Size), Stick)};
bulk_out(Data, Stick = #{phase := {data_out, Tag, Length, Sector}, medium := Medium}) when byte_size(Data) =:= Length ->
    Offset = Sector * ?BLOCK,
    <<Before:Offset/binary, _Old:Length/binary, After/binary>> = Medium,
    {{ok, <<>>}, Stick#{medium := <<Before/binary, Data/binary, After/binary>>, phase := {csw, Tag, 0, 0}}};
bulk_out(_OutOfTurn, Stick) ->
    {{error, stall}, Stick}.

%% A bulk-IN transfer: a command's data, or its CSW; `hold` leaves it unanswered.
bulk_in(_Length, Stick = #{phase := {data_in, Tag, Bytes, Residue}, faults := Faults}) ->
    case Faults of
        [stall_data | Rest] ->
            {{error, stall}, Stick#{phase := {csw, Tag, byte_size(Bytes) + Residue, 1}, sense := ?MEDIUM_ERROR,
                                    faults := Rest}};
        [hold_data | Rest] ->
            {hold, Stick#{faults := Rest}};
        _ ->
            {{ok, Bytes}, Stick#{phase := {csw, Tag, Residue, 0}}}
    end;
bulk_in(_Length, Stick = #{phase := {csw, Tag, Residue, Status}, faults := Faults}) ->
    Csw = <<?ERX_USB_BOT_CSW_SIGNATURE:32/little, Tag:32/little, Residue:32/little, Status>>,
    case Faults of
        [short_csw | Rest] -> {{ok, binary_part(Csw, 0, 12)}, Stick#{phase := cbw, faults := Rest}};
        [bad_csw | Rest] -> {{ok, <<0:32, (binary_part(Csw, 4, 9))/binary>>}, Stick#{phase := cbw, faults := Rest}};
        _ -> {{ok, Csw}, Stick#{phase := cbw}}
    end;
bulk_in(_Length, Stick) ->
    {{error, stall}, Stick}.

%% A command block, by its operation code (sys/cam/scsi/scsi_all.h's layouts).
command(Tag, _Length, <<?ERX_SCSI_OP_TEST_UNIT_READY, _/binary>>, Stick) ->
    Stick#{phase := {csw, Tag, 0, 0}};
command(Tag, Length, <<?ERX_SCSI_OP_SYNCHRONIZE_CACHE_10, _/binary>>, Stick) ->
    Stick#{phase := {csw, Tag, Length, 0}};
command(Tag, Length, <<?ERX_SCSI_OP_REQUEST_SENSE, _/binary>>, Stick = #{sense := {Key, Asc, Ascq}}) ->
    data_in(Tag, Length, <<16#70, 0, Key, 0:32, 10, 0:32, Asc, Ascq, 0:32>>, Stick#{sense := {0, 0, 0}});
command(Tag, Length, <<?ERX_SCSI_OP_INQUIRY, _/binary>>, Stick) ->
    data_in(Tag, Length, <<0, 0, 2, 2, 31, 0, 0, 0, "erXos   ", "Model stick     ", "1.0 ">>, Stick);
command(Tag, Length, <<?ERX_SCSI_OP_READ_CAPACITY_10, _/binary>>, Stick) ->
    data_in(Tag, Length, <<(?BLOCKS - 1):32, ?BLOCK:32>>, Stick);
command(Tag, Length, <<?ERX_SCSI_OP_READ_10, 0, Sector:32, 0, Count:16, 0>>, Stick = #{medium := Medium}) ->
    data_in(Tag, Length, binary_part(Medium, Sector * ?BLOCK, Count * ?BLOCK), Stick);
command(Tag, Length, <<?ERX_SCSI_OP_WRITE_10, 0, Sector:32, 0, Count:16, 0>>, Stick) when Length =:= Count * ?BLOCK ->
    Stick#{phase := {data_out, Tag, Length, Sector}}.

data_in(Tag, Length, Bytes, Stick) ->
    Sent = binary_part(Bytes, 0, min(Length, byte_size(Bytes))),
    Stick#{phase := {data_in, Tag, Sent, Length - byte_size(Sent)}}.
