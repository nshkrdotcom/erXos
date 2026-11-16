%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_wifi_keys).

-moduledoc """
The station's side of the key holder's `wpa_key` facet (docs/design-wifi.md,
"Credentials"): the one module through which the station reaches the holder. The
join machine never derives a key: it returns a request made here as an action, and
the station's process performs it as a call and hands the answer back to the join
machine before any other event ("Concurrency and ordering").

Every request has a fixed shape, an SSID of 1 to 32 bytes, addresses of 6 bytes,
nonces of 32 and one of three AKMs, so a request of any other shape is refused
here, where it is made, and the holder checks lengths and parses nothing.
""".

-include("generated/erx_abi.hrl").

-export([sae_commit/3, sae_key/4, ptk/6]).
-export_type([request/0, answer/0, ptk/0]).

-type akm() :: psk | psk_sha256 | sae.
-type ptk() :: #{kck := <<_:128>>, kek := <<_:128>>, tk := <<_:128>>}.
-type request() :: {sae_commit, #{ssid := binary(), spa := <<_:48>>, aa := <<_:48>>}}
                 | {sae_key, #{ssid := binary(), scalar := <<_:256>>, element := <<_:512>>,
                               rejected := binary()}}
                 | {ptk, #{ssid := binary(), akm := akm(), aa := <<_:48>>, spa := <<_:48>>,
                           anonce := <<_:256>>, snonce := <<_:256>>}}.
%% Every operation may answer `unavailable`. `sae_commit` answers the station's scalar
%% and element, `sae_key` the exchange's KCK and `ptk` the PTK's three keys, each else
%% why there is none ("Credentials").
-type answer() :: {ok, <<_:256>>, <<_:512>>} | {ok, <<_:256>>} | {ok, ptk()}
                | {error, unavailable | no_secret | sae_only | no_pmk | no_commit | bad_element}.

-define(ADDRESS, 6).
%% A Rejected Groups list is one element's body: at most 254 bytes of 16-bit groups.
-define(REJECTED_MAX, 254).

-doc """
The request for SAE's commit under SSID's PT between the station's address Spa and
the BSS's Aa: the holder draws `rand` and `mask`, keeps the exchange, and answers the
scalar and element.
""".
-spec sae_commit(binary(), <<_:48>>, <<_:48>>) -> request().
sae_commit(Ssid, Spa, Aa)
  when byte_size(Ssid) >= 1, byte_size(Ssid) =< ?ERX_IEEE80211_SSID_MAX,
       byte_size(Spa) =:= ?ADDRESS, byte_size(Aa) =:= ?ADDRESS ->
    {sae_commit, #{ssid => Ssid, spa => Spa, aa => Aa}}.

-doc """
The request for the KCK of SSID's exchange in progress from the peer's commit: its
scalar, its element and its Rejected Groups list, empty when its commit carried none.
""".
-spec sae_key(binary(), <<_:256>>, <<_:512>>, binary()) -> request().
sae_key(Ssid, Scalar, Element, Rejected)
  when byte_size(Ssid) >= 1, byte_size(Ssid) =< ?ERX_IEEE80211_SSID_MAX,
       byte_size(Scalar) =:= ?ERX_SAE_SCALAR_SIZE, byte_size(Element) =:= 2 * ?ERX_SAE_SCALAR_SIZE,
       byte_size(Rejected) rem 2 =:= 0, byte_size(Rejected) =< ?REJECTED_MAX ->
    {sae_key, #{ssid => Ssid, scalar => Scalar, element => Element, rejected => Rejected}}.

-doc """
The request for the PTK of SSID's secret under AKM, between the authenticator's
address Aa and the station's Spa, from the access point's ANonce and the station's
SNonce.
""".
-spec ptk(binary(), akm(), <<_:48>>, <<_:48>>, <<_:256>>, <<_:256>>) -> request().
ptk(Ssid, Akm, Aa, Spa, ANonce, SNonce)
  when byte_size(Ssid) >= 1, byte_size(Ssid) =< ?ERX_IEEE80211_SSID_MAX,
       (Akm =:= psk orelse Akm =:= psk_sha256 orelse Akm =:= sae),
       byte_size(Aa) =:= ?ADDRESS, byte_size(Spa) =:= ?ADDRESS,
       byte_size(ANonce) =:= ?ERX_WPA_NONCE_SIZE, byte_size(SNonce) =:= ?ERX_WPA_NONCE_SIZE ->
    {ptk, #{ssid => Ssid, akm => Akm, aa => Aa, spa => Spa, anonce => ANonce, snonce => SNonce}}.
