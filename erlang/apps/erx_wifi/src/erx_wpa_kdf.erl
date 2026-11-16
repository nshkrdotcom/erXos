%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The supplicant's key arithmetic (docs/design-wifi.md, "The supplicant"): the PMK
%% from a passphrase, the PTK from the PMK and the handshake's addresses and nonces,
%% the EAPOL-Key MIC, and AES key unwrap of encrypted key data. Every per-byte step is
%% OTP's crypto (OpenSSL); this module only arranges the bytes. What differs between
%% the AKMs is the AKM table of abi/formats/ieee80211.txt, read through
%% erx_abi_translations, so no AKM is named here.
%%
%% Every function is pure, and none keeps or logs what it is given: the PMK, the PTK's
%% keys and the key data are secrets, which the caller's process holds.
-module(erx_wpa_kdf).

-include("generated/erx_abi.hrl").

-export([pmk/2, ptk/6, pairwise_key_bits/7, prf_sha1/4, kdf_sha256/4, mic/3, check_mic/4,
         unwrap/2]).
-export_type([akm/0, ptk/0]).

-type akm() :: ?ERX_IEEE80211_AKM_PSK | ?ERX_IEEE80211_AKM_PSK_SHA256 | ?ERX_IEEE80211_AKM_SAE.
%% The PTK's three keys, 16 bytes each: the KCK, which keys the MIC, the KEK, which
%% unwraps key data, and the TK, which the chip encrypts with.
-type ptk() :: #{kck := <<_:128>>, kek := <<_:128>>, tk := <<_:128>>}.

-define(LABEL, <<"Pairwise key expansion">>).
-define(ADDRESS, 6).

%% The PSK's PMK: PBKDF2-HMAC-SHA1 of the passphrase, salted with the SSID, 4,096
%% iterations, 32 bytes (IEEE 802.11-2020, J.4.1, as wpa_supplicant's passphrase
%% vectors carry it).
-spec pmk(binary(), binary()) -> <<_:256>>.
pmk(Passphrase, Ssid)
  when byte_size(Passphrase) >= ?ERX_WPA_PASSPHRASE_MIN, byte_size(Passphrase) =< ?ERX_WPA_PASSPHRASE_MAX,
       byte_size(Ssid) >= 1, byte_size(Ssid) =< ?ERX_IEEE80211_SSID_MAX ->
    crypto:pbkdf2_hmac(sha, Passphrase, Ssid, ?ERX_WPA_PSK_ITERATIONS, ?ERX_WPA_PMK_SIZE).

%% The PTK of an AKM: its derivation over the PMK, the label "Pairwise key expansion"
%% and the context of the authenticator's and the supplicant's addresses and nonces,
%% split into KCK, KEK and TK.
-spec ptk(akm(), <<_:256>>, <<_:48>>, <<_:48>>, <<_:256>>, <<_:256>>) -> ptk().
ptk(Akm, Pmk, Aa, Spa, ANonce, SNonce) ->
    <<Kck:?ERX_WPA_KEY_SIZE/binary, Kek:?ERX_WPA_KEY_SIZE/binary, Tk:?ERX_WPA_KEY_SIZE/binary>> =
        pairwise_key_bits(Akm, Pmk, Aa, Spa, ANonce, SNonce, ?ERX_WPA_PTK_BITS),
    #{kck => Kck, kek => Kek, tk => Tk}.

%% The pairwise key derivation's first Bits bits: ptk/6 takes 384 of them; the
%% published KDF-SHA256 vector takes 640, the PTK with a KDK after it, and the length
%% enters every block of KDF-SHA256, so it is a parameter here. The context is the
%% lesser address, the greater, the lesser nonce and the greater, each compared as
%% unsigned bytes (wpa_common.c, wpa_pmk_to_ptk).
-spec pairwise_key_bits(akm(), binary(), <<_:48>>, <<_:48>>, <<_:256>>, <<_:256>>, pos_integer()) -> binary().
pairwise_key_bits(Akm, Pmk, Aa, Spa, ANonce, SNonce, Bits)
  when byte_size(Aa) =:= ?ADDRESS, byte_size(Spa) =:= ?ADDRESS,
       byte_size(ANonce) =:= ?ERX_WPA_NONCE_SIZE, byte_size(SNonce) =:= ?ERX_WPA_NONCE_SIZE ->
    Context = <<(min(Aa, Spa))/binary, (max(Aa, Spa))/binary,
                (min(ANonce, SNonce))/binary, (max(ANonce, SNonce))/binary>>,
    case erx_abi_translations:wpa_akm_kdf(Akm) of
        ?ERX_WPA_KDF_PRF_SHA1 -> prf_sha1(Pmk, ?LABEL, Context, Bits);
        ?ERX_WPA_KDF_KDF_SHA256 -> kdf_sha256(Pmk, ?LABEL, Context, Bits)
    end.

