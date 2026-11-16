%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_wifi_choose (docs/design-wifi.md, "Choosing a network" and "Verification"):
%% admit/4 over every combination of a block, an SSID's keys, a BSS and the chip,
%% against the design's properties; the PMF table row by row; and choose/1 over
%% generated views, every `want`, the names unavailable or listing secrets and
%% marks, and memories of holds past and present.
-module(erx_wifi_choose_tests).

-include_lib("eunit/include/eunit.hrl").

-define(AKMS, [psk, psk_sha256, sae]).
-define(SSIDS, [<<"home">>, <<"cafe">>, <<"lab">>]).

%% Every non-empty sublist of List.
subsets(List) ->
    [S || S <- lists:foldr(fun(X, Acc) -> Acc ++ [[X | S] || S <- Acc] end, [[]], List), S =/= []].

bools() -> [false, true].

blocks() ->
    [#{key_mgmt => [none], ieee80211w => 0, priority => 0}
     | [#{key_mgmt => Akms, ieee80211w => W, priority => 0}
        || Akms <- subsets(?AKMS), W <- [0, 1, 2], not (W =:= 0 andalso lists:member(sae, Akms))]].

all_keys() ->
    [unavailable | [#{psk => P, sae => S, sae_only => O} || P <- bools(), S <- bools(), O <- bools()]].

rsn(Akms, {Pairwise, Group}, {Mfpc, Mfpr}) ->
    #{akms => Akms, pairwise => Pairwise, group => Group, mfpc => Mfpc, mfpr => Mfpr}.

bss(Ssid, Bssid, Signal, Security, H2e) ->
    #{bssid => Bssid, ssid => Ssid, signal => Signal, security => Security, h2e => H2e}.

securities() ->
    [open, legacy
     | [{rsn, rsn(Akms, Ciphers, Mfp)}
        || Akms <- subsets([psk, psk_sha256, sae, {other, 1}]),
           Ciphers <- [{[ccmp], ccmp}, {[tkip], tkip}, {[ccmp, tkip], tkip}, {[ccmp, tkip], ccmp}],
           Mfp <- [{false, false}, {true, false}, {true, true}, {false, true}]]].

chips() -> [#{sae_ext => E, mfp => M} || E <- bools(), M <- bools()].

%% The design's PMF table, written out as its rows read: the PMF, or refused.
pmf_row(2, #{mfpc := true}, true) -> required;
pmf_row(2, #{mfpc := true}, false) -> refused;
pmf_row(2, #{mfpc := false}, _Mfp) -> refused;
pmf_row(1, #{mfpr := true}, true) -> required;
pmf_row(1, #{mfpr := true}, false) -> refused;
pmf_row(1, #{mfpc := true, mfpr := false}, true) -> capable;
pmf_row(1, #{mfpc := true, mfpr := false}, false) -> none;
pmf_row(1, #{mfpc := false}, _Mfp) -> none;
pmf_row(0, #{mfpr := true}, _Mfp) -> refused;
pmf_row(0, #{mfpr := false}, _Mfp) -> none.

%% The AKMs the station may use on a protected BSS, stated from the design's text
%% independently of admit/4's rule order.
usable(#{key_mgmt := Allowed}, Keys, #{akms := Offered}, H2e, Pmf, #{sae_ext := SaeExt}) ->
    [Akm || Akm <- ?AKMS, lists:member(Akm, Allowed), lists:member(Akm, Offered),
            case Akm of
                sae -> maps:get(sae, Keys) andalso SaeExt andalso H2e andalso Pmf =/= none;
                _ -> maps:get(psk, Keys) andalso not maps:get(sae_only, Keys)
            end].

admission_keeps_every_property_over_every_combination_test_() ->
    {timeout, 120, fun() ->
        Cases = [{B, K, bss(<<"home">>, <<0:48>>, 0, Sec, H), C}
                 || B <- blocks(), K <- all_keys(), Sec <- securities(), H <- bools(), C <- chips()],
        Admitted = lists:filter(fun(Case) -> check_admission(Case) end, Cases),
        ?assert(length(Admitted) > 1000)
    end}.

%% Asserts the properties of one admission; whether it admitted. A protected BSS is
%% admitted exactly when the oracle finds a usable AKM, and then with the best one.
check_admission({Block, Keys, #{security := Security, h2e := H2e} = Bss, Chip} = Case) ->
    Open = maps:get(key_mgmt, Block) =:= [none],
    Admission = erx_wifi_choose:admit(Block, Keys, Bss, Chip),
    case Security of
        open ->
            ?assertEqual(case Open of true -> {ok, none, none}; false -> {refused, not_open} end, Admission, Case);
        legacy ->
            ?assertMatch({refused, _}, Admission, Case);
        {rsn, _} when Open; Keys =:= unavailable ->
            ?assertMatch({refused, _}, Admission, Case),
            Open orelse ?assertEqual({refused, keys_unavailable}, Admission, Case);
        {rsn, #{pairwise := Pairwise, group := Group} = Rsn} ->
            Pmf = pmf_row(maps:get(ieee80211w, Block), Rsn, maps:get(mfp, Chip)),
            Ciphers = lists:member(ccmp, Pairwise) andalso Group =:= ccmp,
            Usable = case Pmf =/= refused andalso Ciphers of
                         true -> usable(Block, Keys, Rsn, H2e, Pmf, Chip);
                         false -> []
                     end,
            case Usable of
                [] ->
                    ?assertMatch({refused, _}, Admission, Case);
                _ ->
                    %% SAE when it is usable, PSK-SHA256 before PSK: no downgrade.
                    Best = hd([A || A <- [sae, psk_sha256, psk], lists:member(A, Usable)]),
                    ?assertEqual({ok, Best, Pmf}, Admission, Case),
                    (maps:get(key_mgmt, Block) =:= [sae] orelse maps:get(sae_only, Keys))
                        andalso ?assertEqual(sae, Best, Case)
            end
    end,
    case Admission of {ok, _, _} -> true; {refused, _} -> false end.

%% The design's PMF table: block's ieee80211w, the BSS's MFPC and MFPR, the
%% firmware's `mfp`, and the PMF or the refusal.
pmf_follows_the_design_table_row_by_row_test() ->
    Rows = [{2, {true, false}, true, required}, {2, {true, true}, false, pmf_unavailable},
            {2, {false, false}, true, pmf_required}, {1, {true, true}, true, required},
            {1, {true, true}, false, pmf_unavailable}, {1, {true, false}, true, capable},
            {1, {true, false}, false, none}, {1, {false, false}, true, none},
            {1, {false, true}, true, required}, {0, {true, true}, true, pmf_required},
            {0, {true, false}, true, none}, {0, {false, false}, false, none}],
    Keys = #{psk => true, sae => false, sae_only => false},
    [begin
         Block = #{key_mgmt => [psk], ieee80211w => W, priority => 0},
         Bss = bss(<<"x">>, <<0:48>>, 0, {rsn, rsn([psk], {[ccmp], ccmp}, Mfp)}, false),
         Got = case erx_wifi_choose:admit(Block, Keys, Bss, #{sae_ext => true, mfp => Answers}) of
                   {ok, psk, Pmf} -> Pmf;
                   {refused, Reason} -> Reason
               end,
         ?assertEqual({W, Mfp, Answers, Expected}, {W, Mfp, Answers, Got})
     end || {W, Mfp, Answers, Expected} <- Rows].

-define(WPA3, {rsn, rsn([sae], {[ccmp], ccmp}, {true, true})}).
-define(MIXED, {rsn, rsn([psk, sae], {[ccmp], ccmp}, {true, false})}).
-define(CHIP, #{sae_ext => true, mfp => true}).

view(Bsss, Overrides) ->
    maps:merge(#{blocks => #{}, names => {ok, #{}}, marks => [], bsss => Bsss,
                 memory => erx_wifi_memory:new(), want => any, chip => ?CHIP, joined => none, now => 0},
               Overrides).

entry(Psk, Sae) -> #{psk => Psk, sae => Sae, mark => none}.

verdicts(View) -> [V || {_, V} <- maps:get(verdicts, erx_wifi_choose:choose(View))].

a_secret_alone_makes_a_network_joinable_with_the_default_block_test() ->
    Bss = bss(<<"home">>, <<1:48>>, -50, ?MIXED, true),
    View = view([Bss], #{names => {ok, #{<<"home">> => entry(true, true)}}}),
    ?assertMatch(#{pick := #{bss := Bss, akm := sae, pmf := capable}}, erx_wifi_choose:choose(View)),
    ?assertEqual([{candidate, psk, capable}],
                 verdicts(View#{names := {ok, #{<<"home">> => entry(true, false)}}})).

the_names_tell_unknown_from_no_secret_and_unavailable_says_neither_test() ->
    Bsss = [bss(<<"home">>, <<1:48>>, -50, ?WPA3, true), bss(<<"cafe">>, <<2:48>>, -50, ?WPA3, true)],
    Blocks = #{<<"home">> => erx_wifi_choose:default_block()},
    ?assertEqual([{refused, no_secret}, unknown], verdicts(view(Bsss, #{blocks => Blocks}))),
    ?assertEqual([{refused, keys_unavailable}, {refused, keys_unavailable}],
                 verdicts(view(Bsss, #{blocks => Blocks, names => unavailable}))).

an_open_impostor_of_a_saved_ssid_is_refused_whatever_the_holder_answers_test() ->
    Impostor = bss(<<"home">>, <<1:48>>, -30, open, false),
    Blocks = #{<<"home">> => erx_wifi_choose:default_block()},
    [?assertEqual([{refused, not_open}], verdicts(view([Impostor], #{blocks => Blocks, names => Names, want => Want})))
     || Names <- [unavailable, {ok, #{}}, {ok, #{<<"home">> => entry(true, true)}}],
        Want <- [any, {only, <<"home">>}]],
    ?assertMatch([{candidate, none, none}],
                 verdicts(view([Impostor], #{blocks => Blocks, want => {open, <<"home">>}}))),
    ?assertEqual([{refused, akm_unsupported}],
                 verdicts(view([bss(<<"home">>, <<1:48>>, -30, ?WPA3, true)],
                               #{want => {open, <<"home">>}}))).

the_pick_is_the_highest_priority_then_the_strongest_and_never_held_test() ->
    Names = {ok, #{<<"home">> => entry(true, false), <<"cafe">> => entry(true, false)}},
    Psk = {rsn, rsn([psk], {[ccmp], ccmp}, {false, false})},
    Weak = bss(<<"home">>, <<1:48>>, -70, Psk, false),
    Strong = bss(<<"home">>, <<2:48>>, -40, Psk, false),
    Cafe = bss(<<"cafe">>, <<3:48>>, -80, Psk, false),
    Blocks = #{<<"cafe">> => (erx_wifi_choose:default_block())#{priority => 5}},
    View = view([Weak, Strong, Cafe], #{names => Names}),
    ?assertMatch(#{pick := #{bss := Strong}}, erx_wifi_choose:choose(View)),
    ?assertMatch(#{pick := #{bss := Cafe}}, erx_wifi_choose:choose(View#{blocks := Blocks})),
    Held = erx_wifi_memory:fail(erx_wifi_memory:new(), {bss, <<2:48>>, <<"home">>}, 0),
    ?assertMatch(#{pick := #{bss := Weak}, verdicts := [_, {_, {held, bss, 10000}}, _]},
                 erx_wifi_choose:choose(View#{memory := Held})),
    ?assertMatch(#{pick := none}, erx_wifi_choose:choose(View#{want := none})),
    ?assertMatch(#{pick := #{bss := Weak}, verdicts := [_, {_, joined}, _]},
                 erx_wifi_choose:choose(View#{joined := <<2:48>>})).

%% Generated views: a few SSIDs, BSSs of every security, every `want`, names
%% unavailable or listing random secrets and marks, the station's marks, and a
%% memory made by random failures before the view's time.
choose_keeps_every_property_over_generated_views_test_() ->
    {timeout, 120, fun() ->
        rand:seed(exsss, {16#e7, 16#05, 16#1f}),
        Securities = list_to_tuple(securities()),
        Blocks = list_to_tuple(blocks()),
        [check_choice(random_view(Securities, Blocks)) || _ <- lists:seq(1, 20000)]
    end}.

any_of(List) -> lists:nth(rand:uniform(length(List)), List).

random_view(Securities, Blocks) ->
    Bsss = [bss(any_of(?SSIDS), <<N:48>>, -rand:uniform(90), element(rand:uniform(tuple_size(Securities)), Securities),
                rand:uniform(2) =:= 1)
            || N <- lists:seq(1, rand:uniform(6))],
    Configured = maps:from_list([{Ssid, (element(rand:uniform(tuple_size(Blocks)), Blocks))#{priority => rand:uniform(3)}}
                                 || Ssid <- ?SSIDS, rand:uniform(3) =:= 1]),
    Names = case rand:uniform(4) of
                1 -> unavailable;
                _ -> {ok, maps:from_list([{Ssid, #{psk => any_of(bools()), sae => any_of(bools()),
                                                   mark => any_of([none, none, pending, kept])}}
                                          || Ssid <- ?SSIDS, rand:uniform(2) =:= 1])}
            end,
    Memory = lists:foldl(fun(_, M) ->
                                 #{bssid := Bssid, ssid := Ssid} = any_of(Bsss),
                                 erx_wifi_memory:fail(M, {any_of([bss, secret]), Bssid, Ssid}, -rand:uniform(600000))
                         end, erx_wifi_memory:new(), lists:seq(1, rand:uniform(5) - 1)),
    view(Bsss, #{blocks => Configured, names => Names, marks => [S || S <- ?SSIDS, rand:uniform(5) =:= 1],
                 memory => Memory, want => any_of([any, none, {only, any_of(?SSIDS)}, {open, any_of(?SSIDS)}]),
                 chip => any_of(chips()), joined => any_of([none, <<1:48>>])}).

check_choice(View) ->
    #{verdicts := Verdicts, pick := Pick} = Chosen = erx_wifi_choose:choose(View),
    #{blocks := Blocks, names := Names, marks := Marks, want := Want} = View,
    ?assertEqual(maps:get(bsss, View), [Bss || {Bss, _} <- Verdicts]),
    [begin
         Admitted = admitted(Verdict),
         %% WF16: an open BSS only by a statement that its network is open.
         Admitted andalso Security =:= open
             andalso ?assert(Want =:= {open, Ssid} orelse maps:get(key_mgmt, maps:get(Ssid, Blocks, #{key_mgmt => []})) =:= [none],
                             {View, Bss}),
         %% With the names unavailable nothing protected is admitted, and nothing is unknown.
         Names =:= unavailable andalso ?assertNot(Admitted andalso Security =/= open, {View, Bss}),
         Names =:= unavailable andalso ?assertNotEqual(unknown, Verdict, {View, Bss}),
         %% WF14 and the AKM's own secret, from the names and marks as the view
         %% holds them: SAE-only by the station's marks or the entry's mark.
         check_secret(Verdict, Ssid, Names, Marks, {View, Bss})
     end || {#{ssid := Ssid, security := Security} = Bss, Verdict} <- Verdicts],
    Candidates = [{Bss, Akm, Pmf} || {Bss, {candidate, Akm, Pmf}} <- Verdicts],
    case Pick of
        none ->
            ?assertEqual([], Candidates, View);
        #{bss := PickBss, akm := PickAkm, pmf := PickPmf} ->
            ?assertNotEqual(none, Want),
            ?assert(lists:member({PickBss, PickAkm, PickPmf}, Candidates), View),
            Rank = fun(#{ssid := Ssid, signal := Signal}) ->
                           {maps:get(priority, maps:get(Ssid, Blocks, #{priority => 0})), Signal}
                   end,
            ?assert(lists:all(fun({Bss, _, _}) -> Rank(Bss) =< Rank(PickBss) end, Candidates), View)
    end,
    %% WF13: the memory only turns a candidate into a held one.
    #{verdicts := Forgotten} = erx_wifi_choose:choose(View#{memory := erx_wifi_memory:new()}),
    lists:foreach(fun({{_, Remembered}, {_, Fresh}}) ->
                          Remembered =:= Fresh
                              orelse ?assertMatch({{held, _, _}, {candidate, _, _}}, {Remembered, Fresh}, View)
                  end, lists:zip(Verdicts, Forgotten)),
    Chosen.

admitted(joined) -> true;
admitted({candidate, _, _}) -> true;
admitted({held, _, _}) -> true;
admitted(_Verdict) -> false.

%% A candidate's AKM has its own secret in the SSID's entry, and an SSID that the
%% station's marks or the entry's mark make SAE-only is joined with SAE alone.
check_secret({candidate, Akm, _Pmf}, Ssid, {ok, Entries}, Marks, Context) when Akm =/= none ->
    #{psk := Psk, sae := Sae, mark := Mark} = maps:get(Ssid, Entries, #{psk => false, sae => false, mark => none}),
    SaeOnly = lists:member(Ssid, Marks) orelse Mark =/= none,
    case Akm of
        sae -> ?assert(Sae, Context);
        _ -> ?assert(Psk andalso not SaeOnly, Context)
    end;
check_secret(_Verdict, _Ssid, _Names, _Marks, _Context) ->
    ok.
