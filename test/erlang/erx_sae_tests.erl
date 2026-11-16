%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_sae's cases (docs/design-wifi.md, "SAE and protected management frames",
%% Verification): IEEE 802.11-2020 Annex J.10's vectors as wpa_supplicant 2.12's
%% common_module_tests.c carries them, for the frames erx_sae builds and the fake
%% holder's arithmetic it is tested with; whole exchanges against an access point
%% running SAE (erx_sae_peer), without and with a Rejected Groups list and an
%% anti-clogging token; and the checks on what the air sends: invalid points and
%% scalars, reflection, the downgrade list, the confirm and its send-confirm, statuses,
%% the retry limits, and malformed frames.
-module(erx_sae_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SSID, <<"byteme">>).
-define(PASSWORD, <<"mekmitasdigoat">>).
-define(SPA, <<16#4d, 16#3f, 16#2f, 16#ff, 16#e3, 16#87>>).
-define(AA, <<16#a5, 16#d8, 16#aa, 16#95, 16#8e, 16#3c>>).
-define(H2E_COMMIT, 3, 0, 1, 0, 126, 0).

hex(Text) -> binary:decode_hex(Text).

%% ---- Annex J.10 ----

-define(LOCAL_RAND, hex(<<"992465fd3daa3c60aa6565b7f62a2a7f2e12dd12f198faf4fbed89d7ff1ace94">>)).
-define(LOCAL_MASK, hex(<<"9507a90f777a044d6a0830b91ea3d5dd70bece44e1acffb86983b5e1bf9fb322">>)).
-define(LOCAL_COMMIT, hex(<<"13002e2c0f0db52440ad146d967114ce005ce1eab0aa2c2e5c2871b774f6c2575c65d5ad9e00829707aa36"
                            "ba8b859738fc961d08243505f47c035376d7ac4bc8d7b95083bf43827d0fc31ed778dd3671fd21a46d1091"
                            "d64b6f9a1e1272621325dbe1">>)).
-define(PEER_COMMIT, hex(<<"1300591b96f3397fb945100848e7b550543b6720d88337ee93fc49fd6df7e08b5223e71b9bb048d3873f2055"
                           "6953a96c91536fd8ee6ca9b4a68a148b056a909be03e83ae208f60f8ef5537858074db06687032399862999b"
                           "511e0a1552a5fea317c2">>)).
-define(KCK, hex(<<"1e733f6d9bd53256287304338831b09a39406d121017073a5c30db36f36cb81a">>)).
-define(PMK, hex(<<"4e4dfab1a2dd8ac1a91790f953faaa452ae5c6873ab75b63605ba663f8a7fe59">>)).

%% PT from the hashed values of SSID, password and identifier, then PWE between two
%% other addresses (common_module_tests.c, sae_tests, group 19).
pt_and_pwe_vector_test() ->
    {U1, U2} = erx_sae_peer:hashed_values(?SSID, ?PASSWORD, <<"psk4internet">>),
    Pwe = erx_sae_peer:pwe(erx_sae_peer:pt(U1, U2), hex(<<"00095b66ec1e">>), hex(<<"000b6bd90246">>)),
    ?assertEqual(hex(<<"c93049b9e64000f848201649e999f2b5c22dea69b5632c9df4d633b8aa1f6c1e"
                       "73634e94b53d82e7383a8d258199d9dc1a5ee8269d060382ccbf33e614ff59a0">>),
                 erx_sae_peer:encode(Pwe)).

%% The vector's commit is hunting-and-pecking's, whose PWE it does not state: PWE is
%% recovered from the element and mask. Its scalar is rand plus mask, and K, KCK and
%% PMK follow from the peer's commit with the zero salt that hash-to-element also uses
%% when neither party rejected a group.
key_vector_test() ->
    <<19:16/little, Scalar:256, Element:64/binary>> = ?LOCAL_COMMIT,
    <<19:16/little, PeerScalar:256, PeerElement:64/binary>> = ?PEER_COMMIT,
    #{r := R} = erx_sae_peer:curve(),
    Mask = binary:decode_unsigned(?LOCAL_MASK),
    ?assertEqual(Scalar, (binary:decode_unsigned(?LOCAL_RAND) + Mask) rem R),
    Pwe = erx_sae_peer:mul(erx_sae_peer:scalar_inverse(Mask), erx_sae_peer:neg(erx_sae_peer:point(Element))),
    ?assertEqual({?KCK, ?PMK}, erx_sae_peer:key(Pwe, ?LOCAL_RAND, Scalar, PeerScalar, erx_sae_peer:point(PeerElement), <<>>)).

%% erx_sae's commit carries the holder's scalar and element after the group, as the
%% vector's does, under status 126; its confirm is HMAC-SHA256 under the KCK over its
%% send-confirm, its own scalar and element, then the peer's.
frames_vector_test() ->
    <<19:16/little, Scalar:32/binary, Element:64/binary>> = ?LOCAL_COMMIT,
    <<19:16/little, PeerScalar:32/binary, PeerElement:64/binary>> = ?PEER_COMMIT,
    {[{keys, {sae_commit, #{ssid := ?SSID, spa := ?SPA, aa := ?AA}}}], S1, {running, _}} = start(),
    {[{auth_frame, Commit}], S2, {running, _}} = step(S1, {key, {ok, Scalar, Element}}),
    ?assertEqual(<<?H2E_COMMIT, (?LOCAL_COMMIT)/binary>>, Commit),
    {[{keys, Ask}], S3, {running, _}} = step(S2, {auth_frame, <<?H2E_COMMIT, (?PEER_COMMIT)/binary>>}),
    ?assertEqual({sae_key, #{ssid => ?SSID, scalar => PeerScalar, element => PeerElement, rejected => <<>>}}, Ask),
    {[{auth_frame, Confirm}], _S4, {running, _}} = step(S3, {key, {ok, ?KCK}}),
    Mac = crypto:mac(hmac, sha256, ?KCK, [<<1:16/little>>, Scalar, Element, PeerScalar, PeerElement]),
    ?assertEqual(<<3, 0, 2, 0, 0, 0, 1, 0, Mac/binary>>, Confirm).

%% ---- Whole exchanges ----

exchange_test_() ->
    [{Name, fun() ->
                {accepted, _S, H, Ap, _Sent} = exchange(Config),
                ?assertEqual(erx_sae_peer:ap_pmk(Ap), erx_sae_peer:holder_pmk(H)),
                ?assertEqual([1], erx_sae_peer:ap_confirms(Ap))
            end}
     || {Name, Config} <- [{"plain", #{}},
                           {"with a Rejected Groups list", #{rejected => <<20:16/little, 21:16/little>>}},
                           {"with an anti-clogging token", #{token => binary:copy(<<"t">>, 40)}}]].

anti_clogging_token_test() ->
    Token = binary:copy(<<"t">>, 40),
    {accepted, _, _, _, [First, Second | _]} = exchange(#{token => Token}),
    ?assertEqual(nomatch, binary:match(First, Token)),
    ?assertEqual(<<255, 41, 93, Token/binary>>, binary:part(Second, byte_size(Second), -43)).

%% ---- What the air sends ----

reflected_commit_test() ->
    {S, _H, Ap, Commit} = committed(#{}),
    <<_:8/binary, Scalar:32/binary, Element:64/binary>> = Commit,
    <<_:8/binary, ApScalar:32/binary, ApElement:64/binary>> = erx_sae_peer:ap_commit(Ap),
    [?assertEqual({[], S, {drop, sae_reflected}}, step(S, {auth_frame, peer_commit(Sc, El)}))
     || {Sc, El} <- [{Scalar, Element}, {Scalar, ApElement}, {ApScalar, Element}]].

invalid_element_dropped_before_the_holder_test() ->
    {S, _H, Ap, _Commit} = committed(#{}),
    #{p := P} = erx_sae_peer:curve(),
    <<_:8/binary, ApScalar:32/binary, X:32/binary, Y:32/binary>> = erx_sae_peer:ap_commit(Ap),
    [?assertEqual({[], S, {drop, bad_element}}, step(S, {auth_frame, peer_commit(ApScalar, Element)}))
     || Element <- [<<P:256, Y/binary>>, <<X/binary, P:256>>, <<(P + 1):256, Y/binary>>, <<-1:512>>]].

off_curve_element_dropped_then_genuine_commit_test() ->
    {S, H, Ap0, Commit} = committed(#{}),
    {_, Ap} = erx_sae_peer:ap_take(Commit, Ap0),
    <<_:8/binary, ApScalar:32/binary, X:32/binary, Y:256>> = erx_sae_peer:ap_commit(Ap),
    {[{keys, Ask}], S1, {running, _}} = step(S, {auth_frame, peer_commit(ApScalar, <<X/binary, (Y bxor 1):256>>)}),
    {{error, bad_element}, H1} = erx_sae_peer:holder(Ask, H),
    ?assertEqual({[], S1, {drop, bad_element}}, step(S1, {key, {error, bad_element}})),
    {accepted, _, _, _, _} = run(S1, H1, Ap, [{auth_frame, erx_sae_peer:ap_commit(Ap)}]).

scalar_out_of_range_test() ->
    {S, _H, Ap, _Commit} = committed(#{}),
    #{r := R} = erx_sae_peer:curve(),
    <<_:40/binary, ApElement:64/binary>> = erx_sae_peer:ap_commit(Ap),
    [?assertEqual({[], S, {drop, bad_element}}, step(S, {auth_frame, peer_commit(<<Scalar:256>>, ApElement)}))
     || Scalar <- [0, 1, R, R + 1, (1 bsl 256) - 1]],
    {[{keys, {sae_key, _}}], _, _} = step(S, {auth_frame, peer_commit(<<(R - 1):256>>, ApElement)}).

downgrade_list_naming_group_19_ends_the_exchange_test() ->
    {S, _H, Ap, _Commit} = committed(#{}),
    Commit = erx_sae_peer:ap_commit(Ap),
    ?assertMatch({[], _, {failed, bss}}, step(S, {auth_frame, <<Commit/binary, 255, 5, 92, 20, 0, 19, 0>>})),
    [?assertEqual({[], S, {drop, sae_malformed}}, step(S, {auth_frame, <<Commit/binary, 255, Len, 92, List/binary>>}))
     || {Len, List} <- [{4, <<20, 0, 21>>}, {1, <<>>}]].

confirm_send_confirm_is_verified_test() ->
    {S, Ap} = confirmed(#{}),
    <<Head:6/binary, 1:16/little, Mac/binary>> = erx_sae_peer:ap_confirm(Ap, 1),
    ?assertMatch({[], _, {failed, secret}}, step(S, {auth_frame, <<Head/binary, 2:16/little, Mac/binary>>})),
    ?assertMatch({[], _, accepted}, step(S, {auth_frame, erx_sae_peer:ap_confirm(Ap, 9)})).

wrong_confirm_ends_as_secret_test() ->
    {S, Ap} = confirmed(#{}),
    <<Frame:39/binary, Last>> = erx_sae_peer:ap_confirm(Ap, 1),
    ?assertMatch({[], _, {failed, secret}}, step(S, {auth_frame, <<Frame/binary, (Last bxor 1)>>})).

statuses_test() ->
    {S, _H, Ap, _Commit} = committed(#{}),
    <<_:6/binary, Body/binary>> = erx_sae_peer:ap_commit(Ap),
    ?assertMatch({[], _, {failed, secret}}, step(S, {auth_frame, <<3, 0, 1, 0, 123, 0>>})),
    ?assertMatch({[], _, {failed, bss}}, step(S, {auth_frame, <<3, 0, 1, 0, 77, 0, 19, 0>>})),
    ?assertMatch({[], _, {failed, bss}}, step(S, {auth_frame, <<3, 0, 2, 0, 1, 0>>})),
    ?assertEqual({[], S, {drop, sae_malformed}}, step(S, {auth_frame, <<3, 0, 1, 0, 0, 0, Body/binary>>})),
    ?assertEqual({[], S, {drop, sae_malformed}}, step(S, {auth_frame, <<0, 0, 1, 0, 126, 0, Body/binary>>})),
    ?assertEqual({[], S, {drop, sae_unexpected}}, step(S, {auth_frame, <<3, 0, 2, 0, 0, 0, 1, 0, 0:256>>})),
    {C, _Ap} = confirmed(#{}),
    ?assertMatch({[], _, {failed, secret}}, step(C, {auth_frame, <<3, 0, 2, 0, 1, 0>>})),
    ?assertEqual({[], C, {drop, sae_unexpected}}, step(C, {auth_frame, erx_sae_peer:ap_commit(Ap)})),
    ?assertEqual({[], C, {drop, sae_unexpected}}, step(C, {auth_frame, erx_sae_peer:ap_token_request(Ap#{token := <<"x">>})})).

%% Each frame is sent again 1 s after the last at most twice; the exchange ends 5 s
%% after it started, as `bss` before the confirm and as `secret` after it.
retry_limits_test() ->
    {S, _H, _Ap, Commit} = committed(#{}),
    {[{auth_frame, Commit}], S1, {running, 2000}} = step(S, deadline, 1000),
    {[{auth_frame, Commit}], S2, {running, 3000}} = step(S1, deadline, 2000),
    {[], S3, {running, 5000}} = step(S2, deadline, 3000),
    {[], _, {failed, bss}} = step(S3, deadline, 5000),
    {C, Ap} = confirmed(#{}),
    {[{auth_frame, Confirm2}], C1, {running, 2000}} = step(C, deadline, 1000),
    {[{auth_frame, Confirm3}], C2, {running, 3000}} = step(C1, deadline, 2000),
    {[], C3, {running, 5000}} = step(C2, deadline, 3000),
    {[], _, {failed, secret}} = step(C3, deadline, 5000),
    {_, Ap1} = erx_sae_peer:ap_take(Confirm2, Ap),
    {_, Ap2} = erx_sae_peer:ap_take(Confirm3, Ap1),
    ?assertEqual([2, 3], erx_sae_peer:ap_confirms(Ap2)).

%% The station's identifier goes in its commit, and the peer's commit must carry it.
password_identifier_test() ->
    Sae = erx_sae:new(#{ssid => ?SSID, spa => ?SPA, aa => ?AA, identifier => <<"psk4internet">>}),
    {[{keys, Ask}], S0, _} = step(Sae, start),
    {Answer, _} = erx_sae_peer:holder(Ask, erx_sae_peer:holder_new(pt(), draws())),
    {[{auth_frame, Commit}], S, _} = step(S0, {key, Answer}),
    ?assertEqual(<<255, 13, 33, "psk4internet">>, binary:part(Commit, byte_size(Commit), -15)),
    ApCommit = erx_sae_peer:ap_commit(ap(#{})),
    ?assertEqual({[], S, {drop, sae_malformed}}, step(S, {auth_frame, ApCommit})),
    ?assertEqual({[], S, {drop, sae_malformed}}, step(S, {auth_frame, <<ApCommit/binary, 255, 4, 33, "psk">>})),
    {[{keys, {sae_key, _}}], _, _} = step(S, {auth_frame, <<ApCommit/binary, 255, 13, 33, "psk4internet">>}),
    ?assertError(function_clause, erx_sae:new(#{ssid => ?SSID, spa => ?SPA, aa => ?AA, identifier => binary:copy(<<"i">>, 65)})).

%% A holder that has not answered by the exchange's end, or that has no exchange,
%% ends it as `bss`.
holder_failures_test() ->
    {[{keys, _}], S0, {running, 5000}} = start(),
    {[], _, {failed, bss}} = step(S0, deadline, 5000),
    {S, _H, Ap, _Commit} = committed(#{}),
    {[{keys, _}], S1, _} = step(S, {auth_frame, erx_sae_peer:ap_commit(Ap)}),
    {[], _, {failed, bss}} = step(S1, {key, {error, no_commit}}).

tested_after_the_confirm_test() ->
    {S, _H, _Ap, _Commit} = committed(#{}),
    ?assertNot(erx_sae:tested(S)),
    {C, _} = confirmed(#{}),
    ?assert(erx_sae:tested(C)).

%% Every truncation of the access point's frames, and random bytes behind a valid
%% header, are dropped or end the exchange, in either state; a drop changes nothing.
malformed_frames_test() ->
    {S, _H, Ap0, Commit} = committed(#{}),
    {_, Ap} = erx_sae_peer:ap_take(Commit, Ap0),
    {C, _} = confirmed(#{}),
    Genuine = [erx_sae_peer:ap_commit(Ap), erx_sae_peer:ap_confirm(Ap, 1), erx_sae_peer:ap_token_request(Ap#{token := <<"tok">>})],
    rand:seed(exsss, {1, 2, 3}),
    Frames = [binary:part(F, 0, N) || F <- Genuine, N <- lists:seq(0, byte_size(F) - 1)]
        ++ [<<Head:6/binary, (rand:bytes(rand:uniform(200) - 1))/binary>>
            || Head <- [<<3, 0, 1, 0, 126, 0>>, <<3, 0, 1, 0, 76, 0>>, <<3, 0, 2, 0, 0, 0>>], _ <- lists:seq(1, 300)]
        ++ [<<3, 0, 1, 0, 126, 0, 19, 0, (rand:bytes(96))/binary, 255, (rand:uniform(256) - 1), Ext, (rand:bytes(rand:uniform(20)))/binary>>
            || Ext <- [33, 92, 93], _ <- lists:seq(1, 200)],
    [case {Sae, Frame, step(Sae, {auth_frame, Frame})} of
         {_, _, {[], Sae, {drop, _}}} -> ok;
         {C, <<3, 0, 2, 0, 0, 0, _:34/binary, _/binary>>, {[], _, {failed, secret}}} -> ok;
         {S, <<3, 0, 1, 0, 126, 0, _/binary>>, {[{keys, {sae_key, _}}], _, {running, _}}} -> ok;
         {S, <<3, 0, 1, 0, 76, 0, _/binary>>, {[{auth_frame, _}], _, {running, _}}} -> ok
     end || Sae <- [S, C], Frame <- Frames].

%% ---- The exchange's parties ----

draws() -> [{<<N:256>>, <<(N + 7):256>>} || N <- [1, 11, 23, 37]].

pt() ->
    {U1, U2} = erx_sae_peer:hashed_values(?SSID, ?PASSWORD, <<>>),
    erx_sae_peer:pt(U1, U2).

ap(Config) ->
    erx_sae_peer:ap_new(Config#{pt => pt(), aa => ?AA, spa => ?SPA, rand => <<41:256>>, mask => <<1000003:256>>}).

start() -> erx_sae:step(erx_sae:new(#{ssid => ?SSID, spa => ?SPA, aa => ?AA}), start, #{now => 0}).

step(Sae, Event) -> step(Sae, Event, 0).
step(Sae, Event, Now) -> erx_sae:step(Sae, Event, #{now => Now}).

peer_commit(Scalar, Element) -> <<?H2E_COMMIT, 19, 0, Scalar/binary, Element/binary>>.

%% The station after its commit, with its holder and an access point that has not seen it.
committed(Config) ->
    {[{keys, Ask}], S0, _} = start(),
    {Answer, H} = erx_sae_peer:holder(Ask, erx_sae_peer:holder_new(pt(), draws())),
    {[{auth_frame, Commit}], S, _} = step(S0, {key, Answer}),
    {S, H, ap(Config), Commit}.

%% The station after its confirm, and the access point that took its commit.
confirmed(Config) ->
    {S, H, Ap0, Commit} = committed(Config),
    {[ApCommit], Ap} = erx_sae_peer:ap_take(Commit, Ap0),
    {[{keys, Ask}], S1, _} = step(S, {auth_frame, ApCommit}),
    {Answer, _} = erx_sae_peer:holder(Ask, H),
    {[{auth_frame, _Confirm}], C, _} = step(S1, {key, Answer}),
    {C, Ap}.

%% A whole exchange at time 0: the holder answers each request before any other
%% event, the access point answers each frame the station sends; an exchange that
%% takes more than 20 steps has stalled.
exchange(Config) ->
    {[{keys, Ask}], S0, _} = start(),
    {Answer, H} = erx_sae_peer:holder(Ask, erx_sae_peer:holder_new(pt(), draws())),
    run(S0, H, ap(Config), [{key, Answer}]).

run(S, H, Ap, Events) -> run(S, H, Ap, Events, [], 20).

run(S, H, Ap, Events, Sent, Budget) when Events =:= []; Budget =:= 0 -> {stalled, S, H, Ap, lists:reverse(Sent)};
run(S0, H0, Ap0, [Event | Queue], Sent0, Budget) ->
    {Actions, S, Outcome} = step(S0, Event),
    {Front, Back, H, Ap, Sent} =
        lists:foldl(fun({keys, Ask}, {F, B, Hh, A, Sn}) ->
                            {Answer, Hh1} = erx_sae_peer:holder(Ask, Hh),
                            {F ++ [{key, Answer}], B, Hh1, A, Sn};
                       ({auth_frame, Frame}, {F, B, Hh, A, Sn}) ->
                            {Replies, A1} = erx_sae_peer:ap_take(Frame, A),
                            {F, B ++ [{auth_frame, R} || R <- Replies], Hh, A1, [Frame | Sn]}
                    end, {[], [], H0, Ap0, Sent0}, Actions),
    case Outcome of
        accepted -> {accepted, S, H, Ap, lists:reverse(Sent)};
        {failed, Class} -> {{failed, Class}, S, H, Ap, lists:reverse(Sent)};
        _ -> run(S, H, Ap, Front ++ Queue ++ Back, Sent, Budget - 1)
    end.
