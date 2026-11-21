%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_att).
-moduledoc """
The ATT PDU codec of the GATT server (docs/design-bluetooth.md, "The ATT server"), from
the Bluetooth Core Specification 6.3, Vol 3 Part F, section 3.4, whose codes
abi/formats/bluetooth.txt holds.

`decode/1` reads one PDU a phone sends on the ATT channel into a term: a request the server
answers, the one command it takes, a confirmation, or what the server answers or drops in
their place (3.3): `{unsupported, Opcode}`, a request it does not support, answered Request
Not Supported; `{invalid, Opcode}`, a request whose length or parameters do not fit its
layout, answered Invalid PDU; `ignored`, a command it does not take, or a PDU a server
sends, which is for the client erXos does not have. Each request is matched whole against
its layout, so nothing is read past a PDU. `encode/1` writes a PDU the server sends; the
server fits each within the bearer's MTU. `uuid128/1` widens a UUID for comparison, since
ATT compares every type as 128 bits (3.4.4.1). Nothing here makes an atom.
""".

-include("generated/erx_abi.hrl").

-export([decode/1, encode/1, uuid128/1, error_code/1]).
-export_type([handle/0, uuid/0, request/0, response/0, error/0]).

-doc "An attribute handle (3.2.2); 0 is never one.".
-type handle() :: 0..16#FFFF.
-doc "A UUID as ATT carries it: 2 or 16 octets, least significant first (Part G, 2.5.4).".
-type uuid() :: <<_:16>> | <<_:128>>.

