%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_wifi_join).

-moduledoc """
The join machine (docs/design-wifi.md, "Joining", "The supplicant"): one join, from
the lifecycle's pick to an open port and until the link ends. step/3 is a pure
function of the join, one event and a context of the time and 32 random bytes; it
returns the actions for the station's process to perform and the next join.

table/0 is the one statement of the machine's edges. step/3 checks the event's join
reference first, then looks up the event's cell for the current state: an empty cell
drops the event, counted `unexpected_event`; a filled cell names the handler and the
states it may leave the machine in, and a handler that returns any other state is a
bug that ends the station. A handler that refuses its event returns `{drop, Check}`,
counted by the check, and changes nothing else; SAE's drops, below, are counted the
same way but keep the exchange erx_sae returns.

The supplicant's state lives here: the replay watermark, the pending PTK and the key
slots ("The key slots"). A set_keys request holds only the keys that differ from
their slot's, each install has an id, and a confirmation confirms only the slots its
install last filled, so no frame an attacker can send reinstalls a key (WF9). The
machine derives no key: each PTK is a request to the key holder through
erx_wifi_keys, whose answer the next step receives. SAE's exchange is erx_sae's; its
drops are counted as a handler's, with the exchange erx_sae returns kept, which is
unchanged except after the holder's `bad_element`, which returns it to before the commit.

Every frame here came from the air through the chip and is hostile: it is decoded by
erx_wpa_key and accepted only after the checks of "The 4-way handshake" and "The
group key handshake", in their order.
""".

-include("generated/erx_abi.hrl").

-export([new/0, table/0, step/3, state/1, deadline/1]).
-export_type([join/0, event/0, action/0, ctx/0]).

%% erXos's deadlines, in milliseconds ("Joining", "Deadlines"), and the time a port
%% must stay open for its end not to count against the BSS ("How a join ends").
-define(CONNECT_MS, 10_000).
-define(FIRST_MESSAGE_MS, 10_000).
-define(NEXT_MESSAGE_MS, 5_000).
-define(SHORT_LINK_MS, 10_000).

-type state() :: idle | joining | sae | keys | open | rekey.
-type kind() :: join | leave | connect_confirm | auth_request | auth_frame | auth_tx | key | eapol
              | set_keys_confirm | disconnected | deadline.
-type elements() :: #{rsn := binary() | none, rsnxe := binary() | none}.
-type slot() :: pairwise | {gtk, 0..3} | {igtk, 4..5}.
-type held() :: #{key := <<_:128>>, id := non_neg_integer(), confirmed := boolean()}.
-type ctx() :: #{now := integer(), random := <<_:256>>}.
-type request() :: #{candidate := erx_wifi_choose:candidate(), address := <<_:48>>,
                     own := elements(), scan := elements()}.
-type event() :: {join, reference(), request()} | leave
               | {connect_confirm, reference(), {ok, elements()} | {failed, term()}}
               | {auth_request, reference()} | {auth_frame, reference(), binary()}
               | {auth_tx, reference(), ok | failed} | {key, reference(), term()}
               | {eapol, reference(), binary()} | {set_keys_confirm, reference(), non_neg_integer(), ok | refused}
               | {disconnected, reference(), term(), term()} | {deadline, reference()}.
-type install() :: #{slot := slot(), key := <<_:128>>, rsc := non_neg_integer()}.
-type action() :: {chip, tuple()} | {keys, reference(), erx_wifi_keys:request()}
                | {ended, erx_wifi_memory:class(), term()}.
%% `idle` carries only its counts. A join adds the association's fields: the BSS and
%% the join's AKM and PMF, the station's elements (`own`), the scan's for the BSS
%% (`scan`) and the association request's (`sent`); the supplicant's watermark,
%% pending PTK (`pending`), the PTK whose keys are installed (`ptk`), the slots, the
%% next install id and the slots the last message 3 named (`need`); the PTK request
%% awaiting the holder (`asked`), SAE's exchange, what the station has given away of
%% the secret (`proof`), when the port opened, and whether the chip reported the
%% link's end.
-type join() :: #{state := state(), ref := reference() | none, counts := #{atom() => pos_integer()},
                  _ => _}.

-doc "A machine with no join.".
-spec new() -> join().
new() ->
    #{state => idle, ref => none, counts => #{}}.

