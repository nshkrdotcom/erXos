%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_wpa_kdf against published vectors (docs/design-wifi.md, "Verification"):
%% the PSK passphrase vectors of IEEE 802.11 Annex J.4 and the PRF-SHA1 vectors, as
%% wpa_supplicant 2.12 carries them in src/crypto/crypto_module_tests.c (lines
%% 1158-1257); the KDF-SHA256 PTK vector of IEEE Std 802.11-2024 J.13, as
%% src/common/common_module_tests.c carries it (lines 685-737); AES-CMAC against
%% RFC 4493, section 4; HMAC-SHA1-128 against RFC 2202, section 3; and AES key
%% unwrap against RFC 3394, section 4.
-module(erx_wpa_kdf_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

h(Hex) -> binary:decode_hex(iolist_to_binary(string:replace(Hex, " ", "", all))).

pmk_matches_the_passphrase_vectors_test_() ->
    [?_assertEqual(h(Psk), erx_wpa_kdf:pmk(Passphrase, Ssid))
     || {Passphrase, Ssid, Psk} <-
            [{<<"password">>, <<"IEEE">>,
              "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"},
             {<<"ThisIsAPassword">>, <<"ThisIsASSID">>,
              "0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af"},
             {binary:copy(<<"a">>, 32), binary:copy(<<"Z">>, 32),
              "becb93866bb8c3832cb777c2f559807c8c59afcb6eae734885001300a981cc62"}]].

prf_sha1_matches_its_vectors_test_() ->
    [?_assertEqual(h(Expected), erx_wpa_kdf:prf_sha1(Key, <<"prefix">>, Data, 512))
     || {Key, Data, Expected} <-
            [{h("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"), <<"Hi There">>,
              "bcd4c650b30b9684951829e0d75f9d54b862175ed9f00606e17d8da35402ffee"
              "75df78c3d31e0f889f012120c0862beb67753e7439ae242edb8373698356cf5a"},
             {<<"Jefe">>, <<"what do ya want for nothing?">>,
              "51f4de5b33f249adf81aeb713a3c20f4fe631446fabdfa58244759ae58ef9009"
              "a99abf4eac2ca5fa87e692c440eb40023e7babb206d61de7b92f41529092b8fc"},
             {h("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), binary:copy(<<16#dd>>, 50),
              "e1ac546ec4cb636f9976487be5c86be17a0252ca5d8d8df12cfb0473525249ce"
              "9dd8d177ead710bc9b590547239107aef7b4abd43d87f0a68f1cbd9e2b6f7607"}]].

%% J.13: the SAE PTK with a 32-byte KDK after it, 640 bits, whose first 48 bytes
%% are the KCK, KEK and TK. Either argument order of the addresses and the nonces
%% gives the same keys.
pairwise_keys_match_the_kdf_sha256_vector_test_() ->
    Pmk = h("def43e5567e01ca6649265f19a290eeff8bd888f6c1d9cc9d10f04bd378f3cad"),
    Aa = h("c0ffd4a8dbc1"),
    Spa = h("00904c01c107"),
    ANonce = h("be7a1ca284347b5bd67dbd2dfdb4d99f1afae0b88ba18e008718417e4b27ef5f"),
    SNonce = h("404b012ffb43ed0fb43ea1f287c91f2506d21b4a92d74b5ea50c943350ce8671"),
    Expected = h("cd7b9e7555362df0b63568484a8112f5" "99cad3588da0f1e63fd190191039bb4b"
                 "9e2e9377e7532e737a1bc250fe194a03"
                 "6c7fb97ceb55b01acff00f070942bdf5291feb4bee38e0365b25a250bb2ac9ff"),
    [?_assertEqual(Expected, erx_wpa_kdf:pairwise_key_bits(?ERX_IEEE80211_AKM_SAE, Pmk, Aa, Spa, ANonce, SNonce, 640)),
     ?_assertEqual(Expected, erx_wpa_kdf:pairwise_key_bits(?ERX_IEEE80211_AKM_SAE, Pmk, Spa, Aa, SNonce, ANonce, 640))].

ptk_splits_384_bits_into_three_keys_test() ->
    Pmk = binary:copy(<<1>>, 32),
    {Aa, Spa, ANonce, SNonce} = {<<2:48>>, <<3:48>>, binary:copy(<<4>>, 32), binary:copy(<<5>>, 32)},
    Bits = erx_wpa_kdf:pairwise_key_bits(?ERX_IEEE80211_AKM_PSK, Pmk, Aa, Spa, ANonce, SNonce, 384),
    #{kck := Kck, kek := Kek, tk := Tk} = erx_wpa_kdf:ptk(?ERX_IEEE80211_AKM_PSK, Pmk, Aa, Spa, ANonce, SNonce),
    ?assertEqual(Bits, <<Kck/binary, Kek/binary, Tk/binary>>),
    ?assertEqual(erx_wpa_kdf:prf_sha1(Pmk, <<"Pairwise key expansion">>,
                                      <<Aa/binary, Spa/binary, ANonce/binary, SNonce/binary>>, 384), Bits).

%% RFC 4493's examples 2 and 3 under its key, as the KCK of an AKM whose MIC is
%% AES-128-CMAC.
cmac_mic_matches_rfc4493_test_() ->
    Key = h("2b7e151628aed2a6abf7158809cf4f3c"),
    [?_assertEqual(h(Mac), erx_wpa_kdf:mic(?ERX_IEEE80211_AKM_PSK_SHA256, Key, h(Message)))
     || {Message, Mac} <-
            [{"6bc1bee22e409f96e93d7e117393172a", "070a16b46b4d4144f79bdd9dd04a287c"},
             {"6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411",
              "dfa66747de9ae63030ca32611497c827"}]].

%% RFC 2202's HMAC-SHA-1 test cases 1, 2, 5 and 6, cut to their first 16 bytes, as the
%% MIC of an AKM whose MIC is HMAC-SHA1-128; case 5 is the RFC's own truncation case,
%% whose digest-96 is a prefix of the MIC.
hmac_sha1_mic_matches_rfc2202_test_() ->
    Large = binary:copy(<<16#aa>>, 80),
    [?_assertEqual(binary:part(h(Digest), 0, 16), erx_wpa_kdf:mic(?ERX_IEEE80211_AKM_PSK, Key, Data))
     || {Key, Data, Digest} <-
            [{binary:copy(<<16#0b>>, 20), <<"Hi There">>, "b617318655057264e28bc0b6fb378c8ef146be00"},
             {<<"Jefe">>, <<"what do ya want for nothing?">>, "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79"},
             {binary:copy(<<16#0c>>, 20), <<"Test With Truncation">>, "4c1a03424b55e07fe7f27be1d58bb9324a9a5a04"},
             {Large, <<"Test Using Larger Than Block-Size Key - Hash Key First">>,
              "aa4ae5e15272d00e95705637ce8a3b55ed402112"}]].

check_mic_refuses_a_changed_or_short_mic_test() ->
    Kck = binary:copy(<<7>>, 16),
    Mic = erx_wpa_kdf:mic(?ERX_IEEE80211_AKM_PSK, Kck, <<"frame">>),
    ?assertEqual(16, byte_size(Mic)),
    ?assert(erx_wpa_kdf:check_mic(?ERX_IEEE80211_AKM_PSK, Kck, <<"frame">>, Mic)),
    <<First, Rest/binary>> = Mic,
    ?assertNot(erx_wpa_kdf:check_mic(?ERX_IEEE80211_AKM_PSK, Kck, <<"frame">>, <<(First bxor 1), Rest/binary>>)),
    ?assertNot(erx_wpa_kdf:check_mic(?ERX_IEEE80211_AKM_PSK, Kck, <<"frame">>, Rest)).

rfc3394_vectors() ->
    Kek128 = "000102030405060708090a0b0c0d0e0f",
    Kek192 = "000102030405060708090a0b0c0d0e0f1011121314151617",
    Kek256 = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
    Data128 = "00112233445566778899aabbccddeeff",
    Data192 = "00112233445566778899aabbccddeeff0001020304050607",
    Data256 = "00112233445566778899aabbccddeeff000102030405060708090a0b0c0d0e0f",
    [{Kek128, Data128, "1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5"},
     {Kek192, Data128, "96778b25ae6ca435f92b5b97c050aed2468ab8a17ad84e5d"},
     {Kek256, Data128, "64e8c3f9ce0f5ba263e9777905818a2a93c8191e7d6e8ae7"},
     {Kek192, Data192, "031d33264e15d33268f24ec260743edce1c6c7ddee725a936ba814915c6762d2"},
     {Kek256, Data192, "a8f9bc1612c68b3ff6e6f4fbe30e71e4769c8b80a32cb8958cd5d17d6b254da1"},
     {Kek256, Data256, "28c9f404c4b810f4cbccb35cfb87f8263f5786e2d80ed326"
                       "cbc7f0e71a99f43bfb988b9b7a02dd21"}].

unwrap_matches_rfc3394_test_() ->
    [?_assertEqual({ok, h(Data)}, erx_wpa_kdf:unwrap(h(Kek), h(Wrapped)))
     || {Kek, Data, Wrapped} <- rfc3394_vectors()].

unwrap_refuses_altered_or_malformed_data_test_() ->
    [{Kek, _, Wrapped} | _] = rfc3394_vectors(),
    <<First, Rest/binary>> = h(Wrapped),
    [?_assertEqual({error, unwrap}, erx_wpa_kdf:unwrap(h(Kek), <<(First bxor 1), Rest/binary>>)),
     ?_assertEqual({error, unwrap}, erx_wpa_kdf:unwrap(h(Kek), binary:part(h(Wrapped), 0, 16))),
     ?_assertEqual({error, unwrap}, erx_wpa_kdf:unwrap(h(Kek), <<(h(Wrapped))/binary, 0>>)),
     ?_assertEqual({error, unwrap}, erx_wpa_kdf:unwrap(<<1, 2, 3>>, h(Wrapped)))].
