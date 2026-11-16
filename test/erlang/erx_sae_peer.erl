%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% SAE's arithmetic on P-256 and its two other parties, for the tests of erx_sae and
%% the join machine: a fake key holder answering `sae_commit` and `sae_key` as
%% docs/design-wifi.md ("Credentials", "SAE and protected management frames") states
%% them, and an access point running SAE with hash-to-element. Written apart from
%% erx_sae, from wpa_supplicant 2.12's sae.c (sae_derive_pt_ecc, sswu,
%% sae_derive_pwe_from_pt_ecc, sae_derive_commit, sae_derive_keys, sae_cn_confirm) and
%% RFC 9380's simplified SWU map, and checked against the vectors of
%% common_module_tests.c. The arithmetic runs on Erlang integers in time that depends
%% on the secret, which only a test may do; the holder's real arithmetic is crypto's
%% sae_pt/3, sae_commit/5 and sae_key/5 ("OTP's crypto: SAE's arithmetic").
-module(erx_sae_peer).

-export([hashed_values/3, pt/2, pwe/3, commit/5, key/6, scalar_inverse/1, point/1, encode/1, mul/2, neg/1,
         curve/0]).
-export([holder_new/2, holder/2, holder_pmk/1]).
-export([ap_new/1, ap_commit/1, ap_confirm/2, ap_token_request/1, ap_take/2, ap_pmk/1, ap_confirms/1]).

%% ---- P-256 on integers ----

curve() ->
    {{prime_field, P}, {A, B, _Seed}, _Base, R, _Cofactor} = crypto:ec_curve(secp256r1),
    #{p => int(P), a => int(A), b => int(B), r => int(R)}.

int(Bin) -> binary:decode_unsigned(Bin).

pow(Base, Exp, M) ->
    case crypto:mod_pow(Base, Exp, M) of
        error -> 0;
        Bin -> int(Bin)
    end.

md(X, M) -> ((X rem M) + M) rem M.

inv(X, P) -> pow(md(X, P), P - 2, P).

add(infinity, Q) -> Q;
add(Q, infinity) -> Q;
add({X, Y1}, {X, Y2}) ->
    #{p := P} = curve(),
    case md(Y1 + Y2, P) of
        0 -> infinity;
        _ -> double({X, Y1})
    end;
add({X1, Y1}, {X2, Y2}) ->
    #{p := P} = curve(),
    L = md((Y2 - Y1) * inv(X2 - X1, P), P),
    X3 = md(L * L - X1 - X2, P),
    {X3, md(L * (X1 - X3) - Y1, P)}.

double({X, Y}) ->
    #{p := P, a := A} = curve(),
    L = md((3 * X * X + A) * inv(2 * Y, P), P),
    X3 = md(L * L - 2 * X, P),
    {X3, md(L * (X - X3) - Y, P)}.

mul(K, Point) -> mul(K, Point, infinity).

mul(0, _Point, Acc) -> Acc;
mul(K, Point, Acc) ->
    Next = case K band 1 of 1 -> add(Acc, Point); 0 -> Acc end,
    mul(K bsr 1, add(Point, Point), Next).

neg(infinity) -> infinity;
neg({X, Y}) -> #{p := P} = curve(), {X, md(-Y, P)}.

on_curve({X, Y}) ->
    #{p := P, a := A, b := B} = curve(),
    X < P andalso Y < P andalso md(Y * Y - (X * X * X + A * X + B), P) =:= 0.

%% A 64-byte element as a point, and back.
point(<<X:256, Y:256>>) -> {X, Y}.
encode({X, Y}) -> <<X:256, Y:256>>.

%% ---- Hash-to-element ----

%% The password's two hashed values of 48 bytes, as `wlankey` makes them: pwd-seed is
%% HKDF-Extract with the SSID as salt over the password and the identifier, then
%% HKDF-Expand under the labels of u1 and u2 (sae.c, sae_pwd_seed and sae_derive_pt_ecc).
hashed_values(Ssid, Password, Identifier) ->
    Seed = crypto:mac(hmac, sha256, Ssid, [Password, Identifier]),
    {expand(Seed, <<"SAE Hash to Element u1 P1">>), expand(Seed, <<"SAE Hash to Element u2 P2">>)}.

