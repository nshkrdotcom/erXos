%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_smp_crypto).
-moduledoc """
The Security Manager's cryptographic toolbox for LE Secure Connections
(docs/design-bluetooth.md, "Secure Connections only"), from the Bluetooth Core
Specification 6.3, Vol 3 Part H, section 2.2, over OTP's `crypto`.

Every value here is a binary with its most significant octet first, the order of the
specification's notation and of AES-CMAC's input inside `f4`, `f5` and `f6` (2.2);
`erx_smp` turns the wire's order, least significant octet first (1.2.1), into this one.
An address is `{public | random, <<_:48>>}` and enters `f5` and `f6` as 56 bits whose
lowest bit of the top octet is the address type (2.2.7, 2.2.8).

`e/2` is AES-128 (2.2.1), `aes_cmac/2` AES-CMAC (2.2.5, RFC 4493), `ah/2` the random
address hash (2.2.2), `f4/4`, `f5/5` and `f6/7` the confirm, key and check functions
(2.2.6 to 2.2.8). `on_curve/1` is the public key check of 2.3.5.6.1 and `dhkey/2` the
key agreement over P-256; the curve's constants come from `crypto:ec_curve(secp256r1)`,
the one table OTP holds them in. `debug_key/0` is SMP's debug public key (2.3.5.6.1),
which a responder refuses. `fresh/0` is the one effect: the key pair, nonces and
passkey of one pairing, from `crypto:strong_rand_bytes/1`.
""".

-export([e/2, aes_cmac/2, ah/2, f4/4, f5/5, f6/7, on_curve/1, dhkey/2, static_random/1, identity_address/2, debug_key/0, fresh/0]).
-export_type([value/0, public_key/0, address/0, fresh/0]).

-include("generated/erx_abi.hrl").

-doc "A 128-bit value, most significant octet first.".
-type value() :: <<_:128>>.
-doc "A P-256 public key's coordinates, each most significant octet first.".
-type public_key() :: {X :: <<_:256>>, Y :: <<_:256>>}.
-doc "A device address as connection setup used it (2.2.7).".
-type address() :: {public | random, <<_:48>>}.
-doc "What one pairing draws fresh (2.3.5.6.3, 2.3.6): its key pair, its nonces and its passkey.".
-type fresh() :: #{private := <<_:256>>, public := public_key(),
                   nonces := [value()], passkey := 0..?ERX_SMP_PASSKEY_MAX}.

