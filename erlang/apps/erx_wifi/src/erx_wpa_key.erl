%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The EAPOL-Key codec (docs/design-wifi.md, "The supplicant" and "Untrusted input"):
%% decode/1 reads a frame an access point sent through the chip, key_data/1 reads its
%% key data's elements and KDEs once erx_wpa_kdf has unwrapped them, and build/4 makes
%% the station's messages 2 and 4 and group message 2 with their MIC. Every byte read
%% here is hostile: each length is checked before it is used, nothing creates an atom,
%% and a malformed frame is an error naming the rule it broke, never a crash.
%%
%% The layouts are abi/formats/ieee80211.txt's, read through erx_abi_packed. This
%% module decides nothing about the handshake: which message a frame is, its replay
%% counter's order and its MIC's validity are the station's, which holds the keys.
-module(erx_wpa_key).

-include("generated/erx_abi.hrl").

-export([decode/1, mic_input/1, key_data/1, build/4]).
-export_type([key/0, key_data/0]).

%% A decoded EAPOL-Key frame: Key Information's fields, the counters, the nonce and
%% MIC as sent, the key data still as sent (encrypted when `encrypted`), and `frame`,
%% the frame's bytes through its key data, which the MIC covers.
-type key() :: #{descriptor_version := 0..7, pairwise := boolean(), install := boolean(), ack := boolean(),
                 mic_present := boolean(), secure := boolean(), error := boolean(),
                 request := boolean(), encrypted := boolean(), key_length := non_neg_integer(),
                 replay_counter := non_neg_integer(), nonce := <<_:256>>, rsc := non_neg_integer(),
                 mic := <<_:128>>, data := binary(), frame := binary()}.
%% The key data the station uses: the RSN element and RSNXE, each a whole element
%% with its header, as the scan's are compared byte for byte, and the GTK and IGTK
%% KDEs, or none of each.
-type key_data() :: #{rsn := binary() | none, rsnxe := binary() | none,
                      gtk := #{id := 0..3, tx := boolean(), key := <<_:128>>} | none,
                      igtk := #{id := 4..5, ipn := non_neg_integer(), key := <<_:128>>} | none}.
-type error() :: short | version | type | body_length | descriptor | data_length
               | truncated | overrun | {length, atom()} | {duplicate, atom()} | {key_id, igtk}.

-define(EAPOL_HEADER, ?ERX_EAPOL_KEY_OFF_DESCRIPTOR).

%% A received EAPOL frame to its EAPOL-Key fields, or the rule it broke. Bytes after
%% the EAPOL body, an Ethernet frame's padding, are not part of the frame.
-spec decode(binary()) -> {ok, key()} | {error, error()}.
decode(Bytes) when is_binary(Bytes) ->
    try
        {ok, fields(Bytes)}
    catch
        throw:{malformed, Rule} -> {error, Rule}
    end.

fields(Bytes) ->
    require(byte_size(Bytes) >= ?ERX_EAPOL_KEY_SIZE, short),
    <<Fixed:?ERX_EAPOL_KEY_SIZE/binary, _/binary>> = Bytes,
    #{version := Version, type := Type, body_length := BodyLength, descriptor := Descriptor,
      key_info := Info, key_length := KeyLength, replay_counter := Counter, nonce := Nonce,
      rsc := <<Rsc:64/little>>, mic := Mic, data_length := DataLength} =
        erx_abi_packed:decode(erx_eapol_key, Fixed),
    require(Version >= 1 andalso Version =< ?ERX_EAPOL_VERSION_MAX, version),
    require(Type =:= ?ERX_EAPOL_TYPE_KEY, type),
    require(?EAPOL_HEADER + BodyLength =< byte_size(Bytes), body_length),
    require(Descriptor =:= ?ERX_EAPOL_KEY_DESCRIPTOR_RSN, descriptor),
    require(?ERX_EAPOL_KEY_SIZE + DataLength =< ?EAPOL_HEADER + BodyLength, data_length),
    <<Frame:(?ERX_EAPOL_KEY_SIZE + DataLength)/binary, _/binary>> = Bytes,
    <<_:?ERX_EAPOL_KEY_SIZE/binary, Data/binary>> = Frame,
    #{descriptor_version => Info band ?ERX_WPA_KEY_INFO_VERSION_MASK,
      pairwise => bit(Info, ?ERX_WPA_KEY_INFO_PAIRWISE),
      install => bit(Info, ?ERX_WPA_KEY_INFO_INSTALL),
      ack => bit(Info, ?ERX_WPA_KEY_INFO_ACK),
      mic_present => bit(Info, ?ERX_WPA_KEY_INFO_MIC),
      secure => bit(Info, ?ERX_WPA_KEY_INFO_SECURE),
      error => bit(Info, ?ERX_WPA_KEY_INFO_ERROR),
      request => bit(Info, ?ERX_WPA_KEY_INFO_REQUEST),
      encrypted => bit(Info, ?ERX_WPA_KEY_INFO_ENCRYPTED),
      key_length => KeyLength, replay_counter => Counter, nonce => Nonce, rsc => Rsc,
      mic => Mic, data => Data, frame => Frame}.