-type request() :: {exchange_mtu, ClientMtu :: 0..16#FFFF}
                 | {find_information, Start :: handle(), End :: handle()}
                 | {find_by_type_value, Start :: handle(), End :: handle(), Type :: <<_:16>>, Value :: binary()}
                 | {read_by_type, Start :: handle(), End :: handle(), Type :: uuid()}
                 | {read, handle()}
                 | {read_blob, handle(), Offset :: 0..16#FFFF}
                 | {read_by_group_type, Start :: handle(), End :: handle(), Type :: uuid()}
                 | {write, handle(), Value :: binary()}
                 | {prepare_write, handle(), Offset :: 0..16#FFFF, Part :: binary()}
                 | {execute_write, cancel | write}.

-doc "The errors the server sends (Table 3.4), and a handler's Application Error code.".
-type error() :: invalid_handle | read_not_permitted | write_not_permitted | invalid_pdu
               | insufficient_authentication | request_not_supported | invalid_offset | prepare_queue_full
               | attribute_not_found | invalid_attribute_value_length | unlikely_error | insufficient_encryption
               | unsupported_group_type | value_not_allowed
               | ?ERX_ATT_APPLICATION_ERROR_MIN..?ERX_ATT_APPLICATION_ERROR_MAX.

-type response() :: {error, RequestOpcode :: 0..16#FF, handle(), error()}
                  | {exchange_mtu, ServerMtu :: 0..16#FFFF}
                  | {find_information, [{handle(), uuid()}]}
                  | {find_by_type_value, [{handle(), GroupEnd :: handle()}]}
                  | {read_by_type, [{handle(), binary()}]}
                  | {read, binary()}
                  | {read_blob, binary()}
                  | {read_by_group_type, [{handle(), GroupEnd :: handle(), binary()}]}
                  | write
                  | {prepare_write, handle(), Offset :: 0..16#FFFF, binary()}
                  | execute_write
                  | {notification, handle(), binary()}
                  | {indication, handle(), binary()}.

%% The PDUs a server sends (3.4): on arrival they are for the client, which erXos does not have.
-define(IS_SERVER_PDU(Op), (Op =:= ?ERX_ATT_OPCODE_ERROR_RSP orelse Op =:= ?ERX_ATT_OPCODE_EXCHANGE_MTU_RSP
                            orelse Op =:= ?ERX_ATT_OPCODE_FIND_INFORMATION_RSP
                            orelse Op =:= ?ERX_ATT_OPCODE_FIND_BY_TYPE_VALUE_RSP
                            orelse Op =:= ?ERX_ATT_OPCODE_READ_BY_TYPE_RSP orelse Op =:= ?ERX_ATT_OPCODE_READ_RSP
                            orelse Op =:= ?ERX_ATT_OPCODE_READ_BLOB_RSP orelse Op =:= ?ERX_ATT_OPCODE_READ_MULTIPLE_RSP
                            orelse Op =:= ?ERX_ATT_OPCODE_READ_BY_GROUP_TYPE_RSP orelse Op =:= ?ERX_ATT_OPCODE_WRITE_RSP
                            orelse Op =:= ?ERX_ATT_OPCODE_PREPARE_WRITE_RSP
                            orelse Op =:= ?ERX_ATT_OPCODE_EXECUTE_WRITE_RSP
                            orelse Op =:= ?ERX_ATT_OPCODE_HANDLE_VALUE_NTF orelse Op =:= ?ERX_ATT_OPCODE_HANDLE_VALUE_IND
                            orelse Op =:= ?ERX_ATT_OPCODE_READ_MULTIPLE_VARIABLE_RSP
                            orelse Op =:= ?ERX_ATT_OPCODE_MULTIPLE_HANDLE_VALUE_NTF)).

-doc "Reads one PDU from a phone.".
-spec decode(binary()) -> {request, request()} | {write_command, handle(), binary()} | confirmation
                          | {unsupported, 0..16#FF} | {invalid, 0..16#FF} | ignored.
decode(<<?ERX_ATT_OPCODE_EXCHANGE_MTU_REQ, Mtu:16/little>>) ->
    {request, {exchange_mtu, Mtu}};
decode(<<?ERX_ATT_OPCODE_FIND_INFORMATION_REQ, Start:16/little, End:16/little>>) ->
    {request, {find_information, Start, End}};
decode(<<?ERX_ATT_OPCODE_FIND_BY_TYPE_VALUE_REQ, Start:16/little, End:16/little, Type:2/binary, Value/binary>>) ->
    {request, {find_by_type_value, Start, End, Type, Value}};
decode(<<?ERX_ATT_OPCODE_READ_BY_TYPE_REQ, Start:16/little, End:16/little, Type/binary>>)
  when byte_size(Type) =:= 2; byte_size(Type) =:= 16 ->
    {request, {read_by_type, Start, End, Type}};
decode(<<?ERX_ATT_OPCODE_READ_REQ, Handle:16/little>>) ->
    {request, {read, Handle}};
decode(<<?ERX_ATT_OPCODE_READ_BLOB_REQ, Handle:16/little, Offset:16/little>>) ->
    {request, {read_blob, Handle, Offset}};
decode(<<?ERX_ATT_OPCODE_READ_BY_GROUP_TYPE_REQ, Start:16/little, End:16/little, Type/binary>>)
  when byte_size(Type) =:= 2; byte_size(Type) =:= 16 ->
    {request, {read_by_group_type, Start, End, Type}};
decode(<<?ERX_ATT_OPCODE_WRITE_REQ, Handle:16/little, Value/binary>>) ->
    {request, {write, Handle, Value}};
decode(<<?ERX_ATT_OPCODE_PREPARE_WRITE_REQ, Handle:16/little, Offset:16/little, Part/binary>>) ->
    {request, {prepare_write, Handle, Offset, Part}};
decode(<<?ERX_ATT_OPCODE_EXECUTE_WRITE_REQ, ?ERX_ATT_EXECUTE_CANCEL>>) ->
    {request, {execute_write, cancel}};
decode(<<?ERX_ATT_OPCODE_EXECUTE_WRITE_REQ, ?ERX_ATT_EXECUTE_WRITE>>) ->
    {request, {execute_write, write}};
decode(<<?ERX_ATT_OPCODE_WRITE_CMD, Handle:16/little, Value/binary>>) ->
    {write_command, Handle, Value};
decode(<<?ERX_ATT_OPCODE_HANDLE_VALUE_CFM>>) ->
    confirmation;
decode(<<Op, _/binary>>) when Op band ?ERX_ATT_COMMAND_FLAG =/= 0; ?IS_SERVER_PDU(Op) ->
    ignored;
decode(<<Op, _/binary>>) when Op =:= ?ERX_ATT_OPCODE_EXCHANGE_MTU_REQ; Op =:= ?ERX_ATT_OPCODE_FIND_INFORMATION_REQ;
                              Op =:= ?ERX_ATT_OPCODE_FIND_BY_TYPE_VALUE_REQ; Op =:= ?ERX_ATT_OPCODE_READ_BY_TYPE_REQ;
                              Op =:= ?ERX_ATT_OPCODE_READ_REQ; Op =:= ?ERX_ATT_OPCODE_READ_BLOB_REQ;
                              Op =:= ?ERX_ATT_OPCODE_READ_BY_GROUP_TYPE_REQ; Op =:= ?ERX_ATT_OPCODE_WRITE_REQ;
                              Op =:= ?ERX_ATT_OPCODE_PREPARE_WRITE_REQ; Op =:= ?ERX_ATT_OPCODE_EXECUTE_WRITE_REQ ->
    {invalid, Op};
decode(<<?ERX_ATT_OPCODE_HANDLE_VALUE_CFM, _/binary>>) ->
    ignored;
decode(<<Op, _/binary>>) ->
    {unsupported, Op};
decode(<<>>) ->
    ignored.

-doc "Writes one PDU the server sends.".
-spec encode(response()) -> binary().
encode({error, Opcode, Handle, Error}) ->
    <<?ERX_ATT_OPCODE_ERROR_RSP, Opcode, Handle:16/little, (error_code(Error))>>;
encode({exchange_mtu, Mtu}) ->
    <<?ERX_ATT_OPCODE_EXCHANGE_MTU_RSP, Mtu:16/little>>;
encode({find_information, [{_, Uuid} | _] = Pairs}) ->
    Format = case byte_size(Uuid) of
                 2 -> ?ERX_ATT_INFORMATION_FORMAT_UUID16;
                 16 -> ?ERX_ATT_INFORMATION_FORMAT_UUID128
             end,
    <<?ERX_ATT_OPCODE_FIND_INFORMATION_RSP, Format, << <<H:16/little, U/binary>> || {H, U} <- Pairs >>/binary>>;
encode({find_by_type_value, Ranges}) ->
    <<?ERX_ATT_OPCODE_FIND_BY_TYPE_VALUE_RSP, << <<H:16/little, E:16/little>> || {H, E} <- Ranges >>/binary>>;
encode({read_by_type, [{_, Value} | _] = Pairs}) ->
    <<?ERX_ATT_OPCODE_READ_BY_TYPE_RSP, (2 + byte_size(Value)),
      << <<H:16/little, V/binary>> || {H, V} <- Pairs >>/binary>>;
encode({read, Value}) ->
    <<?ERX_ATT_OPCODE_READ_RSP, Value/binary>>;
encode({read_blob, Part}) ->
    <<?ERX_ATT_OPCODE_READ_BLOB_RSP, Part/binary>>;
encode({read_by_group_type, [{_, _, Value} | _] = Groups}) ->
    <<?ERX_ATT_OPCODE_READ_BY_GROUP_TYPE_RSP, (4 + byte_size(Value)),
      << <<H:16/little, E:16/little, V/binary>> || {H, E, V} <- Groups >>/binary>>;
encode(write) ->
    <<?ERX_ATT_OPCODE_WRITE_RSP>>;
encode({prepare_write, Handle, Offset, Part}) ->
    <<?ERX_ATT_OPCODE_PREPARE_WRITE_RSP, Handle:16/little, Offset:16/little, Part/binary>>;
encode(execute_write) ->
    <<?ERX_ATT_OPCODE_EXECUTE_WRITE_RSP>>;
encode({notification, Handle, Value}) ->
    <<?ERX_ATT_OPCODE_HANDLE_VALUE_NTF, Handle:16/little, Value/binary>>;
encode({indication, Handle, Value}) ->
    <<?ERX_ATT_OPCODE_HANDLE_VALUE_IND, Handle:16/little, Value/binary>>.

-doc "An error's code (Table 3.4).".
-spec error_code(error()) -> 0..16#FF.
error_code(invalid_handle) -> ?ERX_ATT_ERROR_INVALID_HANDLE;
error_code(read_not_permitted) -> ?ERX_ATT_ERROR_READ_NOT_PERMITTED;
error_code(write_not_permitted) -> ?ERX_ATT_ERROR_WRITE_NOT_PERMITTED;
error_code(invalid_pdu) -> ?ERX_ATT_ERROR_INVALID_PDU;
error_code(insufficient_authentication) -> ?ERX_ATT_ERROR_INSUFFICIENT_AUTHENTICATION;
error_code(request_not_supported) -> ?ERX_ATT_ERROR_REQUEST_NOT_SUPPORTED;
error_code(invalid_offset) -> ?ERX_ATT_ERROR_INVALID_OFFSET;
error_code(prepare_queue_full) -> ?ERX_ATT_ERROR_PREPARE_QUEUE_FULL;
error_code(attribute_not_found) -> ?ERX_ATT_ERROR_ATTRIBUTE_NOT_FOUND;
error_code(invalid_attribute_value_length) -> ?ERX_ATT_ERROR_INVALID_ATTRIBUTE_VALUE_LENGTH;
error_code(unlikely_error) -> ?ERX_ATT_ERROR_UNLIKELY_ERROR;
error_code(insufficient_encryption) -> ?ERX_ATT_ERROR_INSUFFICIENT_ENCRYPTION;
error_code(unsupported_group_type) -> ?ERX_ATT_ERROR_UNSUPPORTED_GROUP_TYPE;
error_code(value_not_allowed) -> ?ERX_ATT_ERROR_VALUE_NOT_ALLOWED;
error_code(Code) when Code >= ?ERX_ATT_APPLICATION_ERROR_MIN, Code =< ?ERX_ATT_APPLICATION_ERROR_MAX -> Code.

-doc """
A UUID as 128 bits: a 16-bit one placed in the Bluetooth Base UUID,
00000000-0000-1000-8000-00805F9B34FB (Vol 3 Part B, 2.5.1, which was not read; the value
is Bumble v0.0.237's, bumble/core.py, lines 202 and 212, and unverified against Part B).
""".
-spec uuid128(uuid()) -> <<_:128>>.
uuid128(<<Short:2/binary>>) ->
    <<16#FB, 16#34, 16#9B, 16#5F, 16#80, 16#00, 16#00, 16#80, 16#00, 16#10, 16#00, 16#00, Short/binary, 0, 0>>;
uuid128(<<_:16/binary>> = Long) ->
    Long.
