%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_bumble_decode).
-moduledoc """
erXos's side of the codec comparison with Bumble (test/host/erx_bt_bumble_test.rb,
docs/design-bluetooth.md, "Fuzz targets"). Reads the corpus, lines of `CODEC HEX`
where CODEC is att or smp, decodes each frame with erx_att:decode/1 or
erx_smp:decode/1, and writes one line per frame in the canonical form
test/bt/bumble_decode.py writes from Bumble's decoders: `rejected` for a frame
the decoder answers invalid, else the code in two hex digits and each field in
the order the specification lays it out, integers in decimal, octet strings in
wire order in hex, and a UUID as its 128-bit form in wire order in hex. A frame
the decoder reads as no PDU of its side is named for what it answers:
`unsupported OP`, `ignored`, `reserved CODE` or `empty`.
""".
-export([main/0, run/2]).

-include("generated/erx_abi.hrl").

main() ->
    [Corpus, Output] = init:get_plain_arguments(),
    run(Corpus, Output).

-spec run(file:filename(), file:filename()) -> ok.
run(Corpus, Output) ->
    {ok, Bytes} = file:read_file(Corpus),
    Lines = [line(Line) || Line <- binary:split(Bytes, <<"\n">>, [global, trim_all])],
    ok = file:write_file(Output, [[Line, $\n] || Line <- Lines]).

line(Line) ->
    [Codec, Hex] = binary:split(Line, <<" ">>),
    canonical(Codec, binary:decode_hex(Hex)).

canonical(<<"att">>, Frame) -> att(erx_att:decode(Frame));
canonical(<<"smp">>, Frame) -> smp(erx_smp:decode(Frame)).

att({request, {exchange_mtu, Mtu}}) -> form(?ERX_ATT_OPCODE_EXCHANGE_MTU_REQ, [Mtu]);
att({request, {find_information, Start, End}}) -> form(?ERX_ATT_OPCODE_FIND_INFORMATION_REQ, [Start, End]);
att({request, {find_by_type_value, Start, End, Type, Value}}) ->
    form(?ERX_ATT_OPCODE_FIND_BY_TYPE_VALUE_REQ, [Start, End, uuid(Type), Value]);
att({request, {read_by_type, Start, End, Type}}) -> form(?ERX_ATT_OPCODE_READ_BY_TYPE_REQ, [Start, End, uuid(Type)]);
att({request, {read, Handle}}) -> form(?ERX_ATT_OPCODE_READ_REQ, [Handle]);
att({request, {read_blob, Handle, Offset}}) -> form(?ERX_ATT_OPCODE_READ_BLOB_REQ, [Handle, Offset]);
att({request, {read_by_group_type, Start, End, Type}}) ->
    form(?ERX_ATT_OPCODE_READ_BY_GROUP_TYPE_REQ, [Start, End, uuid(Type)]);
att({request, {write, Handle, Value}}) -> form(?ERX_ATT_OPCODE_WRITE_REQ, [Handle, Value]);
att({request, {prepare_write, Handle, Offset, Part}}) ->
    form(?ERX_ATT_OPCODE_PREPARE_WRITE_REQ, [Handle, Offset, Part]);
att({request, {execute_write, cancel}}) -> form(?ERX_ATT_OPCODE_EXECUTE_WRITE_REQ, [?ERX_ATT_EXECUTE_CANCEL]);
att({request, {execute_write, write}}) -> form(?ERX_ATT_OPCODE_EXECUTE_WRITE_REQ, [?ERX_ATT_EXECUTE_WRITE]);
att({write_command, Handle, Value}) -> form(?ERX_ATT_OPCODE_WRITE_CMD, [Handle, Value]);
att(confirmation) -> form(?ERX_ATT_OPCODE_HANDLE_VALUE_CFM, []);
att({invalid, _Opcode}) -> <<"rejected">>;
att({unsupported, Opcode}) -> <<"unsupported ", (hex(<<Opcode>>))/binary>>;
att(ignored) -> <<"ignored">>.

%% erx_smp keeps multi-octet values most significant octet first; the form has them
%% in wire order, least significant first, and Bumble reads EDIV as an integer.
smp({pairing_request, Features}) -> form(?ERX_SMP_CODE_PAIRING_REQUEST, features(Features));
smp({pairing_response, Features}) -> form(?ERX_SMP_CODE_PAIRING_RESPONSE, features(Features));
smp({pairing_confirm, Value}) -> form(?ERX_SMP_CODE_PAIRING_CONFIRM, [wire(Value)]);
smp({pairing_random, Value}) -> form(?ERX_SMP_CODE_PAIRING_RANDOM, [wire(Value)]);
smp({pairing_failed, Reason}) -> form(?ERX_SMP_CODE_PAIRING_FAILED, [Reason]);
smp({encryption_information, Ltk}) -> form(?ERX_SMP_CODE_ENCRYPTION_INFORMATION, [wire(Ltk)]);
smp({central_identification, Ediv, Rand}) ->
    form(?ERX_SMP_CODE_CENTRAL_IDENTIFICATION, [binary:decode_unsigned(Ediv), wire(Rand)]);
smp({identity_information, Irk}) -> form(?ERX_SMP_CODE_IDENTITY_INFORMATION, [wire(Irk)]);
smp({identity_address_information, Type, Address}) ->
    form(?ERX_SMP_CODE_IDENTITY_ADDRESS_INFORMATION, [Type, wire(Address)]);
smp({security_request, Auth}) -> form(?ERX_SMP_CODE_SECURITY_REQUEST, [Auth]);
smp({pairing_public_key, {X, Y}}) -> form(?ERX_SMP_CODE_PAIRING_PUBLIC_KEY, [wire(X), wire(Y)]);
smp({pairing_dhkey_check, Value}) -> form(?ERX_SMP_CODE_PAIRING_DHKEY_CHECK, [wire(Value)]);
smp({pairing_keypress_notification, Type}) -> form(?ERX_SMP_CODE_PAIRING_KEYPRESS_NOTIFICATION, [Type]);
smp({invalid, _Code}) -> <<"rejected">>;
smp({reserved, Code}) -> <<"reserved ", (hex(<<Code>>))/binary>>;
smp(empty) -> <<"empty">>.

features(#{io := Io, oob := Oob, auth := Auth, max_key := MaxKey, initiator_keys := InitiatorKeys,
           responder_keys := ResponderKeys}) ->
    [Io, Oob, Auth, MaxKey, InitiatorKeys, ResponderKeys].

%% erx_att keeps a UUID as its octets on the wire, 2 or 16; erx_att:uuid128/1 widens
%% a 2-octet one onto the Bluetooth Base UUID, as Bumble does, still in wire order.
uuid(Type) -> erx_att:uuid128(Type).

wire(Value) -> list_to_binary(lists:reverse(binary_to_list(Value))).

form(Code, Fields) ->
    iolist_to_binary(lists:join(<<" ">>, [hex(<<Code>>) | [field(Field) || Field <- Fields]])).

field(Integer) when is_integer(Integer) -> integer_to_binary(Integer);
field(Octets) when is_binary(Octets) -> hex(Octets).

hex(Octets) -> binary:encode_hex(Octets, lowercase).
