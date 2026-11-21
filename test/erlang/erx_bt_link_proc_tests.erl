%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of the link process, erx_bt_link (docs/design-bluetooth.md, "The link's
%% messages"), over stand-ins: the case's own process is the controller process, and three
%% processes registered as the window (erx_bt_fs), the registry (erx_gatt_srv) and the
%% store (erx_bt_store) pass on what the link sends them; the store's also answers the
%% identity address. A Just Works pairing to the store's ok; a reconnection that encrypts
%% with a kept bond's key; a crash mid-pairing that shows no secret; the handler's
%% deadline on the wake-up timer; a disconnection mid-pairing that reaches the window; and
%% format_status/1 hiding the window's fresh values in a message and the sys log.
%% PDUs are written from the Core Specification 6.3's numbers (Vol 3 Parts A, F and H;
%% Vol 4 Part E, 7.7.8 and 7.7.65.5).

-module(erx_bt_link_proc_tests).

-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

-define(CENTRAL_ADDRESS, <<16#C0, 16#FF, 16#EE, 16#12, 16#34, 16#56>>).
-define(OWN_ADDRESS, <<16#D1, 16#E2, 16#F3, 16#A4, 16#B5, 16#C6>>).
-define(CENTRAL, {random, ?CENTRAL_ADDRESS}).
-define(PERIPHERAL, {random, ?OWN_ADDRESS}).
-define(BOND_LTK, <<16#B0:128>>).
-define(NAME, {16#40, 1}).
-define(PASSKEY, 123456).
-define(WAIT_MS, 2000).

%% ---- the cases ----

%% A Just Works pairing through the link process: the window admits it, the controller is
%% answered with the pairing's LTK, the registry hears the link encrypted and then bonded,
%% the store is asked to keep the bond and its ok reaches the window as `bonded`.
just_works_pairing_to_the_store_test() ->
    with_owners(fun() ->
        Link = start(#{pairing => true}),
        {PhonePdus, Ltk} = just_works(),
        {Alias, Tag} = admitted(Link),
        [phone(Link, Pdu) || Pdu <- PhonePdus],
        hci(Link, {le_long_term_key_request, 16#40, <<0:64>>, 0}),
        ?assertEqual({ltk_reply, Ltk}, from_link()),
        hci(Link, {ltk_reply_complete, ok}),
        hci(Link, {encryption_change, 0, 16#40, 1}),
        ?assertEqual({security, #{level => encrypted, bonded => false}}, told(erx_gatt_srv)),
        [phone(Link, Pdu) || Pdu <- identity()],
        ?assertMatch({keep, #{ltk := Ltk, level := unauthenticated}, #{}}, told(erx_bt_store)),
        Alias ! {erx_bt_store, {kept, ok}},
        ?assertEqual({outcome, Tag, {bonded, {random, <<16#C1, 16#C2, 16#C3, 16#C4, 16#C5, 16#C6>>}, unauthenticated}},
                     told(erx_bt_fs)),
        ?assertEqual({security, #{level => encrypted, bonded => true}}, told(erx_gatt_srv)),
        ?assertEqual([], [Code || <<_:16, 6:16/little, 16#05, Code>> <- sent()])
    end).

%% A link whose address resolved to a kept bond answers the Long Term Key Request with the
%% bond's key and is encrypted at the controller's report; the registry hears it bonded.
%% sys:get_status/1 shows no key.
reconnection_with_a_kept_bond_test() ->
    with_owners(fun() ->
        Link = start(#{bond => #{ltk => ?BOND_LTK, level => authenticated}}),
        hci(Link, {le_long_term_key_request, 16#40, <<0:64>>, 0}),
        ?assertEqual({ltk_reply, ?BOND_LTK}, from_link()),
        hci(Link, {ltk_reply_complete, ok}),
        hci(Link, {encryption_change, 0, 16#40, 1}),
        ?assertEqual({security, #{level => authenticated, bonded => true}}, told(erx_gatt_srv)),
        ?assertNot(holds(sys:get_status(Link), [?BOND_LTK]))
    end).

%% A raise in the core mid-pairing, once the link holds the pairing's LTK and the Security
%% Manager its private key, passkey and DHKey: neither sys:get_status/1 before it, nor
%% the link's exit reason, nor any report logged shows a secret, and the window hears the
%% pairing failed `disconnected`.
crash_mid_pairing_leaks_nothing_test() ->
    with_owners(fun() ->
        ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{test => self()}}),
        try
            Link = start(#{pairing => true}),
            {PhonePdus, Ltk} = just_works(),
            {Alias, Tag} = admitted(Link),
            [phone(Link, Pdu) || Pdu <- PhonePdus],
            Secrets = [Ltk, own_private(), dhkey(), ?PASSKEY],
            ?assertNot(holds(sys:get_status(Link), Secrets)),
            Alias ! {erx_bt_fs, {admission, Tag}},        % no clause of the core takes it
            Reason = receive {'EXIT', Link, R} -> R after ?WAIT_MS -> error(link_not_ended) end,
            ?assertMatch({step_raised, error, #{key := unauthenticated}}, Reason),
            ?assertEqual({outcome, Tag, {failed, disconnected}}, told(erx_bt_fs)),
            timer:sleep(100),
            Logged = logged(),
            ?assertNotEqual([], Logged),
            ?assertNot(holds(Logged, Secrets)),
            lists:foreach(fun formatted/1, Logged)
        after
            logger:remove_handler(?MODULE)
        end
    end).

%% format_status/1 shows a message that carries the window's fresh values, and the sys
%% log that holds it, without them: the case erXos's report filter and OTP's own crash
%% reports both rely on when the verdict itself is the last message.
format_status_hides_the_verdict_test() ->
    with_owners(fun() ->
        Link = start(#{pairing => true}),
        Verdict = {erx_bt_fs, {admission, 1, {open, nodisplay, fresh()}}},
        Status = erx_bt_link:format_status(#{state => sys:get_state(Link), message => Verdict,
                                             log => [{in, Verdict}], reason => normal}),
        ?assertMatch(#{message := {erx_bt_fs, admission}, log := []}, Status),
        ?assertNot(holds(Status, [own_private(), ?PASSKEY]))
    end).

%% The handler's deadline runs on the wake-up timer: a write the handler never answers is
%% answered Unlikely Error (0x0E) 5 s after it arrived, and not before.
handler_deadline_on_the_timer_test_() ->
    {timeout, 20, fun() ->
        with_owners(fun() ->
            Link = start(#{}),
            Handle = handle(open_w),
            phone_att(Link, <<16#12, Handle:16/little, "hi">>),
            ?assertMatch({write, _Ref, {svc, open_w}, <<"hi">>}, told(erx_gatt_srv)),
            Unlikely = <<5:16/little, 4:16/little, 16#01, 16#12, Handle:16/little, 16#0E>>,
            receive {erx_bt_link, ?NAME, {send, _, Unlikely}} -> error(answered_early) after 4500 -> ok end,
            receive {erx_bt_link, ?NAME, {send, _, Unlikely}} -> ok after 1500 -> error(not_answered) end
        end)
    end}.

%% A link that ends while the window awaits its pairing, as at the supervisor's shutdown
%% at link_down, tells the window the pairing failed `disconnected`.
disconnection_mid_pairing_reaches_the_window_test() ->
    with_owners(fun() ->
        Link = start(#{pairing => true}),
        {_Alias, Tag} = admitted(Link),
        exit(Link, shutdown),
        receive {'EXIT', Link, shutdown} -> ok after ?WAIT_MS -> error(link_not_ended) end,
        ?assertEqual({outcome, Tag, {failed, disconnected}}, told(erx_bt_fs))
    end).

%% ---- the stand-ins ----

%% Runs Case with the three owners registered, then ends them and any link still running,
%% waiting for each end so the names are free for the next case.
with_owners(Case) ->
    process_flag(trap_exit, true),
    Test = self(),
    Owners = [begin
                  Pid = spawn_link(fun() -> stand_in(Name, Test) end),
                  true = register(Name, Pid),
                  Pid
              end || Name <- [erx_bt_fs, erx_gatt_srv, erx_bt_store]],
    try Case()
    after
        {links, Linked} = process_info(self(), links),
        Links = [Pid || Pid <- Linked, is_pid(Pid), proc_lib:initial_call(Pid) =:= {erx_bt_link, init, ['Argument__1']}],
        lists:foreach(fun end_process/1, Owners ++ Links)
    end.

end_process(Pid) ->
    Monitor = monitor(process, Pid),
    unlink(Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok end.

stand_in(Name, Test) ->
    receive
        {'$gen_call', From, address} when Name =:= erx_bt_store -> gen_server:reply(From, ?OWN_ADDRESS);
        {erx_bt_link, Alias, Message} -> Test ! {owner, Name, Alias, Message}
    end,
    stand_in(Name, Test).

%% A link started by the case as its controller process, with the table of services/0.
start(Domain) ->
    {ok, Link} = erx_bt_link:start_link(
                   #{name => ?NAME, conn => make_ref(), hci => self(),
                     info => #{peer_type => 1, peer => ?CENTRAL_ADDRESS, share => 16, acl_tx_max => 251},
                     domain => maps:merge(#{table => table(), values => #{}, pairing => false, bond => none}, Domain)}),
    Link.

hci(Link, Input) -> Link ! {erx_bt_hci, Input}.

%% A basic frame (Part A, 3.1) in one ACL packet, flagged first_flushable (Vol 4 Part E, 5.4.2).
frame(Cid, Payload) -> <<(byte_size(Payload)):16/little, Cid:16/little, Payload/binary>>.
phone(Link, SmpPdu) -> hci(Link, {acl, 2, frame(6, SmpPdu)}).
phone_att(Link, AttPdu) -> hci(Link, {acl, 2, frame(4, AttPdu)}).

%% The phone's Pairing Request and the window's `open` verdict for it.
admitted(Link) ->
    phone(Link, pairing_request()),
    {Alias, {admit, Tag, ?CENTRAL}} = addressed(erx_bt_fs),
    Alias ! {erx_bt_fs, {admission, Tag, {open, nodisplay, fresh()}}},
    {Alias, Tag}.

%% The next message the link sent the owner `Name`, with the alias it sent it from.
addressed(Name) ->
    receive {owner, Name, Alias, Message} -> {Alias, Message}
    after ?WAIT_MS -> error({nothing_to, Name})
    end.

told(Name) -> element(2, addressed(Name)).

%% The next request to the controller process that is not a packet.
from_link() ->
    receive {erx_bt_link, ?NAME, Request} when element(1, Request) =/= send -> Request
    after ?WAIT_MS -> error(no_request)
    end.

%% The packets the link has handed over so far.
sent() ->
    receive {erx_bt_link, ?NAME, {send, _Boundary, Data}} -> [Data | sent()]
    after 100 -> []
    end.

%% ---- the reports ----

%% The logger handler: every event logged reaches the case.
log(Event, #{config := #{test := Test}}) -> Test ! {logged, Event}.

logged() ->
    receive {logged, Event} -> [Event | logged()]
    after 0 -> []
    end.

%% A logged report as its own callback formats it, which raises when format_status/1 hands
%% gen_server's formatter a shape it does not take.
formatted(#{msg := {report, Report}, meta := #{report_cb := Format}}) when is_function(Format, 2) ->
    Format(Report, #{});
formatted(#{msg := {report, Report}, meta := #{report_cb := Format}}) when is_function(Format, 1) ->
    {Text, Args} = Format(Report),
    io_lib:format(Text, Args);
formatted(_Event) ->
    ok.

%% Whether a secret occurs anywhere in a term, inside a binary included.
holds(Term, Secrets) -> lists:any(fun(Secret) -> occurs(Secret, Term) end, Secrets).

occurs(Secret, Secret) -> true;
occurs(Secret, Term) when is_binary(Secret), is_binary(Term) -> binary:match(Term, Secret) =/= nomatch;
occurs(Secret, Term) when is_tuple(Term) -> occurs(Secret, tuple_to_list(Term));
occurs(Secret, Term) when is_map(Term) -> occurs(Secret, maps:to_list(Term));
occurs(Secret, [Head | Tail]) -> occurs(Secret, Head) orelse occurs(Secret, Tail);
occurs(_Secret, _Term) -> false.

%% ---- the table and the pairing ----

services() ->
    [#{name => svc, uuid => <<16#00, 16#FF>>,
       characteristics => [#{name => open_w, uuid => <<16#01, 16#FF>>, max => 20, access => #{write => open}}]}].

table() -> erx_gatt_db:build(services()).

handle(Char) -> {ok, #{value := Handle}} = erx_gatt_db:characteristic({svc, Char}, table()), Handle.

%% SMP's Pairing Request (Part H, 3.5.1): NoInputNoOutput, no OOB, bonding, MITM, Secure
%% Connections and CT2, a 16-octet key, every key offered.
pairing_request() -> <<16#01, 16#03, 0, 16#2D, 16, 16#0B, 16#0B>>.

%% The phone's Identity Information and Identity Address Information (Part H, 3.6.4, 3.6.5).
identity() -> [<<16#08, 7:128>>, <<16#09, 1, 16#C6, 16#C5, 16#C4, 16#C3, 16#C2, 16#C1>>].

key(Seed) ->
    {<<4, X:32/binary, Y:32/binary>>, Private} = crypto:generate_key(ecdh, secp256r1, crypto:hash(sha256, <<Seed>>)),
    {Private, {X, Y}}.

nonces(Seed) -> [crypto:hash(md5, <<Seed, I>>) || I <- lists:seq(1, 20)].

%% The window's fresh values: the link's private key, its nonces and a passkey.
fresh() ->
    {Private, Public} = key(1),
    #{private => Private, public => Public, nonces => nonces(1), passkey => ?PASSKEY}.

own_private() -> element(1, key(1)).

dhkey() -> erx_smp_crypto:dhkey(element(1, key(2)), element(2, key(1))).

%% The honest phone's Just Works PDUs after its Pairing Request (Part H, 2.3.5.6.2 and
%% 2.3.5.6.5, 3.5 and 3.6), computed independently with erx_smp_crypto, and the LTK.
just_works() ->
    {_PhonePrivate, {X, Y}} = key(2),
    [Na | _] = nonces(2),
    [Nb | _] = nonces(1),
    {MacKey, Ltk} = erx_smp_crypto:f5(dhkey(), Na, Nb, ?CENTRAL, ?PERIPHERAL),
    Ea = erx_smp_crypto:f6(MacKey, Na, Nb, <<0:128>>, <<16#2D, 0, 16#03>>, ?CENTRAL, ?PERIPHERAL),
    {[<<16#0C, (rev(X))/binary, (rev(Y))/binary>>, <<16#04, (rev(Na))/binary>>, <<16#0D, (rev(Ea))/binary>>], Ltk}.

rev(Bytes) -> list_to_binary(lists:reverse(binary_to_list(Bytes))).