%% The bytes the MIC covers: the frame with its MIC field zero.
-spec mic_input(key()) -> binary().
mic_input(#{frame := Frame}) ->
    <<Head:?ERX_EAPOL_KEY_OFF_MIC/binary, _:?ERX_WPA_MIC_SIZE/binary, Tail/binary>> = Frame,
    <<Head/binary, 0:(?ERX_WPA_MIC_SIZE * 8), Tail/binary>>.

%% Plain key data, as sent or as unwrapped, to the elements the station uses. A KDE of
%% another type or OUI is skipped; a GTK or IGTK KDE of a length other than CCMP-128's
%% and BIP-CMAC-128's, or a second one, is an error. The padding of encrypted key
%% data, 0xdd then zero bytes, is the sequence's end marker in
%% abi/formats/ieee80211.txt, so the walk reads nothing after its start.
-spec key_data(binary()) -> {ok, key_data()} | {error, error()}.
key_data(Bytes) when is_binary(Bytes) ->
    try
        Elements = case erx_abi_packed:decode_elements(wpa_key_data, Bytes) of
                       {ok, Known} -> Known;
                       {error, Rule} -> throw({malformed, Rule})
                   end,
        {ok, lists:foldl(fun take/2, #{rsn => none, rsnxe => none, gtk => none, igtk => none}, Elements)}
    catch
        throw:{malformed, Broken} -> {error, Broken}
    end.

take({rsn, Body}, Data) ->
    Data#{rsn := <<?ERX_WPA_KEY_DATA_TAG_RSN, (byte_size(Body)), Body/binary>>};
take({rsnxe, Body}, Data) ->
    Data#{rsnxe := <<?ERX_WPA_KEY_DATA_TAG_RSNXE, (byte_size(Body)), Body/binary>>};
take({vendor, <<?ERX_WPA_KDE_OUI:24, Type, Kde/binary>>}, Data) when Type =:= ?ERX_WPA_KDE_TYPE_GTK ->
    require(byte_size(Kde) =:= ?ERX_WPA_GTK_KDE_SIZE, {length, gtk}),
    require(maps:get(gtk, Data) =:= none, {duplicate, gtk}),
    #{key_info := KeyInfo, gtk := Gtk} = erx_abi_packed:decode(erx_wpa_gtk_kde, Kde),
    Data#{gtk := #{id => KeyInfo band ?ERX_WPA_GTK_KDE_ID_MASK, tx => bit(KeyInfo, ?ERX_WPA_GTK_KDE_TX), key => Gtk}};
take({vendor, <<?ERX_WPA_KDE_OUI:24, Type, Kde/binary>>}, Data) when Type =:= ?ERX_WPA_KDE_TYPE_IGTK ->
    require(byte_size(Kde) =:= ?ERX_WPA_IGTK_KDE_SIZE, {length, igtk}),
    require(maps:get(igtk, Data) =:= none, {duplicate, igtk}),
    #{key_id := Id, ipn := <<Ipn:48/little>>, igtk := Igtk} = erx_abi_packed:decode(erx_wpa_igtk_kde, Kde),
    require(Id >= ?ERX_WPA_IGTK_KEY_ID_MIN andalso Id =< ?ERX_WPA_IGTK_KEY_ID_MAX, {key_id, igtk}),
    Data#{igtk := #{id => Id, ipn => Ipn, key => Igtk}};
take({vendor, _Other}, Data) ->
    Data.

%% The station's message of a kind, with its MIC under the KCK: message 2 carries the
%% SNonce and the station's RSN element, and Secure on a rekey, when a PTK is already
%% installed; message 4 and group message 2 carry neither nonce nor key data and set
%% Secure. Each echoes the replay counter of the message it answers, as wpa_supplicant's
%% replies do (rsn_supp/wpa.c, lines 655-690, 2420-2445 and 3140-3170).
-spec build(message_2 | message_4 | group_2, erx_wpa_kdf:akm(), <<_:128>>, map()) -> binary().
build(message_2, Akm, Kck, #{replay_counter := Counter, snonce := SNonce, rsn := Rsn, rekey := Rekey}) ->
    Secure = case Rekey of true -> ?ERX_WPA_KEY_INFO_SECURE; false -> 0 end,
    frame(Akm, Kck, ?ERX_WPA_KEY_INFO_PAIRWISE bor Secure, Counter, SNonce, Rsn);
build(message_4, Akm, Kck, #{replay_counter := Counter}) ->
    frame(Akm, Kck, ?ERX_WPA_KEY_INFO_PAIRWISE bor ?ERX_WPA_KEY_INFO_SECURE, Counter, zero_nonce(), <<>>);
build(group_2, Akm, Kck, #{replay_counter := Counter}) ->
    frame(Akm, Kck, ?ERX_WPA_KEY_INFO_SECURE, Counter, zero_nonce(), <<>>).

frame(Akm, Kck, Bits, Counter, Nonce, Data) ->
    Info = Bits bor ?ERX_WPA_KEY_INFO_MIC bor erx_abi_translations:wpa_akm_key_version(Akm),
    Unsigned = encode(Info, Counter, Nonce, Data, <<0:(?ERX_WPA_MIC_SIZE * 8)>>),
    encode(Info, Counter, Nonce, Data, erx_wpa_kdf:mic(Akm, Kck, Unsigned)).

encode(Info, Counter, Nonce, Data, Mic) ->
    Fixed = erx_abi_packed:encode(erx_eapol_key,
                                  #{version => ?ERX_EAPOL_VERSION, type => ?ERX_EAPOL_TYPE_KEY,
                                    body_length => ?ERX_EAPOL_KEY_SIZE - ?EAPOL_HEADER + byte_size(Data),
                                    descriptor => ?ERX_EAPOL_KEY_DESCRIPTOR_RSN, key_info => Info,
                                    key_length => 0, replay_counter => Counter, nonce => Nonce,
                                    iv => <<0:128>>, rsc => <<0:64>>, reserved => <<0:64>>, mic => Mic,
                                    data_length => byte_size(Data)}),
    <<Fixed/binary, Data/binary>>.

zero_nonce() -> <<0:(?ERX_WPA_NONCE_SIZE * 8)>>.

bit(Value, Mask) -> Value band Mask =/= 0.

require(true, _Rule) -> ok;
require(false, Rule) -> throw({malformed, Rule}).
