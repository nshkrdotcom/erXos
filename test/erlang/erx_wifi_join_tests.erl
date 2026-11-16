%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The join machine, explored (docs/design-wifi.md, "Verification", erx_wifi_join):
%% every sequence of events up to a bound from three starting points (the pick, the
%% association, an open port), against a fake access point that computes real MICs
%% and wraps real key data, a fake key holder that derives each PTK from the PMK, and
%% a fake chip that keeps what each slot holds and held. Each step is checked for the
%% design's properties as it is taken; every edge of erx_wifi_join:table/0 must be
%% taken and no other. The design's longer scenarios run as scripted sequences through
%% the same checks. test/host/erx_wifi_join_test.rb compiles erx_sae_fake.erl in place
%% of erx_sae.
-module(erx_wifi_join_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(SSID, <<"erxos">>).
-define(AA, <<2, 0, 0, 0, 0, 1>>).
-define(SPA, <<2, 0, 0, 0, 0, 2>>).
-define(DEPTH, 5).
-define(REPLAYS, 3).
-define(SHORT_LINK_MS, 10_000).

%% ---- The exploration ----

exploration_keeps_every_property_test_() ->
    {timeout, 600, fun() ->
        put(edges, #{}),
        Visited = lists:sum([map_size(explore(Name)) || Name <- [psk, psk_sha256_pmf, sae, open]]),
        ?assert(Visited > 1000),
        Taken = lists:sort(maps:keys(get(edges))),
        ?assertEqual(table_edges(), Taken)
    end}.

table_edges() ->
    lists:sort([{Kind, From, To} || Kind := {_, Cells} <- erx_wifi_join:table(),
                                    From := Tos <- Cells, To <- Tos]).

explore(Name) ->
    lists:foldl(fun(Root, Seen) -> dfs(Root, ?DEPTH, Seen) end, #{}, roots(Name)).

dfs(World, Depth, Seen) ->
    Key = key(World),
    case Seen of
        #{Key := Reached} when Reached >= Depth ->
            Seen;
        #{} ->
            live(World),
            Next = case Depth of
                       0 -> [];
                       _ -> [Successor || Event <- enabled(World), Successor <- successors(World, Event)]
                   end,
            lists:foldl(fun(Successor, Acc) -> dfs(Successor, Depth - 1, Acc) end, Seen#{Key => Depth}, Next)
    end.

key(#{join := Join} = World) ->
    maps:without([trace], World#{join := maps:remove(counts, Join)}).

%% The pick, the association and an open port, each reached by genuine events.
roots(open) ->
    [joined(open)];
roots(Name) ->
    Joined = joined(Name),
    Associated = case Name of
                     sae -> play(Joined, [auth_request, {peer, <<"commit">>}, {peer, <<"accept">>}, connect_ok]);
                     _ -> play(Joined, [connect_ok])
                 end,
    Open = play(Associated, [ap_msg1, deliver_up, ap_msg3, deliver_up, {confirm, 1}]),
    ?assertEqual(keys, erx_wifi_join:state(maps:get(join, Associated))),
    ?assertEqual(open, erx_wifi_join:state(maps:get(join, Open))),
    [Joined, Associated, Open].

config(psk) -> #{akm => psk, pmf => none};
config(psk_sha256_pmf) -> #{akm => psk_sha256, pmf => required};
config(sae) -> #{akm => sae, pmf => required};
config(open) -> #{akm => none, pmf => none}.

joined(Name) ->
    #{akm := Akm, pmf := Pmf} = config(Name),
    Ref = make_ref(),
    Bss = #{bssid => ?AA, ssid => ?SSID, signal => -40, security => open, h2e => true},
    %% The firmware's association request leaves out the RSNXE the station asked for,
    %% so message 2 must repeat what was sent, not what was asked.
    Own = #{rsn => own_rsn(Akm), rsnxe => case Akm of sae -> <<244, 1, 16#20>>; _ -> none end},
    World = #{akm => Akm, pmf => Pmf, ref => Ref, old => make_ref(), now => 0, join => erx_wifi_join:new(),
              ap => ap_new(Akm, Pmf), up => [], recorded => [], chip => chip_new(), trace => trace_new(),
              sent => #{rsn => own_rsn(Akm), rsnxe => none}},
    Request = #{candidate => #{bss => Bss, akm => Akm, pmf => Pmf}, address => ?SPA, own => Own,
                scan => #{rsn => ap_rsn(Akm), rsnxe => none}},
    [Joined | _] = step(World, {join, Ref, Request}, genuine),
    Joined.

%% The events a world offers: the access point's genuine messages, an attacker's
%% forged and replayed ones, the chip's confirmations and indications, the lifecycle's
%% leave, the deadline, and events of an ended join.
enabled(#{join := Join, ap := Ap, up := Up, recorded := Recorded, chip := Chip, akm := Akm}) ->
    State = erx_wifi_join:state(Join),
    Stale = [stale_confirm, stale_eapol, stale_deadline, stale_disconnected],
    Ends = [leave, disconnected],
    Air = [ap_msg1, forge_msg1]
        ++ [E || maps:get(cand, Ap) =/= none, E <- [ap_msg3, ap_msg3_other_rsn, ap_msg3_other_anonce, forge_mic]]
        ++ [E || maps:get(phase, Ap) =:= done, E <- [ap_rekey, ap_group]]
        ++ [{replay, Frame} || Frame <- lists:sublist(Recorded, ?REPLAYS)]
        ++ [E || Up =/= [], E <- [deliver_up, drop_up]],
    Chip0 = [{confirm, Id} || Id <- outstanding(Chip)] ++ [{refuse, Id} || Id <- lists:sublist(outstanding(Chip), 1)],
    Deadline = [E || erx_wifi_join:deadline(Join) =/= none, E <- [deadline, early_deadline]],
    case State of
        idle -> Stale;
        joining -> [connect_ok, connect_fail, auth_request, ap_msg1, wrong_confirm | Deadline ++ Ends ++ Stale];
        sae -> [{peer, <<"commit">>}, {peer, <<"accept">>}, {peer, <<"fail">>}, auth_tx, connect_ok | Deadline ++ Ends];
        _ when Akm =:= none -> [ap_msg1, later_disconnected | Ends ++ Stale];
        open -> Air ++ Chip0 ++ [later_disconnected | Ends ++ Stale];
        _ -> Air ++ Chip0 ++ Deadline ++ Ends
    end.

%% ---- One event ----

%% The worlds an event leads to: one, or two when the machine asks the key holder,
%% which answers before any other event, genuinely or `unavailable`.
successors(World, Event) ->
    case prepare(Event, World) of
        {none, Prepared, _Class} -> [Prepared];
        {Machine, Prepared, Class} -> step(Prepared, Machine, Class)
    end.

play(World, Events) ->
    lists:foldl(fun(Event, Acc) -> hd(successors(Acc, Event)) end, World, Events).

prepare(connect_ok, #{ref := Ref, sent := Sent} = W) -> {{connect_confirm, Ref, {ok, Sent}}, W, genuine};
prepare(connect_fail, #{ref := Ref} = W) -> {{connect_confirm, Ref, {failed, 1}}, W, genuine};
prepare(auth_request, #{ref := Ref} = W) -> {{auth_request, Ref}, W, genuine};
prepare({peer, Frame}, #{ref := Ref} = W) -> {{auth_frame, Ref, Frame}, sae_trace(Frame, W), genuine};
prepare(auth_tx, #{ref := Ref} = W) -> {{auth_tx, Ref, ok}, W, genuine};
prepare(wrong_confirm, #{ref := Ref} = W) -> {{set_keys_confirm, Ref, 1, ok}, W, genuine};
prepare(leave, W) -> {leave, cause(leave, W), genuine};
prepare(disconnected, #{ref := Ref} = W) -> {{disconnected, Ref, ap, 3}, W, genuine};
prepare(later_disconnected, #{ref := Ref, now := Now} = W) ->
    {{disconnected, Ref, ap, 3}, W#{now := Now + ?SHORT_LINK_MS + 1}, genuine};
prepare(early_deadline, #{ref := Ref, join := Join, now := Now} = W) ->
    {{deadline, Ref}, W#{now := max(Now, erx_wifi_join:deadline(Join) - 1)}, genuine};
prepare(deadline, #{ref := Ref, join := Join, now := Now} = W) ->
    {{deadline, Ref}, W#{now := max(Now, erx_wifi_join:deadline(Join))}, genuine};
prepare({confirm, Id}, #{ref := Ref} = W) -> {{set_keys_confirm, Ref, Id, ok}, chip_confirm(Id, W), genuine};
prepare({refuse, Id}, #{ref := Ref} = W) -> {{set_keys_confirm, Ref, Id, refused}, W, genuine};
prepare(stale_confirm, #{old := Old} = W) -> {{set_keys_confirm, Old, 1, ok}, W, stale};
prepare(stale_eapol, #{old := Old, ap := Ap} = W) -> {{eapol, Old, message_1(Ap, 1)}, W, stale};
prepare(stale_deadline, #{old := Old} = W) -> {{deadline, Old}, W, stale};
prepare(stale_disconnected, #{old := Old} = W) -> {{disconnected, Old, ap, 3}, W, stale};
prepare(deliver_up, #{up := [Frame | Rest]} = W) -> {none, ap_receive(Frame, W#{up := Rest}), genuine};
prepare(drop_up, #{up := [_ | Rest]} = W) -> {none, W#{up := Rest}, genuine};
prepare({replay, Frame}, #{ref := Ref} = W) -> {{eapol, Ref, Frame}, W, replay};
prepare(Air, #{ref := Ref} = W) ->
    {Frame, Sent, Class} = air(Air, W),
    {{eapol, Ref, Frame}, record(Frame, Sent), Class}.

%% The access point's messages, genuine or bent, and an attacker's forgeries.
air(ap_msg1, #{ap := Ap} = W) ->
    Next = bump(Ap),
    {message_1(Next, maps:get(counter, Next)), W#{ap := Next#{phase := sent1}}, genuine};
air(ap_rekey, #{ap := Ap} = W) ->
    Next = bump(Ap),
    Fresh = Next#{anonce := crypto:hash(sha256, <<"anonce", (maps:get(counter, Next)):64>>), cand := none,
                  phase := sent1},
    {message_1(Fresh, maps:get(counter, Fresh)), W#{ap := Fresh}, genuine};
air(ap_msg3, #{ap := Ap} = W) ->
    Next = bump(Ap),
    {message_3(Next, #{}), W#{ap := Next#{phase := sent3}}, genuine};
air(ap_msg3_other_rsn, #{ap := Ap, akm := Akm} = W) ->
    Next = bump(Ap),
    {message_3(Next, #{rsn => other_rsn(Akm)}), W#{ap := Next}, forged};
air(ap_msg3_other_anonce, #{ap := Ap} = W) ->
    Next = bump(Ap),
    {message_3(Next, #{anonce => <<1:256>>}), W#{ap := Next}, forged};
air(forge_mic, #{ap := Ap} = W) ->
    <<Head:(?ERX_EAPOL_KEY_OFF_MIC)/binary, M, Tail/binary>> = message_3(bump(Ap), #{}),
    {<<Head/binary, (M bxor 1), Tail/binary>>, W, forged};
air(forge_msg1, #{ap := Ap} = W) ->
    {message_1(Ap#{anonce := <<7:256>>}, maps:get(counter, Ap) + 1000), W, forged};
air(ap_group, #{ap := #{gtk := {Id, _}, igtk := {IgtkId, _}, generation := Gen} = Ap, pmf := Pmf} = W) ->
    Gtk = {1 - Id, key(gtk, Gen + 1)},
    Igtk = {9 - IgtkId, key(igtk, Gen + 1)},
    Issued0 = issue(maps:get(issued, Ap), {gtk, element(1, Gtk)}, element(2, Gtk)),
    Issued = case Pmf of none -> Issued0; _ -> issue(Issued0, {igtk, element(1, Igtk)}, element(2, Igtk)) end,
    Next = (bump(Ap))#{gtk := Gtk, igtk := Igtk, generation := Gen + 1, issued := Issued},
    {group_1(Next), W#{ap := Next}, genuine}.

record(Frame, #{recorded := Recorded} = W) -> W#{recorded := [Frame | Recorded]}.

bump(#{counter := Counter} = Ap) -> Ap#{counter := Counter + 1}.

%% One machine step, checked: an event that does not apply changes nothing; a forged
%% or replayed frame, or an event of another join, installs nothing; a message 1
%% never moves the watermark; every edge taken is recorded.
step(#{join := Join, now := Now} = World, Event, Class) ->
    Ctx = #{now => Now, random => crypto:hash(sha256, term_to_binary(key(World)))},
    {Actions, Joined} = erx_wifi_join:step(Join, Event, Ctx),
    Dropped = maps:get(counts, Joined) =/= maps:get(counts, Join),
    case refusal(Event, Join) of
        none when not Dropped ->
            Edge = {kind(Event), erx_wifi_join:state(Join), erx_wifi_join:state(Joined)},
            put(edges, (get(edges))#{Edge => true});
        none ->
            ?assertEqual({[], maps:remove(counts, Join)}, {Actions, maps:remove(counts, Joined)});
        Counted ->
            #{counts := Counts} = Join,
            ?assertEqual({[], Join#{counts := maps:update_with(Counted, fun(N) -> N + 1 end, 1, Counts)}},
                         {Actions, Joined})
    end,
    Installs = [Keys || {chip, {set_keys, _, _, Keys}} <- Actions],
    (Class =:= forged orelse Class =:= stale) andalso ?assertEqual({Class, []}, {Class, Installs}),
    due(Event, Join, Now) andalso ?assertNot(Dropped),
    is_message_1(Event) andalso
        ?assertEqual(maps:get(watermark, Join, none), maps:get(watermark, Joined, none)),
    Done = check_world(effects((proof(Event, World))#{join := Joined}, Event, Actions)),

    case [Request || {keys, _, Request} <- Actions] of
        [] -> [Done];
        [Request] ->
            #{ref := Ref} = Done,
            step(Done, {key, Ref, holder(Done, Request)}, holder)
                ++ step(cause(unavailable, Done), {key, Ref, {error, unavailable}}, holder)
    end.

kind(leave) -> leave;
kind(Event) -> element(1, Event).

%% Whether the machine must refuse an event before any handler, and the count that
%% refusal makes: another join's reference first, then a cell the table leaves empty.
refusal(Event, Join) ->
    {_, Cells} = maps:get(kind(Event), erx_wifi_join:table()),
    Ours = case Event of
               {join, _, _} -> true;
               leave -> true;
               _ -> element(2, Event) =:= maps:get(ref, Join)
           end,
    case {Ours, maps:is_key(erx_wifi_join:state(Join), Cells)} of
        {false, _} -> stale;
        {true, false} -> unexpected_event;
        {true, true} -> none
    end.

is_message_1({eapol, _, Frame}) ->
    case erx_wpa_key:decode(Frame) of
        {ok, #{pairwise := true, mic_present := false}} -> true;
        _ -> false
    end;
is_message_1(_) -> false.

%% Every state in which a handshake waits has a deadline at most the longest wait away.
check_world(#{join := Join, now := Now} = World) ->
    case erx_wifi_join:state(Join) of
        State when State =:= idle; State =:= open -> ok;
        _ ->
            Deadline = erx_wifi_join:deadline(Join),
            ?assert(is_integer(Deadline) andalso Deadline - Now =< 10_000)
    end,
    World.

holder(#{akm := Akm}, {ptk, #{ssid := ?SSID, akm := Akm, aa := ?AA, spa := ?SPA, anonce := ANonce, snonce := SNonce}}) ->
    {ok, erx_wpa_kdf:ptk(suite(Akm), pmk(), ?AA, ?SPA, ANonce, SNonce)};
holder(_World, {sae_commit, fake}) ->
    {ok, fake}.

cause(Cause, #{trace := Trace} = W) -> W#{trace := Trace#{cause := Cause}}.

sae_trace(Frame, #{join := Join, trace := Trace} = W) ->
    case {erx_wifi_join:state(Join), Frame, maps:get(sae_accepted, Trace)} of
        {sae, _, true} -> W;
        {sae, <<"accept">>, false} -> W#{trace := Trace#{sae_accepted := true}};
        {sae, <<"fail">>, false} -> W;
        {sae, _, false} -> W#{trace := Trace#{sae_tested := true}};
        _ -> W
    end.

%% ---- What the actions do ----

effects(World, Event, Actions) ->
    lists:foldl(fun(Action, Acc) -> effect(Action, Event, Acc) end, World, Actions).

effect({chip, {eapol, _, Frame}}, _Event, #{up := Up, trace := Trace} = W) ->
    {ok, #{pairwise := Pairwise, nonce := Nonce}} = erx_wpa_key:decode(Frame),
    Kind = case {Pairwise, Nonce} of
               {false, _} -> group_2;
               {true, <<0:256>>} -> message_4;
               {true, _} -> message_2
           end,
    Counted = maps:update_with(Kind, fun(N) -> N + 1 end, Trace),
    W#{up := Up ++ [Frame], trace := case Kind of message_2 -> Counted#{snonce := Nonce}; _ -> Counted end};
effect({chip, {set_keys, _, Id, Keys}}, _Event, W) ->
    chip_install(Id, Keys, W);
effect({chip, {port, _, open}}, _Event, #{chip := Chip, pmf := Pmf, akm := Akm, now := Now, trace := Trace} = W) ->
    Akm =:= none orelse port_keys(Chip, Pmf),
    W#{trace := Trace#{opened := Now}};
effect({chip, {delete_keys, _}}, _Event, W) ->
    W#{chip := chip_new()};
effect({ended, Class, Reason}, _Event, #{trace := Trace, now := Now, akm := Akm, pmf := Pmf} = W) ->
    ?assertEqual({Reason, expected_class(Trace, Now)}, {Reason, Class}),
    W#{trace := trace_new(), ap := ap_new(Akm, Pmf), up := []};
effect(_Other, _Event, W) ->
    W.

%% "How a join ends", restated from what the station did rather than from its state.
expected_class(#{cause := Cause}, _Now) when Cause =:= leave; Cause =:= unavailable -> none;
expected_class(#{opened := Opened}, Now) when Opened =/= none ->
    case Now - Opened < ?SHORT_LINK_MS of true -> bss; false -> none end;
expected_class(#{sae_accepted := true}, _Now) -> bss;
expected_class(#{sae_tested := true}, _Now) -> secret;
expected_class(#{message_2 := Sent, proved := false}, _Now) when Sent > 0 -> secret;
expected_class(#{}, _Now) -> bss.

trace_new() ->
    #{cause => none, opened => none, sae_tested => false, sae_accepted => false, message_2 => 0,
      message_4 => 0, group_2 => 0, snonce => none, proved => false}.

%% A due deadline in a state that waits is never dropped: every wait ends.
due({deadline, Ref}, #{ref := Ref} = Join, Now) ->
    lists:member(erx_wifi_join:state(Join), [joining, sae, keys, rekey]) andalso
        Now >= erx_wifi_join:deadline(Join);
due(_Event, _Join, _Now) ->
    false.

%% The access point proved the secret when the station takes a message 3 whose MIC
%% verifies under the PTK of the station's last message 2 and the frame's ANonce.
proof({eapol, Ref, Frame}, #{ref := Ref, akm := Akm, trace := #{snonce := SNonce} = Trace} = W)
  when SNonce =/= none ->
    case erx_wpa_key:decode(Frame) of
        {ok, #{pairwise := true, ack := true, mic_present := true, nonce := ANonce, mic := Mic} = Key} ->
            #{kck := Kck} = erx_wpa_kdf:ptk(suite(Akm), pmk(), ?AA, ?SPA, ANonce, SNonce),
            case erx_wpa_kdf:check_mic(suite(Akm), Kck, erx_wpa_key:mic_input(Key), Mic) of
                true -> W#{trace := Trace#{proved := true}};
                false -> W
            end;
        _ -> W
    end;
proof(_Event, W) ->
    W.

%% ---- The fake chip: what each slot holds and has held, and which installs are confirmed ----

chip_new() -> #{slots => #{}, held => #{}, installs => [], confirmed => []}.

%% WF9: no install of the key a slot holds, or of one it held before; and each key in
%% the slot the access point issued it for, the pairwise key in its own slot and the
%% GTK of key id N in GTK slot N, 0 included.
chip_install(Id, Keys, #{chip := #{slots := Slots, held := Held, installs := Installs} = Chip, ap := Ap} = W) ->
    Next = lists:foldl(
             fun(#{slot := Slot, key := Key}, {S, H}) ->
                     Before = maps:get(Slot, H, []),
                     Current = case S of #{Slot := {K, _}} -> [K]; #{} -> [] end,
                     ?assertEqual({reinstall, Slot, false}, {reinstall, Slot, lists:member(Key, Current ++ Before)}),
                     ?assertEqual({issued_for, Slot}, {issued_for, maps:get(Key, maps:get(issued, Ap), none)}),
                     {S#{Slot => {Key, Id}}, H#{Slot => Current ++ Before}}
             end, {Slots, Held}, Keys),
    {Filled, History} = Next,
    W#{chip := Chip#{slots := Filled, held := History, installs := Installs ++ [Id]}}.

chip_confirm(Id, #{chip := #{confirmed := Confirmed} = Chip} = W) ->
    W#{chip := Chip#{confirmed := [Id | Confirmed]}}.

outstanding(#{installs := Installs, confirmed := Confirmed}) -> Installs -- Confirmed.

%% WF4: the port opens only with every key in the chip confirmed, the pairwise key and
%% a GTK among them, and an IGTK under PMF.
port_keys(#{slots := Slots, confirmed := Confirmed}, Pmf) ->
    ?assertEqual([], [Slot || Slot := {_, Id} <- Slots, not lists:member(Id, Confirmed)]),
    ?assert(maps:is_key(pairwise, Slots)),
    ?assert(lists:any(fun({gtk, _}) -> true; (_) -> false end, maps:keys(Slots))),
    Pmf =:= none orelse ?assert(lists:any(fun({igtk, _}) -> true; (_) -> false end, maps:keys(Slots))).

%% ---- The fake access point ----

ap_new(Akm, Pmf) ->
    Gtk = {0, key(gtk, 0)},
    Igtk = {4, key(igtk, 0)},
    Issued = issue(issue(#{}, {gtk, 0}, element(2, Gtk)), {igtk, 4}, element(2, Igtk)),
    #{akm => Akm, pmf => Pmf, counter => 0, anonce => crypto:hash(sha256, <<"anonce">>), phase => idle,
      cand => none, ptk => none, gtk => Gtk, igtk => Igtk, generation => 0, issued => Issued}.

issue(Issued, Slot, Key) -> Issued#{Key => Slot}.

key(Kind, Generation) -> binary:part(crypto:hash(sha256, term_to_binary({Kind, Generation})), 0, 16).

%% What the access point does with the station's frames: a message 2 under a valid MIC
%% gives it the PTK it will use, and must repeat the elements the association request
%% carried; a message 4 under that PTK completes the handshake.
ap_receive(Frame, #{ap := #{akm := Akm, anonce := ANonce, cand := Cand} = Ap, sent := Sent} = W) ->
    {ok, #{pairwise := Pairwise, nonce := Nonce, mic := Mic, data := Data} = Key} = erx_wpa_key:decode(Frame),
    Input = erx_wpa_key:mic_input(Key),
    case {Pairwise, Nonce} of
        {true, <<0:256>>} when Cand =/= none ->
            case erx_wpa_kdf:check_mic(suite(Akm), maps:get(kck, Cand), Input, Mic) of
                true -> W#{ap := Ap#{phase := done, ptk := Cand}};
                false -> W
            end;
        {true, SNonce} when SNonce =/= <<0:256>> ->
            Ptk = erx_wpa_kdf:ptk(suite(Akm), pmk(), ?AA, ?SPA, ANonce, SNonce),
            case erx_wpa_kdf:check_mic(suite(Akm), maps:get(kck, Ptk), Input, Mic) of
                true ->
                    ?assertEqual(elements(Sent), Data),
                    W#{ap := Ap#{cand := Ptk, phase := got2,
                                 issued := issue(maps:get(issued, Ap), pairwise, maps:get(tk, Ptk))}};
                false -> W
            end;
        _ -> W
    end.

elements(#{rsn := Rsn, rsnxe := none}) -> Rsn;
elements(#{rsn := Rsn, rsnxe := Rsnxe}) -> <<Rsn/binary, Rsnxe/binary>>.

message_1(#{akm := Akm, anonce := ANonce}, Counter) ->
    frame(Akm, ?ERX_WPA_KEY_INFO_PAIRWISE bor ?ERX_WPA_KEY_INFO_ACK, Counter, ANonce, 0, <<>>, none).

message_3(#{akm := Akm, anonce := ANonce, counter := Counter, cand := #{kck := Kck, kek := Kek},
            gtk := Gtk, igtk := Igtk, pmf := Pmf}, Bent) ->
    Rsn = maps:get(rsn, Bent, ap_rsn(Akm)),
    Plain = <<Rsn/binary, (group_kdes(Gtk, Igtk, Pmf))/binary>>,
    Info = ?ERX_WPA_KEY_INFO_PAIRWISE bor ?ERX_WPA_KEY_INFO_ACK bor ?ERX_WPA_KEY_INFO_MIC bor
        ?ERX_WPA_KEY_INFO_INSTALL bor ?ERX_WPA_KEY_INFO_SECURE bor ?ERX_WPA_KEY_INFO_ENCRYPTED,
    frame(Akm, Info, Counter, maps:get(anonce, Bent, ANonce), 5, wrap(Kek, pad(Plain)), Kck).

group_1(#{akm := Akm, counter := Counter, ptk := #{kck := Kck, kek := Kek}, gtk := Gtk, igtk := Igtk, pmf := Pmf}) ->
    Info = ?ERX_WPA_KEY_INFO_ACK bor ?ERX_WPA_KEY_INFO_MIC bor ?ERX_WPA_KEY_INFO_SECURE bor
        ?ERX_WPA_KEY_INFO_ENCRYPTED,
    frame(Akm, Info, Counter, <<0:256>>, 9, wrap(Kek, pad(group_kdes(Gtk, Igtk, Pmf))), Kck).

group_kdes({GtkId, Gtk}, {IgtkId, Igtk}, Pmf) ->
    GtkKde = <<16#dd, 22, ?ERX_WPA_KDE_OUI:24, ?ERX_WPA_KDE_TYPE_GTK, (GtkId bor ?ERX_WPA_GTK_KDE_TX), 0, Gtk/binary>>,
    case Pmf of
        none -> GtkKde;
        _ -> <<GtkKde/binary, 16#dd, 28, ?ERX_WPA_KDE_OUI:24, ?ERX_WPA_KDE_TYPE_IGTK, IgtkId:16/little, 3:48/little,
               Igtk/binary>>
    end.

frame(Akm, Bits, Counter, Nonce, Rsc, Data, Kck) ->
    Info = Bits bor erx_abi_translations:wpa_akm_key_version(suite(Akm)),
    Encode = fun(Mic) ->
                     Fixed = erx_abi_packed:encode(
                               erx_eapol_key,
                               #{version => ?ERX_EAPOL_VERSION, type => ?ERX_EAPOL_TYPE_KEY,
                                 body_length => ?ERX_EAPOL_KEY_SIZE - ?ERX_EAPOL_KEY_OFF_DESCRIPTOR + byte_size(Data),
                                 descriptor => ?ERX_EAPOL_KEY_DESCRIPTOR_RSN, key_info => Info, key_length => 16,
                                 replay_counter => Counter, nonce => Nonce, iv => <<0:128>>, rsc => <<Rsc:64/little>>,
                                 reserved => <<0:64>>, mic => Mic, data_length => byte_size(Data)}),
                     <<Fixed/binary, Data/binary>>
             end,
    Unsigned = Encode(<<0:128>>),
    case Kck of
        none -> Unsigned;
        _ -> Encode(erx_wpa_kdf:mic(suite(Akm), Kck, Unsigned))
    end.

%% Encrypted key data is padded with 0xdd and zeros to a multiple of 8 bytes, at least
%% 16, then wrapped with AES key wrap (RFC 3394, section 2.2.1).
pad(Plain) ->
    Size = max(16, (byte_size(Plain) + 1 + 7) div 8 * 8),
    case byte_size(Plain) rem 8 =:= 0 andalso byte_size(Plain) >= 16 of
        true -> Plain;
        false -> <<Plain/binary, 16#dd, 0:((Size - byte_size(Plain) - 1) * 8)>>
    end.

wrap(Kek, Plain) ->
    R0 = [Block || <<Block:8/binary>> <= Plain],
    N = length(R0),
    {A, R} = lists:foldl(
               fun(J, {A0, Rs}) ->
                       {A1, Reversed} = lists:foldl(
                                          fun({I, Block}, {Ai, Acc}) ->
                                                  <<Msb:64, Lsb:8/binary>> =
                                                      crypto:crypto_one_time(aes_128_ecb, Kek, <<Ai:64, Block/binary>>, true),
                                                  {Msb bxor (N * J + I), [Lsb | Acc]}
                                          end, {A0, []}, lists:zip(lists:seq(1, N), Rs)),
                       {A1, lists:reverse(Reversed)}
               end, {?ERX_AES_WRAP_IV, R0}, lists:seq(0, 5)),
    iolist_to_binary([<<A:64>> | R]).

pmk() ->
    case persistent_term:get({?MODULE, pmk}, none) of
        none ->
            Pmk = erx_wpa_kdf:pmk(<<"correct horse">>, ?SSID),
            persistent_term:put({?MODULE, pmk}, Pmk),
            Pmk;
        Pmk -> Pmk
    end.

suite(none) -> suite(psk);
suite(Akm) ->
    {Akm, Suite} = lists:keyfind(Akm, 1, ?ERX_IEEE80211_AKM_MEMBERS),
    Suite.

%% The access point's RSN element as its beacon and message 3 carry it, the station's
%% own, and a weaker one a forged beacon could have shown.
ap_rsn(none) -> none;
ap_rsn(Akm) -> rsn(Akm, 16#c0).
own_rsn(none) -> none;
own_rsn(Akm) -> rsn(Akm, 16#80).
other_rsn(Akm) -> rsn(Akm, 16#00).

rsn(Akm, Caps) ->
    <<48, 20, 1:16/little, 0, 16#0f, 16#ac, 4, 1:16/little, 0, 16#0f, 16#ac, 4, 1:16/little,
      0, 16#0f, 16#ac, (suite(Akm)), Caps, 0>>.

%% ---- Liveness ----

%% From any world with an association, the access point's genuine messages complete a
%% handshake, whatever came before, once it starts one; from an open port a genuine
%% PTK rekey installs its new key and a genuine group rekey its new GTK.
live(#{join := Join, akm := Akm} = World) when Akm =/= none ->
    case erx_wifi_join:state(Join) of
        State when State =:= keys; State =:= rekey -> handshake(World);
        open -> group_rekey(handshake(World));
        _ -> ok
    end;
live(_World) ->
    ok.

handshake(#{ap := #{phase := Phase}} = World) ->
    Start = case Phase of done -> ap_rekey; _ -> ap_msg1 end,
    Done = confirm_all(play(World#{up := []}, [Start, deliver_up, ap_msg3, deliver_up])),
    #{join := Join, chip := #{slots := Slots}, ap := #{ptk := #{tk := Tk}}} = Done,
    ?assertEqual({open, Tk}, {erx_wifi_join:state(Join), element(1, maps:get(pairwise, Slots))}),
    Done.

group_rekey(World) ->
    Done = confirm_all(play(World, [ap_group])),
    #{chip := #{slots := Slots}, ap := #{gtk := {Id, Gtk}}} = Done,
    ?assertEqual(Gtk, element(1, maps:get({gtk, Id}, Slots))).

confirm_all(#{chip := Chip} = World) ->
    play(World, [{confirm, Id} || Id <- outstanding(Chip)]).

%% ---- The design's scenarios ----

open_world(Name) -> lists:last(roots(Name)).
keys_world(Name) -> lists:nth(2, roots(Name)).

%% Message 3 delivered, message 4 dropped, and message 3 sent again once before the
%% chip confirms the install and once after: message 4 answers each, each key is
%% installed once, and the port opens.
krack_retransmissions_install_once_test() ->
    put(edges, #{}),
    W0 = play(keys_world(psk), [ap_msg1, deliver_up, ap_msg3, drop_up, ap_msg3, drop_up, {confirm, 1}, ap_msg3]),
    #{join := Join, trace := #{message_4 := Fours}, chip := #{installs := Installs}} = W0,
    ?assertEqual({open, 3, [1]}, {erx_wifi_join:state(Join), Fours, Installs}).

%% A handshake started again before the first install is confirmed: the first
%% install's confirmation does not confirm the second's key, so the port waits for it.
newer_install_waits_for_its_own_confirmation_test() ->
    put(edges, #{}),
    W0 = play(keys_world(psk), [ap_msg1, deliver_up, ap_msg3, drop_up, ap_msg1, deliver_up, ap_msg3, drop_up]),
    ?assertEqual([1, 2], maps:get(installs, maps:get(chip, W0))),
    W1 = play(W0, [{confirm, 1}]),
    ?assertEqual(keys, erx_wifi_join:state(maps:get(join, W1))),
    W2 = play(W1, [{confirm, 2}]),
    ?assertEqual(open, erx_wifi_join:state(maps:get(join, W2))).

%% A -> B -> A: group rekeys that move GTK slot 1 from B to D, then the recorded group
%% message of B replayed, and the recorded message 3 of the first GTK replayed after
%% slot 0 moved on: nothing is installed again (WF9).
replayed_group_and_message_3_install_nothing_test() ->
    put(edges, #{}),
    Open = open_world(psk_sha256_pmf),
    Message3 = hd(maps:get(recorded, Open)),
    B = confirm_all(play(Open, [ap_group])),
    GroupB = hd(maps:get(recorded, B)),
    D = confirm_all(play(B, [ap_group, ap_group])),
    Replayed = play(D, [{replay, GroupB}, {replay, Message3}]),
    ?assertEqual(maps:get(chip, D), maps:get(chip, Replayed)),
    ?assertEqual(open, erx_wifi_join:state(maps:get(join, Replayed))).

%% A forged message 1 with a large counter moves nothing the access point's own
%% messages need, and a forged message 1 in `open` starts a rekey its deadline ends,
%% back in `open` under the same keys.
forged_message_1_spoils_nothing_test() ->
    put(edges, #{}),
    %% One forged after message 3 and before the chip's confirmation: the access point
    %% sends nothing more, and the confirmation alone opens the port.
    Late = play(keys_world(psk), [ap_msg1, deliver_up, ap_msg3, deliver_up, forge_msg1, {confirm, 1}]),
    ?assertEqual(open, erx_wifi_join:state(maps:get(join, Late))),
    Keys = handshake(play(keys_world(psk), [forge_msg1, forge_msg1])),
    ?assertEqual(open, erx_wifi_join:state(maps:get(join, Keys))),
    Open = open_world(psk),
    Rekey = play(Open, [forge_msg1]),
    ?assertEqual(rekey, erx_wifi_join:state(maps:get(join, Rekey))),
    Back = play(Rekey, [deadline]),
    ?assertEqual({open, maps:get(chip, Open)}, {erx_wifi_join:state(maps:get(join, Back)), maps:get(chip, Back)}).

%% WF5: the machine derives no PTK and no PMK.
no_key_is_derived_by_the_machine_test() ->
    {ok, {_, [{imports, Imports}]}} = beam_lib:chunks(code:which(erx_wifi_join), [imports]),
    ?assertEqual([], [Import || {erx_wpa_kdf, F, _} = Import <- Imports, F =/= mic, F =/= check_mic, F =/= unwrap]),
    ?assertEqual([], [Import || {crypto, _, _} = Import <- Imports]).

