%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_smp).
-moduledoc """
The Security Manager Protocol's PDU codec (docs/design-bluetooth.md, "Secure
Connections only"), from the Bluetooth Core Specification 6.3, Vol 3 Part H, section
3, whose codes abi/formats/bluetooth.txt holds.

`decode/1` reads one PDU of the Security Manager channel, which a radio peer writes:
every command is checked whole against its section's layout, so a PDU of the wrong
length is `{invalid, Code}` (Invalid Parameters is a command length that is invalid,
Table 3.7), a code reserved for future use is `{reserved, Code}`, which the responder
ignores (3.3), and an empty PDU is `empty`. `encode/1` writes any PDU `decode/1`
gives. Nothing here makes an atom.

A multi-octet field travels least significant octet first (1.2.1); a PDU term holds
it most significant octet first, the order of the specification's notation and of
`erx_smp_crypto`. Every one-octet field keeps its number as sent, so a reserved value
reaches `erx_smp_core`, which judges it, and AuthReq enters f6 exactly as it
travelled, its RFU bits included (2.2.8); `auth/1` and `keys/1` read the bit fields of
AuthReq and of the key distribution fields, and `auth_octet/1` and `keys_octet/1`
write them.
""".

-include("generated/erx_abi.hrl").

-export([decode/1, encode/1, auth/1, auth_octet/1, keys/1, keys_octet/1]).
-export_type([pdu/0, features/0, auth/0, keys/0, decoded/0]).

-doc "AuthReq's fields (3.5.1, Figure 3.3); its two RFU bits are not kept.".
-type auth() :: #{bonding := 0..3, mitm := boolean(), sc := boolean(), keypress := boolean(), ct2 := boolean()}.
-doc "A Key Distribution / Generation field (3.6.1, Figure 3.11); its RFU and previously used bits are not kept.".
-type keys() :: #{enc := boolean(), id := boolean(), link := boolean()}.
-doc "The fields of a Pairing Request or Pairing Response (3.5.1, 3.5.2), each octet as sent.".
-type features() :: #{io := byte(), oob := byte(), auth := byte(), max_key := byte(),
                      initiator_keys := byte(), responder_keys := byte()}.
-type value() :: erx_smp_crypto:value().
-type pdu() :: {pairing_request, features()}
             | {pairing_response, features()}
             | {pairing_confirm, value()}
             | {pairing_random, value()}
             | {pairing_failed, Reason :: byte()}
             | {encryption_information, Ltk :: value()}
             | {central_identification, Ediv :: <<_:16>>, Rand :: <<_:64>>}
             | {identity_information, Irk :: value()}
             | {identity_address_information, Type :: byte(), Address :: <<_:48>>}
             | {security_request, Auth :: byte()}
             | {pairing_public_key, erx_smp_crypto:public_key()}
             | {pairing_dhkey_check, value()}
             | {pairing_keypress_notification, Type :: byte()}.
-type decoded() :: pdu() | {invalid, Code :: byte()} | {reserved, Code :: byte()} | empty.

-doc "Decodes one PDU of the Security Manager channel.".
-spec decode(binary()) -> decoded().
decode(<<>>) -> empty;
decode(<<Code, Data/binary>>) -> data(Code, Data).

%% Each command's Data, by its code (3.5, 3.6); a known code whose Data has any other
%% length is invalid. Code 0x0A, "previously used", is reserved like every code past
%% the last.
data(?ERX_SMP_CODE_PAIRING_REQUEST, <<_:6/binary>> = Features) -> {pairing_request, features(Features)};
data(?ERX_SMP_CODE_PAIRING_RESPONSE, <<_:6/binary>> = Features) -> {pairing_response, features(Features)};
data(?ERX_SMP_CODE_PAIRING_CONFIRM, <<Value:16/binary>>) -> {pairing_confirm, reversed(Value)};
data(?ERX_SMP_CODE_PAIRING_RANDOM, <<Value:16/binary>>) -> {pairing_random, reversed(Value)};
data(?ERX_SMP_CODE_PAIRING_FAILED, <<Reason>>) -> {pairing_failed, Reason};
data(?ERX_SMP_CODE_ENCRYPTION_INFORMATION, <<Ltk:16/binary>>) -> {encryption_information, reversed(Ltk)};
data(?ERX_SMP_CODE_CENTRAL_IDENTIFICATION, <<Ediv:2/binary, Rand:8/binary>>) ->
    {central_identification, reversed(Ediv), reversed(Rand)};
data(?ERX_SMP_CODE_IDENTITY_INFORMATION, <<Irk:16/binary>>) -> {identity_information, reversed(Irk)};
data(?ERX_SMP_CODE_IDENTITY_ADDRESS_INFORMATION, <<Type, Address:6/binary>>) ->
    {identity_address_information, Type, reversed(Address)};
data(?ERX_SMP_CODE_SECURITY_REQUEST, <<Auth>>) -> {security_request, Auth};
data(?ERX_SMP_CODE_PAIRING_PUBLIC_KEY, <<X:32/binary, Y:32/binary>>) ->
    {pairing_public_key, {reversed(X), reversed(Y)}};