%% IEEE 802.11's PRF: HMAC-SHA1 of the key over the label, a zero byte, the data and
%% a one-byte counter from 0, its blocks concatenated and cut to Bits, a multiple of 8.
-spec prf_sha1(binary(), binary(), binary(), pos_integer()) -> binary().
prf_sha1(Key, Label, Data, Bits) when Bits rem 8 =:= 0, Bits div 160 < 256 ->
    Blocks = (Bits + 159) div 160,
    Stream = << <<(crypto:mac(hmac, sha, Key, <<Label/binary, 0, Data/binary, Counter>>))/binary>>
                || Counter <- lists:seq(0, Blocks - 1) >>,
    binary:part(Stream, 0, Bits div 8).

%% IEEE 802.11's KDF with SHA-256: HMAC-SHA256 of the key over a little-endian 16-bit
%% counter from 1, the label, the context and the output's length in bits, also
%% little-endian 16-bit, its blocks concatenated and cut to Bits, a multiple of 8.
-spec kdf_sha256(binary(), binary(), binary(), pos_integer()) -> binary().
kdf_sha256(Key, Label, Context, Bits) when Bits rem 8 =:= 0, Bits < 65536 ->
    Blocks = (Bits + 255) div 256,
    Stream = << <<(crypto:mac(hmac, sha256, Key, <<Counter:16/little, Label/binary, Context/binary, Bits:16/little>>))/binary>>
                || Counter <- lists:seq(1, Blocks) >>,
    binary:part(Stream, 0, Bits div 8).

%% The EAPOL-Key MIC of an AKM over a frame whose MIC field is zero: HMAC-SHA1's first
%% 16 bytes or AES-128-CMAC, under the KCK.
-spec mic(akm(), <<_:128>>, binary()) -> <<_:128>>.
mic(Akm, Kck, Frame) when byte_size(Kck) =:= ?ERX_WPA_KEY_SIZE ->
    case erx_abi_translations:wpa_akm_mic(Akm) of
        ?ERX_WPA_MIC_HMAC_SHA1_128 -> binary:part(crypto:mac(hmac, sha, Kck, Frame), 0, ?ERX_WPA_MIC_SIZE);
        ?ERX_WPA_MIC_AES_128_CMAC -> crypto:mac(cmac, aes_128_cbc, Kck, Frame)
    end.

%% Whether Mic is the frame's MIC, compared in constant time.
-spec check_mic(akm(), <<_:128>>, binary(), binary()) -> boolean().
check_mic(Akm, Kck, Frame, Mic) when byte_size(Mic) =:= ?ERX_WPA_MIC_SIZE ->
    crypto:hash_equals(mic(Akm, Kck, Frame), Mic);
check_mic(_Akm, _Kck, _Frame, _Mic) ->
    false.

%% AES key unwrap (RFC 3394, section 2.2.2, the index form) under a KEK of 16, 24 or
%% 32 bytes: the plaintext when the integrity value unwraps to the initial value, else
%% an error that says nothing more. Wrapped data is at least three semiblocks.
-spec unwrap(binary(), binary()) -> {ok, binary()} | {error, unwrap}.
unwrap(Kek, Wrapped)
  when (byte_size(Kek) =:= 16 orelse byte_size(Kek) =:= 24 orelse byte_size(Kek) =:= 32),
       byte_size(Wrapped) rem ?ERX_AES_WRAP_SEMIBLOCK =:= 0,
       byte_size(Wrapped) >= 3 * ?ERX_AES_WRAP_SEMIBLOCK ->
    <<A0:64, Blocks/binary>> = Wrapped,
    R0 = [Block || <<Block:?ERX_AES_WRAP_SEMIBLOCK/binary>> <= Blocks],
    Indexed = lists:zip(lists:seq(1, length(R0)), R0),
    {A, R} = lists:foldl(fun(J, {Ai, Ri}) -> unwrap_round(Kek, J, Ai, Ri) end,
                         {A0, Indexed}, [5, 4, 3, 2, 1, 0]),
    case A of
        ?ERX_AES_WRAP_IV -> {ok, << <<Block/binary>> || {_, Block} <- R >>};
        _ -> {error, unwrap}
    end;
unwrap(_Kek, _Wrapped) ->
    {error, unwrap}.

%% One round j of the unwrap, over the semiblocks i = n down to 1: B = AES-1(K, (A xor
%% t) | R[i]) with t = n * j + i, then A is B's first semiblock and R[i] its second.
%% The fold walks R from its end and prepends, so R comes back in order.
unwrap_round(Kek, J, A, Indexed) ->
    N = length(Indexed),
    lists:foldl(fun({I, Block}, {Ai, Done}) ->
                        <<Next:64, Plain:?ERX_AES_WRAP_SEMIBLOCK/binary>> =
                            crypto:crypto_one_time(ecb(Kek), Kek, <<(Ai bxor (N * J + I)):64, Block/binary>>, false),
                        {Next, [{I, Plain} | Done]}
                end, {A, []}, lists:reverse(Indexed)).

ecb(Kek) when byte_size(Kek) =:= 16 -> aes_128_ecb;
ecb(Kek) when byte_size(Kek) =:= 24 -> aes_192_ecb;
ecb(Kek) when byte_size(Kek) =:= 32 -> aes_256_ecb.
