%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_wpa_key (docs/design-wifi.md, "The supplicant"): frames written here byte by
%% byte from IEEE 802.11's EAPOL-Key layout, independently of the generated codec,
%% decode to their fields; each malformed frame fails with its rule; key data's
%% elements, KDEs and padding read as wpa_supplicant reads them; and the station's
%% messages carry the fields wpa_supplicant's replies carry, with a MIC that checks.
-module(erx_wpa_key_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(KCK, <<16#11:128>>).

%% An access point's message 1 for PSK: Key Information 0x008a (version 2, pairwise,
%% Ack), key length 16, replay counter 1, the ANonce, no MIC and no key data.
message_1() ->
    eapol(16#008a, 16, 1, binary:copy(<<16#aa>>, 32), <<0:64>>, <<0:128>>, <<>>).

%% The EAPOL-Key frame: version 2, type 3, the body length, descriptor 2, then the
%% fields at their offsets (IEEE 802.11-2020, 12.7.2), the Key RSC little-endian.
eapol(Info, KeyLength, Counter, Nonce, Rsc, Mic, Data) ->
    Body = <<2, Info:16, KeyLength:16, Counter:64, Nonce/binary, 0:128, Rsc/binary, 0:64, Mic/binary,
             (byte_size(Data)):16, Data/binary>>,
    <<2, 3, (byte_size(Body)):16, Body/binary>>.

message_1_decodes_to_its_fields_test() ->
    Frame = message_1(),
    ?assertEqual(99, byte_size(Frame)),
    {ok, Key} = erx_wpa_key:decode(<<Frame/binary, 0, 0, 0>>),
    ?assertMatch(#{descriptor_version := 2, pairwise := true, ack := true, install := false, mic_present := false,
                   secure := false, encrypted := false, key_length := 16, replay_counter := 1,
                   rsc := 0, data := <<>>}, Key),
    ?assertEqual(binary:copy(<<16#aa>>, 32), maps:get(nonce, Key)),
    ?assertEqual(Frame, maps:get(frame, Key)).

the_key_rsc_is_little_endian_test() ->
    Frame = eapol(16#1382, 0, 2, <<0:256>>, <<5, 0, 0, 0, 0, 0, 0, 1>>, <<0:128>>, <<>>),
    {ok, #{rsc := Rsc, encrypted := true, secure := true}} = erx_wpa_key:decode(Frame),
    ?assertEqual(16#0100000000000005, Rsc).

each_malformed_frame_fails_with_its_rule_test_() ->
    Good = message_1(),
    <<_:8, AfterVersion/binary>> = Good,
    <<V, _:8, AfterType/binary>> = Good,
    <<V, T, _:16, AfterLength/binary>> = Good,
    <<Head:4/binary, _:8, AfterDescriptor/binary>> = Good,
    <<Prefix:97/binary, _:16>> = Good,
    [?_assertEqual({error, short}, erx_wpa_key:decode(binary:part(Good, 0, 98))),
     ?_assertEqual({error, version}, erx_wpa_key:decode(<<0, AfterVersion/binary>>)),
     ?_assertEqual({error, version}, erx_wpa_key:decode(<<4, AfterVersion/binary>>)),
     ?_assertEqual({error, type}, erx_wpa_key:decode(<<V, 0, AfterType/binary>>)),
     ?_assertEqual({error, body_length}, erx_wpa_key:decode(<<V, T, 96:16, AfterLength/binary>>)),
     ?_assertEqual({error, descriptor}, erx_wpa_key:decode(<<Head/binary, 254, AfterDescriptor/binary>>)),
     ?_assertEqual({error, data_length}, erx_wpa_key:decode(<<Prefix/binary, 1:16>>)),
     %% A body shorter than the frame's fixed part cannot hold its key data.
     ?_assertEqual({error, data_length}, erx_wpa_key:decode(<<V, T, 90:16, AfterLength/binary>>))].

the_mic_input_zeroes_the_mic_alone_test() ->
    Frame = eapol(16#010a, 0, 3, <<0:256>>, <<0:64>>, <<16#ff:128>>, <<1, 2, 3>>),
    {ok, Key} = erx_wpa_key:decode(Frame),
    ?assertEqual(eapol(16#010a, 0, 3, <<0:256>>, <<0:64>>, <<0:128>>, <<1, 2, 3>>), erx_wpa_key:mic_input(Key)).

gtk_kde(Id, Gtk) -> <<221, 22, 0, 16#0f, 16#ac, 1, (Id bor 4), 0, Gtk/binary>>.
igtk_kde(Id, Ipn, Igtk) -> <<221, 28, 0, 16#0f, 16#ac, 9, Id:16/little, Ipn:48/little, Igtk/binary>>.
rsn() -> <<48, 20, 1, 0, 0, 16#0f, 16#ac, 4, 1, 0, 0, 16#0f, 16#ac, 4, 1, 0, 0, 16#0f, 16#ac, 2, 0, 0>>.

key_data_reads_the_elements_and_kdes_test() ->
    Data = <<(rsn())/binary, (gtk_kde(1, <<16#77:128>>))/binary, (igtk_kde(4, 9, <<16#88:128>>))/binary,
             221, 6, 16#50, 16#6f, 16#9a, 16#16, 1, 2>>,
    ?assertEqual({ok, #{rsn => rsn(), rsnxe => none,
                        gtk => #{id => 1, tx => true, key => <<16#77:128>>},
                        igtk => #{id => 4, ipn => 9, key => <<16#88:128>>}}},
                 erx_wpa_key:key_data(Data)).

%% Encrypted key data padded with 0xdd and zeros to a multiple of 8 bytes, by every
%% padding length; nothing after the padding's start is read, even bytes that would
%% not parse, and a lone last byte that is not 0xdd is a cut header.
key_data_padding_ends_the_elements_test_() ->
    Gtk = gtk_kde(2, <<16#33:128>>),
    [?_assertMatch({ok, #{gtk := #{id := 2}, rsn := none}},
                   erx_wpa_key:key_data(<<Gtk/binary, 221, 0:(Pad * 8)>>))
     || Pad <- lists:seq(0, 7)] ++
    [?_assertMatch({ok, #{igtk := none}},
                   erx_wpa_key:key_data(<<Gtk/binary, 221, 0, (igtk_kde(4, 1, <<1:128>>))/binary>>)),
     ?_assertMatch({ok, #{gtk := #{id := 2}}}, erx_wpa_key:key_data(<<Gtk/binary, 221, 0, 48, 200>>)),
     ?_assertEqual({error, truncated}, erx_wpa_key:key_data(<<Gtk/binary, 0>>))].

key_data_refuses_malformed_kdes_test_() ->
    Gtk = gtk_kde(1, <<1:128>>),
    [?_assertEqual({error, {length, gtk}},
                   erx_wpa_key:key_data(<<221, 14, 0, 16#0f, 16#ac, 1, 1, 0, 0:64>>)),
     ?_assertEqual({error, {duplicate, gtk}}, erx_wpa_key:key_data(<<Gtk/binary, Gtk/binary>>)),
     ?_assertEqual({error, {length, igtk}},
                   erx_wpa_key:key_data(<<221, 27, 0, 16#0f, 16#ac, 9, 4, 0, 0:48, 0:120>>)),
     ?_assertEqual({error, {key_id, igtk}}, erx_wpa_key:key_data(igtk_kde(6, 0, <<1:128>>))),
     ?_assertEqual({error, overrun}, erx_wpa_key:key_data(<<48, 30, 1, 0>>)),
     ?_assertEqual({error, truncated}, erx_wpa_key:key_data(<<Gtk/binary, 48>>)),
     ?_assertEqual({error, {duplicate, rsn}}, erx_wpa_key:key_data(<<(rsn())/binary, (rsn())/binary>>))].

%% Message 2 for each AKM: Key Information of its version, pairwise and MIC, Secure
%% only on a rekey; key length 0; the counter echoed; the SNonce; the RSN element as
%% key data; a MIC over the frame with the MIC zero that checks under the KCK.
message_2_carries_the_replys_fields_test_() ->
    [fun() ->
             SNonce = binary:copy(<<16#5a>>, 32),
             Frame = erx_wpa_key:build(message_2, Akm, ?KCK,
                                       #{replay_counter => 7, snonce => SNonce, rsn => rsn(), rekey => Rekey}),
             {ok, Key} = erx_wpa_key:decode(Frame),
             Secure = Rekey,
             ?assertMatch(#{descriptor_version := Version, pairwise := true, mic_present := true, secure := Secure,
                            ack := false, install := false, key_length := 0, replay_counter := 7}, Key),
             ?assertEqual(SNonce, maps:get(nonce, Key)),
             ?assertEqual(rsn(), maps:get(data, Key)),
             <<1, 3, _/binary>> = Frame,
             ?assert(erx_wpa_kdf:check_mic(Akm, ?KCK, erx_wpa_key:mic_input(Key), maps:get(mic, Key)))
     end
     || {Akm, Version} <- [{?ERX_IEEE80211_AKM_PSK, 2}, {?ERX_IEEE80211_AKM_PSK_SHA256, 3},
                           {?ERX_IEEE80211_AKM_SAE, 0}],
        Rekey <- [false, true]].

message_4_and_group_2_carry_no_nonce_or_data_test() ->
    {ok, Four} = erx_wpa_key:decode(erx_wpa_key:build(message_4, ?ERX_IEEE80211_AKM_PSK, ?KCK, #{replay_counter => 8})),
    ?assertMatch(#{pairwise := true, secure := true, mic_present := true, nonce := <<0:256>>, data := <<>>,
                   replay_counter := 8}, Four),
    {ok, Group} = erx_wpa_key:decode(erx_wpa_key:build(group_2, ?ERX_IEEE80211_AKM_PSK, ?KCK, #{replay_counter => 9})),
    ?assertMatch(#{pairwise := false, secure := true, mic_present := true, data := <<>>, replay_counter := 9}, Group),
    ?assert(erx_wpa_kdf:check_mic(?ERX_IEEE80211_AKM_PSK, ?KCK, erx_wpa_key:mic_input(Group), maps:get(mic, Group))).