expand(Prk, Info) ->
    T1 = crypto:mac(hmac, sha256, Prk, [Info, 1]),
    T2 = crypto:mac(hmac, sha256, Prk, [T1, Info, 2]),
    binary:part(<<T1/binary, T2/binary>>, 0, 48).

%% PT, the sum of the two hashed values' images under the simplified SWU map.
pt(U1, U2) ->
    #{p := P} = curve(),
    add(sswu(md(int(U1), P)), sswu(md(int(U2), P))).

%% RFC 9380 section 6.6.2 with Z = -10 for P-256 (sae.c, sswu_curve_param), and the
%% sign of y taken from u.
sswu(U) ->
    #{p := P, a := A, b := B} = curve(),
    Z = md(-10, P),
    T1 = md(Z * U * U, P),
    M = md(T1 * T1 + T1, P),
    X1 = case M of
             0 -> md(B * inv(Z * A, P), P);
             _ -> md(-B * inv(A, P) * (1 + inv(M, P)), P)
         end,
    X2 = md(T1 * X1, P),
    G = fun(X) -> md(X * X * X + A * X + B, P) end,
    {X, V} = case pow(G(X1), (P - 1) div 2, P) of
                 E when E =< 1 -> {X1, G(X1)};
                 _ -> {X2, G(X2)}
             end,
    Y = pow(V, (P + 1) div 4, P),
    case (U band 1) =:= (Y band 1) of
        true -> {X, Y};
        false -> {X, md(-Y, P)}
    end.

%% PWE, val times PT, val from both addresses, the larger first, reduced to 1 to r - 1.
pwe(Pt, Addr1, Addr2) ->
    #{r := R} = curve(),
    [Max, Min] = lists:reverse(lists:sort([Addr1, Addr2])),
    Val = int(crypto:mac(hmac, sha256, <<0:256>>, [Max, Min])) rem (R - 1) + 1,
    mul(Val, Pt).

%% sae_commit/5: PWE, the scalar and the element, or `retry`.
commit(Pt, Addr1, Addr2, Rand, Mask) ->
    #{r := R} = curve(),
    {Ra, Ma} = {int(Rand), int(Mask)},
    Scalar = (Ra + Ma) rem R,
    case Ra > 1 andalso Ra < R andalso Ma > 1 andalso Ma < R andalso Scalar > 1 of
        false -> retry;
        true -> Pwe = pwe(Pt, Addr1, Addr2), {Pwe, Scalar, neg(mul(Ma, Pwe))}
    end.

%% sae_key/5 and the KDF: the KCK and the PMK, or `bad_element`. The salt is the peer's
%% Rejected Groups list, or zeros when it is empty, since the station's own is.
key(Pwe, Rand, OwnScalar, PeerScalar, PeerElement, Rejected) ->
    #{r := R} = curve(),
    case on_curve(PeerElement) andalso mul(int(Rand), add(mul(PeerScalar, Pwe), PeerElement)) of
        false -> bad_element;
        infinity -> bad_element;
        {Kx, _} ->
            Salt = case Rejected of <<>> -> <<0:256>>; _ -> Rejected end,
            Keyseed = crypto:mac(hmac, sha256, Salt, <<Kx:256>>),
            Val = (OwnScalar + PeerScalar) rem R,
            <<Kck:32/binary, Pmk:32/binary>> =
                erx_wpa_kdf:kdf_sha256(Keyseed, <<"SAE KCK and PMK">>, <<Val:256>>, 512),
            {Kck, Pmk}
    end.

scalar_inverse(S) -> #{r := R} = curve(), pow(S, R - 2, R).

%% ---- The fake key holder ----

%% The holder of one SSID's PT, drawing `rand` and `mask` from a fixed list.
holder_new(Pt, Draws) -> #{pt => Pt, draws => Draws, exchange => none, pmk => none}.