data(?ERX_SMP_CODE_PAIRING_DHKEY_CHECK, <<Value:16/binary>>) -> {pairing_dhkey_check, reversed(Value)};
data(?ERX_SMP_CODE_PAIRING_KEYPRESS_NOTIFICATION, <<Type>>) -> {pairing_keypress_notification, Type};
data(Code, _Data) when Code >= ?ERX_SMP_CODE_PAIRING_REQUEST, Code =< ?ERX_SMP_CODE_PAIRING_KEYPRESS_NOTIFICATION,
                       Code =/= 16#0A ->
    {invalid, Code};
data(Code, _Data) -> {reserved, Code}.

%% Pairing Request and Pairing Response share their layout (Figures 3.2 and 3.4).
features(<<Io, Oob, Auth, MaxKey, InitiatorKeys, ResponderKeys>>) ->
    #{io => Io, oob => Oob, auth => Auth, max_key => MaxKey, initiator_keys => InitiatorKeys,
      responder_keys => ResponderKeys}.

-doc "Encodes a PDU.".
-spec encode(pdu()) -> binary().
encode({pairing_request, Features}) -> <<?ERX_SMP_CODE_PAIRING_REQUEST, (features_octets(Features))/binary>>;
encode({pairing_response, Features}) -> <<?ERX_SMP_CODE_PAIRING_RESPONSE, (features_octets(Features))/binary>>;
encode({pairing_confirm, <<_:128>> = Value}) -> <<?ERX_SMP_CODE_PAIRING_CONFIRM, (reversed(Value))/binary>>;
encode({pairing_random, <<_:128>> = Value}) -> <<?ERX_SMP_CODE_PAIRING_RANDOM, (reversed(Value))/binary>>;
encode({pairing_failed, Reason}) -> <<?ERX_SMP_CODE_PAIRING_FAILED, Reason>>;
encode({encryption_information, <<_:128>> = Ltk}) ->
    <<?ERX_SMP_CODE_ENCRYPTION_INFORMATION, (reversed(Ltk))/binary>>;
encode({central_identification, <<_:16>> = Ediv, <<_:64>> = Rand}) ->
    <<?ERX_SMP_CODE_CENTRAL_IDENTIFICATION, (reversed(Ediv))/binary, (reversed(Rand))/binary>>;
encode({identity_information, <<_:128>> = Irk}) -> <<?ERX_SMP_CODE_IDENTITY_INFORMATION, (reversed(Irk))/binary>>;
encode({identity_address_information, Type, <<_:48>> = Address}) ->
    <<?ERX_SMP_CODE_IDENTITY_ADDRESS_INFORMATION, Type, (reversed(Address))/binary>>;
encode({security_request, Auth}) -> <<?ERX_SMP_CODE_SECURITY_REQUEST, Auth>>;
encode({pairing_public_key, {<<_:256>> = X, <<_:256>> = Y}}) ->
    <<?ERX_SMP_CODE_PAIRING_PUBLIC_KEY, (reversed(X))/binary, (reversed(Y))/binary>>;
encode({pairing_dhkey_check, <<_:128>> = Value}) -> <<?ERX_SMP_CODE_PAIRING_DHKEY_CHECK, (reversed(Value))/binary>>;
encode({pairing_keypress_notification, Type}) -> <<?ERX_SMP_CODE_PAIRING_KEYPRESS_NOTIFICATION, Type>>.

features_octets(#{io := Io, oob := Oob, auth := Auth, max_key := MaxKey,
                  initiator_keys := InitiatorKeys, responder_keys := ResponderKeys}) ->
    <<Io, Oob, Auth, MaxKey, InitiatorKeys, ResponderKeys>>.

-doc "AuthReq's fields (Figure 3.3).".
-spec auth(byte()) -> auth().
auth(Octet) ->
    <<_Rfu:2, Ct2:1, Keypress:1, Sc:1, Mitm:1, Bonding:2>> = <<Octet>>,
    #{bonding => Bonding, mitm => Mitm =:= 1, sc => Sc =:= 1, keypress => Keypress =:= 1, ct2 => Ct2 =:= 1}.

-doc "AuthReq's octet, its RFU bits zero (Figure 3.3).".
-spec auth_octet(auth()) -> byte().
auth_octet(#{bonding := Bonding, mitm := Mitm, sc := Sc, keypress := Keypress, ct2 := Ct2}) ->
    <<Octet>> = <<0:2, (bit(Ct2)):1, (bit(Keypress)):1, (bit(Sc)):1, (bit(Mitm)):1, Bonding:2>>,
    Octet.

-doc "A Key Distribution / Generation field's flags (Figure 3.11).".
-spec keys(byte()) -> keys().
keys(Octet) ->
    <<_Rfu:4, Link:1, _PreviouslyUsed:1, Id:1, Enc:1>> = <<Octet>>,
    #{enc => Enc =:= 1, id => Id =:= 1, link => Link =:= 1}.

-doc "A Key Distribution / Generation field's octet, its other bits zero (Figure 3.11).".
-spec keys_octet(keys()) -> byte().
keys_octet(#{enc := Enc, id := Id, link := Link}) ->
    <<Octet>> = <<0:4, (bit(Link)):1, 0:1, (bit(Id)):1, (bit(Enc)):1>>,
    Octet.

bit(true) -> 1;
bit(false) -> 0.

%% A field's octets in the other order: the wire's least significant first to the
%% term's most significant first, and back.
reversed(Field) -> list_to_binary(lists:reverse(binary_to_list(Field))).