%% f5's SALT and keyID "btle" (2.2.7).
-define(F5_SALT, <<16#6C888391:32, 16#AAF5A538:32, 16#60370BDB:32, 16#5A6083BE:32>>).
-define(F5_KEY_ID, <<"btle">>).

-doc "Security function e: AES-128 of one block (2.2.1).".
-spec e(value(), value()) -> value().
e(Key, Plain) -> crypto:crypto_one_time(aes_128_ecb, Key, Plain, true).

-doc "AES-CMAC with a 128-bit key (2.2.5).".
-spec aes_cmac(value(), binary()) -> value().
aes_cmac(Key, Message) -> crypto:mac(cmac, aes_128_cbc, Key, Message).

-doc "The random address hash: the low 24 bits of e(k, padding || r) (2.2.2).".
-spec ah(value(), <<_:24>>) -> <<_:24>>.
ah(Irk, Prand) ->
    <<_:104, Hash:24/bits>> = e(Irk, <<0:104, Prand/binary>>),
    Hash.

-doc "The confirm value: AES-CMAC_X(U || V || Z) (2.2.6).".
-spec f4(<<_:256>>, <<_:256>>, value(), byte()) -> value().
f4(U, V, X, Z) -> aes_cmac(X, <<U/binary, V/binary, Z>>).

-doc """
The key generation function: `{MacKey, Ltk}`, the most and the least significant 128
bits of f5(W, N1, N2, A1, A2) (2.2.7).
""".
-spec f5(<<_:256>>, value(), value(), address(), address()) -> {value(), value()}.
f5(W, N1, N2, A1, A2) ->
    T = aes_cmac(?F5_SALT, W),
    Block = fun(Counter) ->
                    aes_cmac(T, <<Counter, ?F5_KEY_ID/binary, N1/binary, N2/binary,
                                  (address(A1))/binary, (address(A2))/binary, 256:16>>)
            end,
    {Block(0), Block(1)}.

-doc "The check value: AES-CMAC_W(N1 || N2 || R || IOcap || A1 || A2) (2.2.8).".
-spec f6(value(), value(), value(), value(), <<_:24>>, address(), address()) -> value().
f6(W, N1, N2, R, IoCap, A1, A2) ->
    aes_cmac(W, <<N1/binary, N2/binary, R/binary, IoCap/binary, (address(A1))/binary, (address(A2))/binary>>).

%% An address as 56 bits: seven zero bits, the type bit, then the address (2.2.7).
address({public, Address}) -> <<0, Address/binary>>;
address({random, Address}) -> <<1, Address/binary>>.

-doc """
Whether a public key is a point of P-256: both coordinates below p, and
y^2 = x^3 + ax + b (mod p) (2.3.5.6.1). Checked here, before any key agreement, so
an invalid point never reaches OpenSSL.
""".
-spec on_curve(public_key()) -> boolean().
on_curve({<<X:256>>, <<Y:256>>}) ->
    {{prime_field, <<P:256>>}, {<<A:256>>, <<B:256>>, _Seed}, _Base, _Order, _Cofactor} =
        crypto:ec_curve(secp256r1),
    X < P andalso Y < P andalso (Y * Y - (X * X * X + A * X + B)) rem P =:= 0.

-doc """
The Diffie-Hellman key of a private key and a peer's public key, its X coordinate
(2.2.7, DHKey). The caller has checked the public key with `on_curve/1`.
""".
-spec dhkey(<<_:256>>, public_key()) -> <<_:256>>.
dhkey(Private, {X, Y}) -> crypto:compute_key(ecdh, <<4, X/binary, Y/binary>>, Private, secp256r1).

-doc """
Whether 48 bits, most significant first, are a static random address (Vol 6 Part B,
1.3.2 and 1.3.2.1): the top two bits set, and the other 46 neither all zeros nor all
ones. The other three values of the top bits are private addresses and a reserved one.
""".
-spec static_random(<<_:48>>) -> boolean().
static_random(<<2#11:2, Random:46>>) -> Random =/= 0 andalso Random =/= 1 bsl 46 - 1;
static_random(<<_:48>>) -> false.

-doc """
The identity address of an identity's type octet and 48 bits, as Identity Address
Information sends them and the stored state keeps them (3.6.5): type 0 is a public
address, any 48 bits, and type 1 a static random one (`static_random/1`). Any other is
`error`, a private address among them, since it names no lasting device.
""".
-spec identity_address(byte(), <<_:48>>) -> {ok, address()} | error.
identity_address(0, Octets) -> {ok, {public, Octets}};
identity_address(1, Octets) ->
    case static_random(Octets) of
        true -> {ok, {random, Octets}};
        false -> error
    end;
identity_address(_Type, _Octets) -> error.

-doc "SMP's debug public key (2.3.5.6.1).".
-spec debug_key() -> public_key().
debug_key() ->
    {<<16#20b003d2:32, 16#f297be2c:32, 16#5e2c83a7:32, 16#e9f9a5b9:32,
       16#eff49111:32, 16#acf4fddb:32, 16#cc030148:32, 16#0e359de6:32>>,
     <<16#dc809c49:32, 16#652aeb6d:32, 16#63329abf:32, 16#5a52155c:32,
       16#766345c2:32, 16#8fed3024:32, 16#741c8ed0:32, 16#1589d28b:32>>}.

-doc """
A fresh key pair, one nonce for each Passkey Entry round (Just Works uses the first)
and a passkey drawn uniformly from 0 to 999999 (2.3.5.6.3, 2.3.6).
""".
-spec fresh() -> fresh().
fresh() ->
    {<<4, X:32/binary, Y:32/binary>>, Private} = crypto:generate_key(ecdh, secp256r1),
    #{private => Private, public => {X, Y},
      nonces => [crypto:strong_rand_bytes(16) || _ <- lists:seq(1, ?ERX_SMP_PASSKEY_ROUNDS)],
      passkey => passkey()}.

%% Twenty random bits, drawn again while they exceed the passkey's bound, so every
%% passkey is equally likely.
passkey() ->
    <<_:4, Bits:20>> = crypto:strong_rand_bytes(3),
    if Bits =< ?ERX_SMP_PASSKEY_MAX -> Bits; true -> passkey() end.