holder({sae_commit, #{spa := Spa, aa := Aa}}, #{pt := Pt, draws := [{Rand, Mask} | Draws]} = H) ->
    case commit(Pt, Spa, Aa, Rand, Mask) of
        retry ->
            holder({sae_commit, #{spa => Spa, aa => Aa}}, H#{draws := Draws});
        {Pwe, Scalar, Element} ->
            {{ok, <<Scalar:256>>, encode(Element)},
             H#{draws := Draws, exchange := #{pwe => Pwe, rand => Rand, scalar => Scalar}, pmk := none}}
    end;
holder({sae_key, _}, #{exchange := none} = H) ->
    {{error, no_commit}, H};
holder({sae_key, #{scalar := <<PeerScalar:256>>, element := PeerElement, rejected := Rejected}},
       #{exchange := #{pwe := Pwe, rand := Rand, scalar := Own}} = H) ->
    case key(Pwe, Rand, Own, PeerScalar, point(PeerElement), Rejected) of
        bad_element -> {{error, bad_element}, H};
        {Kck, Pmk} -> {{ok, Kck}, H#{exchange := none, pmk := Pmk}}
    end.

holder_pmk(#{pmk := Pmk}) -> Pmk.

%% ---- The access point ----

-define(SAE, 3).

%% An access point for the station at Spa: its own `rand` and `mask`, the Rejected
%% Groups list its commit carries (empty for none) and the token it demands, or none.
ap_new(#{pt := Pt, aa := Aa, spa := Spa, rand := Rand, mask := Mask} = Config) ->
    {Pwe, Scalar, Element} = commit(Pt, Aa, Spa, Rand, Mask),
    #{pwe => Pwe, rand => Rand, scalar => Scalar, element => Element,
      rejected => maps:get(rejected, Config, <<>>), token => maps:get(token, Config, none),
      peer => none, kck => none, pmk => none, confirms => []}.

ap_commit(#{scalar := Scalar, element := Element, rejected := Rejected}) ->
    List = case Rejected of <<>> -> <<>>; _ -> <<255, (byte_size(Rejected) + 1), 92, Rejected/binary>> end,
    <<?SAE:16/little, 1:16/little, 126:16/little, 19:16/little, Scalar:256, (encode(Element))/binary, List/binary>>.

ap_token_request(#{token := Token}) ->
    <<?SAE:16/little, 1:16/little, 76:16/little, 19:16/little, 255, (byte_size(Token) + 1), 93, Token/binary>>.

%% The access point's confirm with send-confirm Sc, once it has the station's commit.
ap_confirm(#{kck := Kck, scalar := Scalar, element := Element, peer := {PeerScalar, PeerElement}}, Sc) ->
    Confirm = crypto:mac(hmac, sha256, Kck, [<<Sc:16/little, Scalar:256>>, encode(Element),
                                             <<PeerScalar:256>>, encode(PeerElement)]),
    <<?SAE:16/little, 2:16/little, 0:16/little, Sc:16/little, Confirm/binary>>.

%% A frame from the station: its commit, answered by the access point's commit, or by
%% a token request while the token it demands is missing; its confirm, answered by the
%% access point's confirm when it verifies, else by a failure.
ap_take(<<?SAE:16/little, 1:16/little, 126:16/little, 19:16/little, Scalar:256, Element:64/binary, Rest/binary>>,
        #{token := Token} = Ap) ->
    case Token =:= none orelse binary:match(Rest, <<255, (byte_size(Token) + 1), 93, Token/binary>>) =/= nomatch of
        false ->
            {[ap_token_request(Ap)], Ap};
        true ->
            #{pwe := Pwe, rand := Rand, scalar := Own, rejected := Rejected} = Ap,
            {Kck, Pmk} = key(Pwe, Rand, Own, Scalar, point(Element), Rejected),
            {[ap_commit(Ap)], Ap#{peer := {Scalar, point(Element)}, kck := Kck, pmk := Pmk}}
    end;
ap_take(<<?SAE:16/little, 2:16/little, 0:16/little, Sc:16/little, Confirm:32/binary>>,
        #{kck := Kck, scalar := Own, element := Element, peer := {PeerScalar, PeerElement}, confirms := Seen} = Ap) ->
    Expected = crypto:mac(hmac, sha256, Kck, [<<Sc:16/little, PeerScalar:256>>, encode(PeerElement),
                                              <<Own:256>>, encode(Element)]),
    case Expected =:= Confirm of
        true -> {[ap_confirm(Ap, 1)], Ap#{confirms := Seen ++ [Sc]}};
        false -> {[<<?SAE:16/little, 2:16/little, 1:16/little>>], Ap}
    end.

ap_pmk(#{pmk := Pmk}) -> Pmk.

%% The send-confirm values of the station's confirms that verified, in order.
ap_confirms(#{confirms := Seen}) -> Seen.
