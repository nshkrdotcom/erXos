%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_sae).

-moduledoc """
SAE's exchange as the join machine sees it (docs/design-wifi.md, "SAE and
protected management frames"): new/1 makes an exchange for one join, and step/3
takes each of its events and returns the actions to perform, the exchange, and an
outcome the join machine acts on. tested/1 says whether a guess of the secret could
now be tested offline from what the station sent, the `secret` class's condition
("Joining", "How a join ends").

This is the public half of SAE, group 19 with hash-to-element alone, after
wpa_supplicant 2.12's station (`sae.c`, `sme.c`). The key holder does every step on a
secret: the commit's scalar and element from PT, and the KCK from the peer's commit.
This module asks for both, as requests made by erx_wifi_keys, builds the commit and
the confirm, and checks what the access point sends. It holds no value from which the
password could be tested but the KCK of the exchange in progress.

A frame is an Authentication frame's body: the algorithm, the transaction sequence
number and the status, each a little-endian 16-bit field, then the fields of the
commit or the confirm. Every frame comes from the air and is parsed once, here.

The states are wpa_supplicant's four (`sae.h:113-115`), `nothing`, `committed` once the
commit is sent, `confirmed` once the confirm is sent, and `accepted`, with `committing`
while the holder makes the commit. The station's process hands the holder's answer to
the join machine before any other event ("Concurrency and ordering"), so a `committed`
exchange that has asked for the KCK of the peer's commit takes that answer next. The contract a step keeps, which erx_wifi_join's
table checks: `{auth_tx, _}` never ends the exchange, and `{drop, Check}` comes with
no action and the exchange unchanged, so the join machine counts it as any refused
event. An action is `{auth_frame, Frame}`, a frame to send, or `{keys, Request}`,
whose answer the next step receives as `{key, Answer}`.
""".

-include("generated/erx_abi.hrl").

-export([new/1, step/3, tested/1]).
-export_type([sae/0, event/0, outcome/0, action/0]).

%% erXos's limits ("Joining", "Deadlines"): the exchange within 5 s of its start, each
%% frame sent again 1 s after it was last sent, at most twice.
-define(EXCHANGE_MS, 5_000).
-define(RESEND_MS, 1_000).
-define(RESENDS, 2).

-define(SCALAR, ?ERX_SAE_SCALAR_SIZE).
-define(HEADER(Transaction, Status),
        ?ERX_IEEE80211_AUTH_ALGORITHM_SAE:16/little, Transaction:16/little, Status:16/little).

-type phase() :: nothing | committing | committed | confirmed | accepted.
%% A party's commit: its scalar, 32 bytes, and its element, both coordinates, 64.
-type commit() :: #{scalar := <<_:256>>, element := <<_:512>>}.
-opaque sae() :: #{ssid := binary(), spa := <<_:48>>, aa := <<_:48>>, identifier := binary() | none,
                   phase := phase(), ends := integer() | none, next := integer() | none,
                   resent := 0..?RESENDS, own := commit() | none, peer := commit() | none,
                   token := binary() | none, kck := <<_:256>> | none, send_confirm := 0..65535}.
-type event() :: start | {auth_frame, binary()} | {auth_tx, ok | failed} | {key, erx_wifi_keys:answer()}
               | deadline.
-type action() :: {auth_frame, binary()} | {keys, erx_wifi_keys:request()}.
%% `{running, Deadline}` keeps the exchange going until the time Deadline, when the
%% join machine gives it `deadline`; `{drop, Check}` refuses the event; `accepted`
%% means each side proved the secret.
-type outcome() :: {running, integer()} | {drop, atom()} | accepted | {failed, secret | bss}.

