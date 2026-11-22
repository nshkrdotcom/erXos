%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_bumble_decode).
-moduledoc """
erXos's side of the codec comparison with Bumble (test/host/erx_bt_bumble_test.rb,
docs/design-bluetooth.md, "Fuzz targets"). Reads the corpus, lines of `CODEC HEX`,
decodes each frame and writes one line per frame in the canonical form
test/bt/bumble_decode.py writes from Bumble's decoders, whose documentation
defines it:

* att, smp: erx_att:decode/1, erx_smp:decode/1. `rejected` for a frame the
  decoder answers invalid, else the code and each field in the order the
  specification lays it out. A frame the decoder reads as no PDU of its side is
  named for what it answers: `unsupported OP`, `ignored`, `reserved CODE` or
  `empty`.
* hci: erx_hci:event/2 on the frame's first octet and the rest, and for a
  Command Complete erx_hci:return/2 on its return parameters, for the command
  its opcode names. `rejected` for a malformed event or return, else the code
  and the fields erx_hci keeps.
* l2cap: erx_l2cap:signal/1. `drop`, or `reject ID` for the Command Reject it
  answers with.
* att-op: erx_att:decode/1 on an opcode alone. `takes` for an opcode it reads
  as a PDU the server receives, whole or not, `refuses` for an unsupported
  request, `ignores` for one it drops.

Integers are in decimal, octet strings in wire order in hex, and a UUID as its
128-bit form in wire order in hex.
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
canonical(<<"smp">>, Frame) -> smp(erx_smp:decode(Frame));
canonical(<<"hci">>, <<Code, Parameters/binary>>) -> hci(erx_hci:event(Code, Parameters));
canonical(<<"l2cap">>, Frame) -> l2cap(erx_l2cap:signal(Frame));
canonical(<<"att-op">>, <<_Op>> = Frame) -> att_op(erx_att:decode(Frame)).

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

hci({command_complete, Allowed, Opcode, Return}) ->
    case maps:find(Opcode, commands()) of
        {ok, Name} -> command_complete(Allowed, Opcode, Name, erx_hci:return(Name, Return));
        error -> form(?ERX_HCI_EVENT_COMMAND_COMPLETE, [Allowed, Opcode, unnamed])
    end;
hci({command_status, Status, Allowed, Opcode}) -> form(?ERX_HCI_EVENT_COMMAND_STATUS, [Status, Allowed, Opcode]);
hci({disconnection_complete, Status, Handle, Reason}) ->
    form(?ERX_HCI_EVENT_DISCONNECTION_COMPLETE, [Status, Handle, Reason]);
hci({encryption_change, Status, Handle, Enabled}) -> form(?ERX_HCI_EVENT_ENCRYPTION_CHANGE, [Status, Handle, Enabled]);
hci({encryption_key_refresh_complete, Status, Handle}) ->
    form(?ERX_HCI_EVENT_ENCRYPTION_KEY_REFRESH_COMPLETE, [Status, Handle]);
hci({hardware_error, Code}) -> form(?ERX_HCI_EVENT_HARDWARE_ERROR, [Code]);
hci({number_of_completed_packets, Pairs}) ->
    form(?ERX_HCI_EVENT_NUMBER_OF_COMPLETED_PACKETS, lists:append([[Handle, Packets] || {Handle, Packets} <- Pairs]));
hci({le_connection_complete, {failed, Status}}) -> le_form(?ERX_HCI_LE_SUBEVENT_CONNECTION_COMPLETE, [failed, Status]);
hci({le_connection_complete, Handle, {Type, Address}}) ->
    le_form(?ERX_HCI_LE_SUBEVENT_CONNECTION_COMPLETE, [Handle, peer_type(Type), wire(Address)]);
hci({le_connection_update_complete, Status, Handle}) ->
    le_form(?ERX_HCI_LE_SUBEVENT_CONNECTION_UPDATE_COMPLETE, [Status, Handle]);
hci({le_long_term_key_request, Handle, Random, Ediv}) ->
    le_form(?ERX_HCI_LE_SUBEVENT_LONG_TERM_KEY_REQUEST, [Handle, Random, Ediv]);
hci({unknown, {le_meta, Subevent}}) -> <<"unknown ", (hex(<<?ERX_HCI_EVENT_LE_META, Subevent>>))/binary>>;
hci({unknown, Code}) -> <<"unknown ", (hex(<<Code>>))/binary>>;
hci(malformed) -> <<"rejected">>.

command_complete(_Allowed, _Opcode, _Name, malformed) -> <<"rejected">>;
command_complete(Allowed, Opcode, _Name, {failed, Status}) ->
    form(?ERX_HCI_EVENT_COMMAND_COMPLETE, [Allowed, Opcode, failed, Status]);
command_complete(Allowed, Opcode, Name, {ok, Value}) ->
    form(?ERX_HCI_EVENT_COMMAND_COMPLETE, [Allowed, Opcode, ok | returned(Name, Value)]).

%% The values erx_hci:return/2 reads for each command: Read Local Version's in the
%% specification's order, a BD_ADDR most significant octet first, a buffer size's
%% length and count, a bit map, a handle, or none.
returned(read_local_version, #{hci_version := HciVersion, hci_subversion := HciSubversion,
                               lmp_version := LmpVersion, company := Company, lmp_subversion := LmpSubversion}) ->
    [HciVersion, HciSubversion, LmpVersion, Company, LmpSubversion];
returned(read_bd_addr, Address) -> [wire(Address)];
returned(Name, {Length, Packets}) when Name =:= read_buffer_size; Name =:= le_read_buffer_size -> [Length, Packets];
returned(Name, Bits) when Name =:= read_local_commands; Name =:= le_read_features -> [Bits];
returned(Name, Handle) when Name =:= le_long_term_key_request_reply;
                            Name =:= le_long_term_key_request_negative_reply ->
    [Handle];
returned(_Name, done) -> [].

%% The commands the host sends whose Command Complete erx_hci:return/2 reads, by
%% opcode.
commands() ->
    maps:from_list([{erx_hci:opcode(Name), Name}
                    || Name <- [reset, read_local_version, read_local_commands, read_buffer_size, read_bd_addr,
                                le_read_buffer_size, le_read_features, set_event_mask, le_set_event_mask,
                                host_buffer_size, le_set_random_address, le_set_advertising_parameters,
                                le_set_advertising_data, le_set_scan_response_data, le_set_advertising_enable,
                                le_long_term_key_request_reply, le_long_term_key_request_negative_reply]]).

peer_type(public) -> ?ERX_HCI_PEER_ADDRESS_TYPE_PUBLIC;
peer_type(random) -> ?ERX_HCI_PEER_ADDRESS_TYPE_RANDOM.

le_form(Subevent, Fields) -> form(<<?ERX_HCI_EVENT_LE_META, Subevent>>, Fields).

l2cap(drop) -> <<"drop">>;
l2cap({reply, <<?ERX_L2CAP_SIGNAL_COMMAND_REJECT, Identifier, _/binary>>}) -> joined(<<"reject">>, [Identifier]).

att_op({unsupported, _Op}) -> <<"refuses">>;
att_op(ignored) -> <<"ignores">>;
att_op(_Taken) -> <<"takes">>.

features(#{io := Io, oob := Oob, auth := Auth, max_key := MaxKey, initiator_keys := InitiatorKeys,
           responder_keys := ResponderKeys}) ->
    [Io, Oob, Auth, MaxKey, InitiatorKeys, ResponderKeys].

%% erx_att keeps a UUID as its octets on the wire, 2 or 16; erx_att:uuid128/1 widens
%% a 2-octet one onto the Bluetooth Base UUID, as Bumble does, still in wire order.
uuid(Type) -> erx_att:uuid128(Type).

wire(Value) -> list_to_binary(lists:reverse(binary_to_list(Value))).

%% A code, one octet or an LE event's two, in hex, then the fields.
form(Code, Fields) when is_integer(Code) -> form(<<Code>>, Fields);
form(Code, Fields) -> joined(hex(Code), Fields).

%% A field is an integer, octets, or a word such as `ok`.
joined(Head, Fields) -> iolist_to_binary(lists:join(<<" ">>, [Head | [field(Field) || Field <- Fields]])).

field(Integer) when is_integer(Integer) -> integer_to_binary(Integer);
field(Octets) when is_binary(Octets) -> hex(Octets);
field(Word) when is_atom(Word) -> atom_to_binary(Word).

hex(Octets) -> binary:encode_hex(Octets, lowercase).