-doc "The machine's state.".
-spec state(join()) -> state().
state(#{state := State}) -> State.

-doc "The time by which the awaited event must come, or none when nothing is awaited.".
-spec deadline(join()) -> integer() | none.
deadline(#{deadline := Deadline}) -> Deadline;
deadline(#{}) -> none.

-doc """
For each kind of event, its handler and, for each state where it applies, the states
the handler may leave the machine in ("Joining", the transition table).
""".
-spec table() -> #{kind() => {fun((state(), event(), join(), ctx()) -> term()), #{state() => [state()]}}}.
table() ->
    Ends = #{joining => [idle], sae => [idle], keys => [idle], open => [idle], rekey => [idle]},
    #{join => {fun join/4, #{idle => [joining]}},
      leave => {fun leave/4, Ends},
      connect_confirm => {fun connect_confirm/4, #{joining => [keys, open, idle], sae => [keys, idle]}},
      auth_request => {fun auth_request/4, #{joining => [sae, idle]}},
      auth_frame => {fun sae_event/4, #{sae => [sae, idle]}},
      auth_tx => {fun sae_event/4, #{sae => [sae]}},
      key => {fun key/4, #{sae => [sae, idle], keys => [keys, idle], rekey => [rekey, idle]}},
      eapol => {fun eapol/4, #{keys => [keys, idle], open => [open, rekey, idle], rekey => [rekey, idle]}},
      set_keys_confirm => {fun set_keys_confirm/4,
                           #{keys => [keys, open, idle], open => [open, idle], rekey => [rekey, open, idle]}},
      disconnected => {fun disconnected/4, Ends},
      deadline => {fun due/4, #{joining => [idle], sae => [sae, idle], keys => [idle], rekey => [open]}}}.

-doc """
One event at the time and with the random bytes of Ctx: the next join, and the actions
to perform, in order.
""".
-spec step(join(), event(), ctx()) -> {join(), [action()]}.
step(#{state := State} = Join, Event, Ctx) ->
    Kind = kind(Event),
    {Handler, Cells} = maps:get(Kind, table()),
    case {belongs(Event, Join), maps:find(State, Cells)} of
        {false, _} ->
            {count(stale, Join), []};
        {true, error} ->
            {count(unexpected_event, Join), []};
        {true, {ok, Allowed}} ->
            case Handler(State, Event, Join, Ctx) of
                {drop, Check} ->
                    {count(Check, Join), []};
                {Actions, #{state := Next} = Joined} ->
                    lists:member(Next, Allowed) orelse erlang:error({outside_table, Kind, State, Next}),
                    {Joined, Actions}
            end
    end.

kind(leave) -> leave;
kind(Event) -> element(1, Event).

%% The lifecycle's `join` makes the reference and its `leave` names the current join;
%% every other event carries the reference of the join it belongs to.
belongs({join, _, _}, _Join) -> true;
belongs(leave, _Join) -> true;
belongs(Event, #{ref := Ref}) -> Ref =/= none andalso element(2, Event) =:= Ref.

count(Check, #{counts := Counts} = Join) ->
    Join#{counts := maps:update_with(Check, fun(N) -> N + 1 end, 1, Counts)}.

%% ---- The lifecycle's events and the chip's link ----

join(idle, {join, Ref, #{candidate := #{bss := #{bssid := Bssid, ssid := Ssid}, akm := Akm, pmf := Pmf},
                        address := Spa, own := Own, scan := Scan}}, Join, #{now := Now}) ->
    Elements = case Akm of
                   none -> #{rsn => none, rsnxe => none};
                   sae -> Own;
                   _ -> Own#{rsnxe := none}
               end,
    {[{chip, {connect, Ref, Bssid, Akm, Pmf, Elements}}],
     Join#{state := joining, ref := Ref, ssid => Ssid, bssid => Bssid, spa => Spa, akm => Akm, pmf => Pmf,
           own => Elements, scan => Scan, sent => none, deadline => Now + ?CONNECT_MS, opened => none,
           reported => false, proof => none, sae => none, asked => none, watermark => none,
           pending => none, ptk => none, slots => #{}, next_install => 1, need => []}}.

leave(_State, leave, Join, Ctx) ->
    finish(Join, none, left, Ctx).

disconnected(_State, {disconnected, _, By, Reason}, Join, Ctx) ->
    finish(Join#{reported := true}, {disconnected, By, Reason}, Ctx).

connect_confirm(_State, {connect_confirm, _, {failed, Status}}, Join, Ctx) ->
    finish(Join, {connect_failed, Status}, Ctx);
connect_confirm(joining, {connect_confirm, Ref, {ok, _Sent}}, #{akm := none} = Join, #{now := Now}) ->
    {[{chip, {port, Ref, open}}], Join#{state := open, opened := Now, deadline := none}};
connect_confirm(joining, {connect_confirm, _, {ok, _}}, #{akm := sae} = Join, Ctx) ->
    finish(Join, no_exchange, Ctx);
connect_confirm(sae, {connect_confirm, _, {ok, _}}, #{sae := Sae} = Join, Ctx) when Sae =/= accepted ->
    finish(Join, no_exchange, Ctx);
connect_confirm(_State, {connect_confirm, _, {ok, #{rsn := Rsn, rsnxe := Rsnxe} = Sent}}, #{own := #{rsn := Rsn}} = Join,
                #{now := Now}) when Rsnxe =:= none; is_binary(Rsnxe) ->
    {[], Join#{state := keys, sent := Sent, deadline := Now + ?FIRST_MESSAGE_MS}};
connect_confirm(_State, {connect_confirm, _, {ok, _}}, Join, Ctx) ->
    finish(Join, sent_rsn_differs, Ctx).

%% ---- SAE, through erx_sae ----

auth_request(joining, {auth_request, _}, #{akm := sae, ssid := Ssid, spa := Spa, bssid := Aa} = Join, Ctx) ->
    sae_step(Join#{state := sae, sae := erx_sae:new(#{ssid => Ssid, spa => Spa, aa => Aa})}, start, Ctx);
auth_request(joining, {auth_request, _}, Join, Ctx) ->
    finish(Join, unexpected_auth_request, Ctx).

sae_event(sae, {auth_frame, _, Frame}, Join, Ctx) -> sae_step(Join, {auth_frame, Frame}, Ctx);
sae_event(sae, {auth_tx, _, Status}, Join, Ctx) -> sae_step(Join, {auth_tx, Status}, Ctx).

%% Once the exchange is accepted, only the connect's confirmation is awaited.
sae_step(#{sae := accepted}, _Event, _Ctx) ->
    {drop, sae_done};
sae_step(#{sae := Sae0, ref := Ref, proof := Proof} = Join, Event, #{now := Now} = Ctx) ->
    {SaeActions, Sae, Outcome} = erx_sae:step(Sae0, Event, Ctx),
    Actions = [sae_action(Ref, Action) || Action <- SaeActions],
    Tested = case erx_sae:tested(Sae) of true -> tested; false -> Proof end,
    case Outcome of
        %% The exchange a drop returns is kept: unchanged, but after the holder's
        %% `bad_element`, which returns it to before the commit it dropped.
        {drop, Check} ->
            {[], count(Check, Join#{sae := Sae})};
        {running, Deadline} ->
            {Actions, Join#{sae := Sae, proof := Tested, deadline := Deadline}};
        accepted ->
            {Actions ++ [{chip, {auth_result, Ref, ok}}],
             Join#{sae := accepted, proof := proved, deadline := Now + ?CONNECT_MS}};
        {failed, Class} ->
            {Ended, Idle} = finish(Join#{sae := Sae}, Class, sae_failed, Ctx),
            {Actions ++ [{chip, {auth_result, Ref, failed}} | Ended], Idle}
    end.

sae_action(Ref, {auth_frame, Frame}) -> {chip, {auth_frame, Ref, Frame}};
sae_action(Ref, {keys, Request}) -> {keys, Ref, Request}.

%% ---- The key holder's answers ----

key(sae, {key, _, {error, unavailable}}, Join, Ctx) ->
    finish(Join, none, keys_unavailable, Ctx);
key(sae, {key, _, Answer}, Join, Ctx) ->
    sae_step(Join, {key, Answer}, Ctx);
key(_State, {key, _, _}, #{asked := none}, _Ctx) ->
    {drop, unasked_answer};
key(_State, {key, _, {error, unavailable}}, Join, Ctx) ->
    finish(Join, none, keys_unavailable, Ctx);
key(_State, {key, _, {ok, #{kck := <<_:128>>, kek := <<_:128>>, tk := <<_:128>>} = Ptk}},
    #{asked := #{anonce := ANonce, replay_counter := Counter, snonce := SNonce}} = Join, #{now := Now}) ->
    #{state := State, ref := Ref, akm := Akm, sent := #{rsn := Rsn, rsnxe := Rsnxe}, proof := Proof} = Join,
    Message2 = erx_wpa_key:build(message_2, suite(Akm), maps:get(kck, Ptk),
                                 #{replay_counter => Counter, snonce => SNonce, rsn => Rsn, rsnxe => Rsnxe,
                                   rekey => State =:= rekey}),
    {[{chip, {eapol, Ref, Message2}}],
     Join#{asked := none, pending := #{anonce => ANonce, snonce => SNonce, ptk => Ptk},
           proof := tested_unless_proved(Proof), deadline := Now + ?NEXT_MESSAGE_MS}};
key(_State, {key, _, {error, Why}}, Join, Ctx) when is_atom(Why) ->
    finish(Join, {keys_refused, Why}, Ctx);
key(_State, {key, _, _Malformed}, Join, Ctx) ->
    finish(Join, keys_malformed, Ctx).

tested_unless_proved(proved) -> proved;
tested_unless_proved(_) -> tested.

%% ---- EAPOL-Key frames ----

eapol(_State, {eapol, _, _}, #{akm := none}, _Ctx) ->
    {drop, not_protected};
eapol(State, {eapol, _, Frame}, #{akm := Akm, watermark := Watermark} = Join, Ctx) ->
    Version = erx_abi_translations:wpa_akm_key_version(suite(Akm)),
    case erx_wpa_key:decode(Frame) of
        {error, _} -> {drop, malformed};
        {ok, #{descriptor_version := V}} when V =/= Version -> {drop, descriptor_version};
        {ok, #{replay_counter := Counter} = Key} ->
            case above(Counter, Watermark) of
                false -> {drop, replayed};
                true -> message(message_kind(Key), State, Key, Join, Ctx)
            end
    end.

%% Every handshake message carries a counter above the watermark; while there is no
%% watermark, any counter is above it.
above(_Counter, none) -> true;
above(Counter, Watermark) -> Counter > Watermark.

message_kind(#{pairwise := true, ack := true, mic_present := false, install := false}) -> message_1;
message_kind(#{pairwise := true, ack := true, mic_present := true}) -> message_3;
message_kind(#{pairwise := false, ack := true, mic_present := true, secure := true}) -> group_1;
message_kind(#{}) -> unknown.

message(message_1, State, #{nonce := ANonce, replay_counter := Counter}, Join, #{now := Now, random := SNonce}) ->
    #{ref := Ref, ssid := Ssid, akm := Akm, bssid := Aa, spa := Spa} = Join,
    %% A rekey's own message 3 names the slots that end it.
    Begun = case State of open -> Join#{state := rekey, need := []}; _ -> Join end,
    {[{keys, Ref, erx_wifi_keys:ptk(Ssid, Akm, Aa, Spa, ANonce, SNonce)}],
     Begun#{asked := #{anonce => ANonce, replay_counter => Counter, snonce => SNonce},
            deadline := Now + ?NEXT_MESSAGE_MS}};
message(message_3, _State, _Key, #{pending := none}, _Ctx) ->
    {drop, no_pending};
message(message_3, _State, #{nonce := ANonce}, #{pending := #{anonce := Pending}}, _Ctx) when ANonce =/= Pending ->
    {drop, wrong_anonce};
message(message_3, State, Key, #{pending := #{ptk := Ptk}} = Join, Ctx) ->
    %% A valid MIC under the pending PTK proves that the access point knows the secret,
    %% whatever check the message fails after it.
    case protected_key_data(Key, Ptk, Join) of
        {drop, _} = Drop -> Drop;
        {deauthenticate, Why} -> finish(Join#{proof := proved}, Why, Ctx);
        {ok, Data} -> message_3(State, Key, Data, Join#{proof := proved}, Ctx)
    end;
message(group_1, keys, _Key, _Join, _Ctx) ->
    {drop, no_pairwise};
message(group_1, State, Key, #{ptk := Ptk} = Join, Ctx) ->
    case protected_key_data(Key, Ptk, Join) of
        {drop, _} = Drop -> Drop;
        {deauthenticate, Why} -> finish(Join, Why, Ctx);
        {ok, Data} -> group_1(State, Key, Data, Join)
    end;
message(unknown, _State, _Key, _Join, _Ctx) ->
    {drop, unknown_message}.

%% A MIC-protected message's key data: its MIC valid under the KCK, its Encrypted bit
%% set and its key data unwrapped under the KEK and parsed. A key of the wrong length
%% deauthenticates; every other failure drops the frame.
protected_key_data(#{mic := Mic, encrypted := Encrypted, data := Wrapped} = Key, #{kck := Kck, kek := Kek},
                   #{akm := Akm}) ->
    case erx_wpa_kdf:check_mic(suite(Akm), Kck, erx_wpa_key:mic_input(Key), Mic) of
        false -> {drop, bad_mic};
        true when not Encrypted -> {drop, not_encrypted};
        true ->
            case erx_wpa_kdf:unwrap(Kek, Wrapped) of
                {error, unwrap} -> {drop, unwrap};
                {ok, Plain} ->
                    case erx_wpa_key:key_data(Plain) of
                        {ok, Data} -> {ok, Data};
                        {error, {length, _}} -> {deauthenticate, key_length};
                        {error, _} -> {drop, key_data}
                    end
            end
    end.

%% Message 3 under a valid MIC: the RSN element and RSNXE the scan reported, the
%% Install bit, a GTK and, under PMF, an IGTK; then the watermark rises to its
%% counter, message 4 answers it, and only what differs from the slots is installed.
message_3(_State, _Key, #{rsn := Rsn, rsnxe := Rsnxe}, #{scan := #{rsn := ScanRsn, rsnxe := ScanRsnxe}} = Join,
          Ctx) when Rsn =/= ScanRsn; Rsnxe =/= ScanRsnxe ->
    finish(Join, rsn_element_differs, Ctx);
message_3(_State, #{install := false}, _Data, _Join, _Ctx) ->
    {drop, no_install};
message_3(_State, _Key, #{gtk := none}, _Join, _Ctx) ->
    {drop, no_gtk};
message_3(_State, _Key, #{igtk := none}, #{pmf := Pmf}, _Ctx) when Pmf =/= none ->
    {drop, no_igtk};
message_3(State, #{replay_counter := Counter, rsc := Rsc}, Data, Join, #{now := Now}) ->
    #{ref := Ref, akm := Akm, pending := #{ptk := #{kck := Kck, tk := Tk} = Ptk}} = Join,
    Offered = [#{slot => pairwise, key => Tk, rsc => 0} | group_keys(Data, Rsc, Join)],
    Message4 = erx_wpa_key:build(message_4, suite(Akm), Kck, #{replay_counter => Counter}),
    {Installs, Installed} = install(Offered, Join),
    Deadline = case State of open -> none; _ -> Now + ?NEXT_MESSAGE_MS end,
    {[{chip, {eapol, Ref, Message4}} | Installs],
     Installed#{watermark := Counter, ptk := Ptk, deadline := Deadline,
                need := [Slot || #{slot := Slot} <- Offered]}}.

%% Group message 1 under a valid MIC: a GTK and, under PMF, the IGTK if it carries
%% one; then the watermark rises, group message 2 answers it, and only what differs
%% from the slots is installed. The machine stays in its state.
group_1(_State, _Key, #{gtk := none}, _Join) ->
    {drop, no_gtk};
group_1(_State, #{replay_counter := Counter, rsc := Rsc}, Data, Join) ->
    #{ref := Ref, akm := Akm, ptk := #{kck := Kck}} = Join,
    Group2 = erx_wpa_key:build(group_2, suite(Akm), Kck, #{replay_counter => Counter}),
    {Installs, Installed} = install(group_keys(Data, Rsc, Join), Join),
    {[{chip, {eapol, Ref, Group2}} | Installs], Installed#{watermark := Counter}}.

%% The group keys a message carries: its GTK, whose receive counter is the frame's
%% Key RSC, and under PMF its IGTK, whose receive counter is the KDE's packet number.
group_keys(#{gtk := #{id := GtkId, key := Gtk}, igtk := Igtk}, Rsc, #{pmf := Pmf}) ->
    Group = [#{slot => gtk_slot(GtkId), key => Gtk, rsc => Rsc}],
    case Igtk of
        #{id := IgtkId, ipn := Ipn, key := Key} when Pmf =/= none ->
            Group ++ [#{slot => {igtk, IgtkId}, key => Key, rsc => Ipn}];
        _ ->
            Group
    end.

%% The Key ID field's two bits name the GTK slot, 0 included; the pairwise slot is
%% a slot of its own.
gtk_slot(Id) -> {gtk, Id}.

%% ---- The key slots ----

%% One set_keys request for the offered keys that differ from their slot's key,
%% confirmed or not, each slot it fills recorded under the request's install id as
%% unconfirmed; nothing when every key equals its slot's.
-spec install([install()], join()) -> {[action()], join()}.
install(Offered, #{ref := Ref, slots := Slots, next_install := Id} = Join) ->
    case [Item || #{slot := Slot, key := Key} = Item <- Offered, slot_key(Slot, Slots) =/= Key] of
        [] ->
            {[], Join};
        Changed ->
            Filled = lists:foldl(fun(#{slot := Slot, key := Key}, Acc) ->
                                         Acc#{Slot => #{key => Key, id => Id, confirmed => false}}
                                 end, Slots, Changed),
            {[{chip, {set_keys, Ref, Id, Changed}}], Join#{slots := Filled, next_install := Id + 1}}
    end.

-spec slot_key(slot(), #{slot() => held()}) -> <<_:128>> | none.
slot_key(Slot, Slots) ->
    case Slots of
        #{Slot := #{key := Key}} -> Key;
        #{} -> none
    end.

set_keys_confirm(_State, {set_keys_confirm, _, Id, _}, #{next_install := Next}, _Ctx) when Id >= Next ->
    {drop, unknown_install};
set_keys_confirm(_State, {set_keys_confirm, _, _Id, refused}, Join, Ctx) ->
    finish(Join, install_refused, Ctx);
set_keys_confirm(State, {set_keys_confirm, Ref, Id, ok}, #{slots := Slots} = Join, #{now := Now}) ->
    case [Slot || Slot := #{id := Filled, confirmed := false} <- Slots, Filled =:= Id] of
        [] ->
            {drop, superseded_install};
        Confirmed ->
            Updated = Join#{slots := lists:foldl(fun(Slot, Acc) -> confirm(Slot, Acc) end, Slots, Confirmed)},
            case {State, complete(Updated)} of
                {keys, true} ->
                    {[{chip, {port, Ref, open}}], Updated#{state := open, opened := Now, deadline := none}};
                {rekey, true} ->
                    {[], Updated#{state := open, deadline := none}};
                {_, _} ->
                    {[], Updated}
            end
    end.

confirm(Slot, Slots) ->
    maps:update_with(Slot, fun(Held) -> Held#{confirmed := true} end, Slots).

%% Every negotiated key of the handshake is in its slot and confirmed: the TK of the
%% PTK the last accepted message 3 installed in the pairwise slot, and each slot that
%% message named. A message 1 after it, which no MIC protects, changes neither.
complete(#{ptk := #{tk := Tk}, slots := Slots, need := Need}) when Need =/= [] ->
    slot_key(pairwise, Slots) =:= Tk andalso
        lists:all(fun(Slot) -> maps:get(confirmed, maps:get(Slot, Slots)) end, Need);
complete(#{}) ->
    false.

%% ---- Deadlines ----

due(_State, {deadline, _}, #{deadline := Deadline}, #{now := Now}) when Deadline =:= none; Now < Deadline ->
    {drop, early_deadline};
due(sae, {deadline, _}, #{sae := accepted} = Join, Ctx) ->
    finish(Join, {deadline, sae}, Ctx);
due(sae, {deadline, _}, Join, Ctx) ->
    sae_step(Join, deadline, Ctx);
due(rekey, {deadline, _}, Join, _Ctx) ->
    {[], Join#{state := open, pending := none, asked := none, deadline := none}};
due(State, {deadline, _}, Join, Ctx) ->
    finish(Join, {deadline, State}, Ctx).

%% ---- How a join ends ----

%% Ends the join with the class "How a join ends" derives from what the join did.
finish(#{opened := Opened} = Join, Reason, #{now := Now} = Ctx) ->
    Class = if
                Opened =/= none, Now - Opened < ?SHORT_LINK_MS -> bss;
                Opened =/= none -> none;
                true -> case Join of #{proof := tested} -> secret; #{} -> bss end
            end,
    finish(Join, Class, Reason, Ctx).

%% Closes the port, disconnects unless the chip reported the link's end, deletes the
%% installed keys, and returns to idle with the end's class.
finish(Join, Class, Reason, _Ctx) ->
    #{ref := Ref, opened := Opened, reported := Reported, slots := Slots, counts := Counts} = Join,
    Actions = [{chip, {port, Ref, closed}} || Opened =/= none]
        ++ [{chip, {disconnect, Ref, Reason}} || not Reported]
        ++ [{chip, {delete_keys, Ref}} || map_size(Slots) > 0]
        ++ [{ended, Class, Reason}],
    {Actions, (new())#{counts := Counts}}.


%% The AKM's suite number in the AKM table of abi/formats/ieee80211.txt.
suite(Akm) ->
    {Akm, Suite} = lists:keyfind(Akm, 1, ?ERX_IEEE80211_AKM_MEMBERS),
    Suite.