-doc """
The exchange of one join: the SSID, the station's address and the BSS's, and the
password identifier the holder's entry names, if any.
""".
-spec new(#{ssid := binary(), spa := <<_:48>>, aa := <<_:48>>, identifier => binary()}) -> sae().
new(#{ssid := Ssid, spa := Spa, aa := Aa} = Join)
  when byte_size(map_get(identifier, Join)) =< ?ERX_SAE_PASSWORD_IDENTIFIER_MAX;
       not is_map_key(identifier, Join) ->
    #{ssid => Ssid, spa => Spa, aa => Aa, identifier => maps:get(identifier, Join, none),
      phase => nothing, ends => none, next => none, resent => 0, own => none, peer => none,
      token => none, kck => none, send_confirm => 0}.

-doc "One event of the exchange, at the time in Ctx.".
-spec step(sae(), event(), #{now := integer(), _ => _}) -> {[action()], sae(), outcome()}.
step(Sae, Event, #{now := Now}) ->
    try
        event(Sae, Event, Now)
    catch
        throw:{drop, Check} -> {[], Sae, {drop, Check}}
    end.

-doc "Whether the station sent its confirm and no peer confirm has verified.".
-spec tested(sae()) -> boolean().
tested(#{phase := Phase}) ->
    Phase =:= confirmed.

%% ---- Events ----

event(#{phase := nothing, ssid := Ssid, spa := Spa, aa := Aa} = Sae, start, Now) ->
    Ends = Now + ?EXCHANGE_MS,
    {[{keys, erx_wifi_keys:sae_commit(Ssid, Spa, Aa)}], Sae#{phase := committing, ends := Ends, next := Ends},
     {running, Ends}};
event(#{phase := committing} = Sae, {key, {ok, Scalar, Element}}, Now)
  when byte_size(Scalar) =:= ?SCALAR, byte_size(Element) =:= 2 * ?SCALAR ->
    transmit(Sae#{phase := committed, own := #{scalar => Scalar, element => Element}, resent := 0}, Now);
event(#{phase := committed, peer := #{}} = Sae, {key, {ok, Kck}}, Now) when byte_size(Kck) =:= ?ERX_SAE_KCK_SIZE ->
    transmit(Sae#{phase := confirmed, kck := Kck, resent := 0}, Now);
event(#{phase := committed, peer := #{}}, {key, {error, bad_element}}, _Now) ->
    throw({drop, bad_element});
event(#{phase := Phase} = Sae, {key, {error, _}}, _Now) when Phase =:= committing; Phase =:= committed ->
    {[], Sae, {failed, bss}};
event(_Sae, {key, _}, _Now) ->
    throw({drop, unasked_answer});
event(Sae, {auth_tx, _}, _Now) ->
    {[], Sae, running(Sae)};
event(Sae, {auth_frame, Frame}, Now) ->
    frame(Sae, header(Frame), Now);
event(#{ends := Ends} = Sae, deadline, Now) when Now >= Ends ->
    {[], Sae, {failed, class(Sae)}};
event(#{phase := Phase, resent := Resent} = Sae, deadline, Now)
  when Resent < ?RESENDS, (Phase =:= committed orelse Phase =:= confirmed) ->
    transmit(Sae#{resent := Resent + 1}, Now);
event(#{ends := Ends} = Sae, deadline, _Now) ->
    {[], Sae#{next := Ends}, {running, Ends}}.

running(#{next := Next}) -> {running, Next}.

class(Sae) ->
    case tested(Sae) of
        true -> secret;
        false -> bss
    end.

%% Sends the frame of the phase, the commit or the next confirm, and waits for the
%% next resend, or for the exchange's end when that comes first.
transmit(#{ends := Ends} = Sae0, Now) ->
    {Frame, Sae} = outgoing(Sae0),
    Next = min(Now + ?RESEND_MS, Ends),
    {[{auth_frame, Frame}], Sae#{next := Next}, {running, Next}}.

outgoing(#{phase := committed, own := #{scalar := Scalar, element := Element}, identifier := Id, token := Token} = Sae) ->
    {<<?HEADER(?ERX_SAE_TRANSACTION_COMMIT, ?ERX_IEEE80211_STATUS_SAE_HASH_TO_ELEMENT),
       ?ERX_SAE_GROUP:16/little, Scalar/binary, Element/binary,
       (ext_element(?ERX_IEEE80211_EID_EXT_PASSWORD_IDENTIFIER, Id))/binary,
       (ext_element(?ERX_IEEE80211_EID_EXT_ANTI_CLOGGING_TOKEN, Token))/binary>>, Sae};
outgoing(#{phase := confirmed, send_confirm := Sent, kck := Kck, own := Own, peer := Peer} = Sae) ->
    Sc = min(Sent + 1, ?ERX_SAE_SEND_CONFIRM_MAX),
    {<<?HEADER(?ERX_SAE_TRANSACTION_CONFIRM, ?ERX_IEEE80211_STATUS_SUCCESS), Sc:16/little,
       (confirm(Kck, Sc, Own, Peer))/binary>>, Sae#{send_confirm := Sc}}.

ext_element(_Ext, none) -> <<>>;
ext_element(Ext, Body) -> <<?ERX_IEEE80211_EID_EXTENSION, (byte_size(Body) + 1), Ext, Body/binary>>.

%% CN of `sae_cn_confirm`: HMAC-SHA256 under the KCK over the send-confirm, the
%% sender's commit and then the receiver's.
confirm(Kck, Sc, #{scalar := S1, element := E1}, #{scalar := S2, element := E2}) ->
    crypto:mac(hmac, sha256, Kck, [<<Sc:16/little>>, S1, E1, S2, E2]).

%% ---- Frames from the air ----

header(<<?HEADER(Transaction, Status), Body/binary>>) -> {Transaction, Status, Body};
header(_Frame) -> throw({drop, sae_malformed}).

%% A frame before the station has sent its commit answers nothing it sent.
frame(#{phase := Phase}, _Frame, _Now) when Phase =/= committed, Phase =/= confirmed ->
    throw({drop, sae_unexpected});
frame(Sae, {?ERX_SAE_TRANSACTION_COMMIT, ?ERX_IEEE80211_STATUS_SAE_HASH_TO_ELEMENT, Body}, _Now) ->
    peer_commit(Sae, Body);
frame(Sae, {?ERX_SAE_TRANSACTION_COMMIT, ?ERX_IEEE80211_STATUS_ANTI_CLOGGING_TOKEN_REQUIRED, Body}, Now) ->
    token_request(Sae, Body, Now);
frame(Sae, {?ERX_SAE_TRANSACTION_CONFIRM, ?ERX_IEEE80211_STATUS_SUCCESS, Body}, _Now) ->
    peer_confirm(Sae, Body);
frame(Sae, {?ERX_SAE_TRANSACTION_COMMIT, ?ERX_IEEE80211_STATUS_UNKNOWN_PASSWORD_IDENTIFIER, _Body}, _Now) ->
    {[], Sae, {failed, secret}};
%% A commit with status 0 is hunting-and-pecking's, which the station never offers.
frame(_Sae, {_Transaction, ?ERX_IEEE80211_STATUS_SUCCESS, _Body}, _Now) ->
    throw({drop, sae_malformed});
%% Any other status of a commit or a confirm is the peer's refusal, as it ends
%% wpa_supplicant's exchange (`sme.c`, sme_sae_auth). A token request once the confirm
%% is sent, which also ends wpa_supplicant's, is dropped by token_request/3: the peer
%% has already answered the commit it would ask to repeat.
frame(Sae, {Transaction, _Status, _Body}, _Now)
  when Transaction =:= ?ERX_SAE_TRANSACTION_COMMIT; Transaction =:= ?ERX_SAE_TRANSACTION_CONFIRM ->
    {[], Sae, {failed, class(Sae)}};
frame(_Sae, _Frame, _Now) ->
    throw({drop, sae_malformed}).

%% The peer's commit, checked as `sae_parse_commit` checks it, then the holder asked
%% for the KCK; or the end of the exchange when its Rejected Groups list names group
%% 19, the station's only group.
peer_commit(#{phase := committed, ssid := Ssid, own := Own} = Sae, Body) ->
    {Peer, Elements} = commit_fields(Body),
    not reflects(Peer, Own) orelse throw({drop, sae_reflected}),
    Rejected = rejected_groups(Elements, Sae),
    Groups = [Group || <<Group:16/little>> <= Rejected],
    case lists:member(?ERX_SAE_GROUP, Groups) of
        true ->
            {[], Sae, {failed, bss}};
        false ->
            #{scalar := Scalar, element := Element} = Peer,
            {[{keys, erx_wifi_keys:sae_key(Ssid, Scalar, Element, Rejected)}], Sae#{peer := Peer}, running(Sae)}
    end;
peer_commit(_Sae, _Body) ->
    throw({drop, sae_unexpected}).

%% Group 19, a scalar from 2 to r - 1 and an element of two coordinates below the
%% prime. Whether the element lies on the curve the holder decides, answering
%% `bad_element` when it does not.
commit_fields(<<?ERX_SAE_GROUP:16/little, Scalar:?SCALAR/binary, X:?SCALAR/binary, Y:?SCALAR/binary,
                Elements/binary>>) ->
    {{prime_field, Prime}, _Curve, _Base, Order, _Cofactor} = crypto:ec_curve(secp256r1),
    in_range(Scalar, 2, Order) andalso below(X, Prime) andalso below(Y, Prime) orelse throw({drop, bad_element}),
    {#{scalar => Scalar, element => <<X/binary, Y/binary>>}, Elements};
commit_fields(_Body) ->
    throw({drop, sae_malformed}).

%% Whether Value, a big-endian number, is at least the integer Low and below High,
%% another big-endian number, as crypto:ec_curve/1 gives the order.
in_range(Value, Low, High) -> binary:decode_unsigned(Value) >= Low andalso below(Value, High).

below(Value, Bound) -> binary:decode_unsigned(Value) < binary:decode_unsigned(Bound).

%% A commit that repeats the station's own scalar or element is its own reflected.
reflects(#{scalar := Scalar, element := Element}, #{scalar := OwnScalar, element := OwnElement}) ->
    Scalar =:= OwnScalar orelse Element =:= OwnElement.

%% The elements after the commit's fields, each optional and in this order: the
%% password identifier, which must be the station's when it sent one, then the
%% Rejected Groups list, a non-empty list of 16-bit groups. The token container that
%% may follow is for an access point, and the rest is not read. The list, empty when
%% there is none.
rejected_groups(Elements, #{identifier := Id}) ->
    {PeerId, AfterId} = optional_element(?ERX_IEEE80211_EID_EXT_PASSWORD_IDENTIFIER, Elements),
    Id =:= none orelse PeerId =:= Id orelse throw({drop, sae_malformed}),
    case optional_element(?ERX_IEEE80211_EID_EXT_REJECTED_GROUPS, AfterId) of
        {none, _} -> <<>>;
        {List, _} when List =/= <<>>, byte_size(List) rem 2 =:= 0 -> List;
        {_List, _} -> throw({drop, sae_malformed})
    end.

%% The extension element Ext at the front of Bytes, its body and what follows, or
%% `none` and Bytes when another element or nothing is there.
optional_element(Ext, <<?ERX_IEEE80211_EID_EXTENSION, Length, Ext, Rest/binary>>)
  when Length >= 1, byte_size(Rest) >= Length - 1 ->
    <<Body:(Length - 1)/binary, After/binary>> = Rest,
    {Body, After};
optional_element(_Ext, Bytes) ->
    {none, Bytes}.

%% An anti-clogging token request (status 76) while committed: the commit is sent
%% again with the token in its container, as hash-to-element carries it.
token_request(#{phase := committed} = Sae, <<?ERX_SAE_GROUP:16/little, Elements/binary>>, Now) ->
    case optional_element(?ERX_IEEE80211_EID_EXT_ANTI_CLOGGING_TOKEN, Elements) of
        {none, _} -> throw({drop, sae_malformed});
        {Token, _} -> transmit(Sae#{token := Token, resent := 0}, Now)
    end;
token_request(#{phase := committed}, _Body, _Now) ->
    throw({drop, sae_malformed});
token_request(_Sae, _Body, _Now) ->
    throw({drop, sae_unexpected}).

%% The peer's confirm, verified over its own send-confirm and both commits, the
%% peer's first; a confirm that does not verify ends the exchange as `secret`, since
%% the station's confirm was sent.
peer_confirm(#{phase := confirmed, kck := Kck, own := Own, peer := Peer} = Sae,
             <<Sc:16/little, Confirm:?ERX_SAE_KCK_SIZE/binary, _Elements/binary>>) ->
    case crypto:hash_equals(confirm(Kck, Sc, Peer, Own), Confirm) of
        true -> {[], Sae#{phase := accepted}, accepted};
        false -> {[], Sae, {failed, secret}}
    end;
peer_confirm(#{phase := confirmed}, _Body) ->
    throw({drop, sae_malformed});
peer_confirm(_Sae, _Body) ->
    throw({drop, sae_unexpected}).
