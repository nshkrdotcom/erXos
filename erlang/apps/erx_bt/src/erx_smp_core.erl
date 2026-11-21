%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_smp_core).
-moduledoc """
The Security Manager of one link as responder, a pure state machine
(docs/design-bluetooth.md, "Secure Connections only"), from the Bluetooth Core
Specification 6.3, Vol 3 Part H. `new/1` takes the addresses connection setup used;
`step/2` takes one input and the state and returns the actions the link performs and
the next state. The inputs are a PDU as `erx_smp:decode/1` gives it, the pairing
window's verdict on a Pairing Request, `encrypted` when the link is encrypted with the
pairing's key, and `timeout` when the Security Manager Timer runs out (3.4).

**A pairing** runs through these phases:

- `idle`: a Pairing Request asks the window (`admit`) and starts the timer;
- `{admitting, Request}`: the verdict refuses, or opens a pairing with the window's
  mode and the pairing's fresh key pair, nonces and passkey, and the request decides
  the method: Passkey Entry in a `display` window, the phone typing what erXos shows,
  and Just Works in a `nodisplay` one (2.3.5.1, Tables 2.7 and 2.8);
- `{public_key, P}`: the phone's public key, checked on P-256, not SMP's debug key and
  not sharing erXos's X coordinate (2.3.5.6.1), answered with erXos's;
- `{confirm, Round, P}` and `{random, Round, Confirm, P}`: authentication stage 1,
  twenty rounds of Passkey Entry, the phone's commitment checked when its nonce comes
  (2.3.5.6.3, Figure 2.4), or Just Works's one round, erXos's commitment sent with its
  public key (2.3.5.6.2);
- `{dhkey_check, Na, Nb, P}`: the phone's check value, after which erXos sends its own
  and gives the link the LTK (`{key, Ltk, Level}`), so the phone's encryption uses it
  (2.3.5.6.5);
- `{encrypting, Bond}`, `{identity, Bond}`, `{identity_address, Bond}`: once encrypted,
  the phone's IRK and identity address, the only keys distributed (2.4.3.2, 3.6.1),
  after which the bond is reported (`{bonded, Bond}`) and the link is `done`.

**Refusals** follow the design's list: no window, Pairing Not Supported; the pairing
wait, Repeated Attempts; a bonded link, Unspecified Reason; no Secure Connections, an
OOB claim, no bonding or no identity key offered, or a method below the window's
level, Authentication Requirements; a key shorter than 16 octets, Encryption Key Size;
a malformed PDU, a reserved value or the debug key, Invalid Parameters; a key off the
curve, a reflected key or a wrong check value, DHKey Check Failed; a wrong commitment,
Confirm Value Failed. A PDU out of its turn fails the pairing with Unspecified Reason,
or Command Not Supported for a command a responder never takes. Every failure of a
pairing goes through one route, `fail/2`, which sends Pairing Failed, reports the
reason (`{failed, Reason}`) and stops the timer; the phone's Pairing Failed is
reported as `{peer, Code}`. A timeout reports `timeout`, sends nothing more and ends
the link (`end_link`); the state is then `ended`, which ignores everything (3.4).
Reserved codes, empty PDUs and keypress notifications are ignored in every phase: erXos
never sets the keypress flag, so they never restart the timer.

`timer` restarts the 30 s timer and `timer_stop` stops it; `{passkey, N}` is the
passkey for the window to show.
""".

-include("generated/erx_abi.hrl").

-export([new/1, step/2]).
-export_type([state/0, input/0, action/0, verdict/0, bond/0, reason/0]).

-type mode() :: display | nodisplay.
-type level() :: authenticated | unauthenticated.
-type value() :: erx_smp_crypto:value().
-doc "The window's answer to `admit` (docs/design-bluetooth.md, \"The pairing window\").".
-type verdict() :: {open, mode(), erx_smp_crypto:fresh()} | closed | waiting | bonded.
-type input() :: {pdu, erx_smp:decoded()} | {admission, verdict()} | encrypted | timeout.
-doc "What a successful pairing leaves: the LTK, its level and the phone's identity.".
-type bond() :: #{ltk := value(), level := level(), irk := value(), identity := erx_smp_crypto:address()}.
-type reason() :: already_bonded | secure_connections_required | key_size | method | bonding | invalid
                | confirm | dhkey | unexpected | timeout | {peer, byte()}.
-type action() :: admit | timer | timer_stop | end_link | {send, erx_smp:pdu()} | {passkey, 0..?ERX_SMP_PASSKEY_MAX}
                | {key, value(), level()} | {bonded, bond()} | {failed, reason()}.
%% The pairing's context once admitted: the method, both feature exchanges, the fresh
%% values and, from the public key exchange on, the phone's key and the DHKey.
-type pairing() :: #{method := passkey | just_works, request := erx_smp:features(), response := erx_smp:features(),
                     fresh := erx_smp_crypto:fresh(), peer => erx_smp_crypto:public_key(), dhkey => <<_:256>>}.
-type phase() :: idle | {admitting, erx_smp:features()} | {public_key, pairing()}
               | {confirm, non_neg_integer(), pairing()} | {random, non_neg_integer(), value() | none, pairing()}
               | {dhkey_check, value(), value(), pairing()} | {encrypting, map()} | {identity, map()}
               | {identity_address, map()} | done | ended.
-opaque state() :: #{phase := phase(), central := erx_smp_crypto:address(), peripheral := erx_smp_crypto:address()}.

-doc "A link's Security Manager, with the addresses its connection setup used (2.2.7).".
-spec new(#{central := erx_smp_crypto:address(), peripheral := erx_smp_crypto:address()}) -> state().
new(#{central := Central, peripheral := Peripheral}) -> #{phase => idle, central => Central, peripheral => Peripheral}.

-doc "Takes one input; returns the link's actions and the next state.".
-spec step(input(), state()) -> {[action()], state()}.
step(Input, #{phase := Phase} = State) ->
    try phase(Input, Phase, State) of
        {Actions, Next} -> {Actions, State#{phase := Next}}
    catch
        throw:{fail, Code, Reason} ->
            {[{send, {pairing_failed, Code}}, {failed, Reason}, timer_stop], State#{phase := idle}}
    end.

%% What every phase ignores, then the phases without a pairing, then a pairing's.
phase({pdu, {reserved, _}}, Phase, _State) -> {[], Phase};
phase({pdu, empty}, Phase, _State) -> {[], Phase};
phase({pdu, {pairing_keypress_notification, _}}, Phase, _State) -> {[], Phase};
phase(_Input, ended, _State) -> {[], ended};
phase({pdu, {pairing_request, Request}}, idle, _State) -> {[admit, timer], {admitting, Request}};
phase(_Input, idle, _State) -> {[], idle};
phase({pdu, {pairing_request, _}}, done, _State) ->
    {[{send, {pairing_failed, ?ERX_SMP_REASON_UNSPECIFIED_REASON}}, {failed, already_bonded}], done};
phase(_Input, done, _State) -> {[], done};
phase(timeout, _Phase, _State) -> {[{failed, timeout}, end_link], ended};
phase({pdu, {pairing_failed, Code}}, _Phase, _State) -> {[{failed, {peer, Code}}, timer_stop], idle};
phase({pdu, {invalid, _}}, _Phase, _State) -> fail(?ERX_SMP_REASON_INVALID_PARAMETERS, invalid);
phase({admission, Verdict}, {admitting, Request}, _State) -> admitted(Verdict, Request);
phase({pdu, {pairing_public_key, Key}}, {public_key, P}, _State) -> public_key(Key, P);
phase({pdu, {pairing_confirm, Confirm}}, {confirm, Round, P}, _State) ->
    {[{send, {pairing_confirm, confirm(Round, P)}}, timer], {random, Round, Confirm, P}};
phase({pdu, {pairing_random, Na}}, {random, Round, Confirm, P}, _State) -> random(Na, Round, Confirm, P);
phase({pdu, {pairing_dhkey_check, Ea}}, {dhkey_check, Na, Nb, P}, State) -> dhkey_check(Ea, Na, Nb, P, State);
phase(encrypted, {encrypting, Bond}, _State) -> {[timer], {identity, Bond}};
phase({pdu, {identity_information, Irk}}, {identity, Bond}, _State) -> {[timer], {identity_address, Bond#{irk => Irk}}};
phase({pdu, {identity_address_information, Type, Address}}, {identity_address, Bond}, _State) ->
    {[{bonded, Bond#{identity => {identity_type(Type), Address}}}, timer_stop], done};
phase(encrypted, Phase, _State) -> {[], Phase};
phase({admission, _}, Phase, _State) -> {[], Phase};
phase({pdu, Pdu}, _Phase, _State) when element(1, Pdu) =:= pairing_response; element(1, Pdu) =:= security_request;
                                       element(1, Pdu) =:= encryption_information;
                                       element(1, Pdu) =:= central_identification ->
    fail(?ERX_SMP_REASON_COMMAND_NOT_SUPPORTED, unexpected);
phase({pdu, _}, _Phase, _State) -> fail(?ERX_SMP_REASON_UNSPECIFIED_REASON, unexpected).

admitted(closed, _Request) -> {[{send, {pairing_failed, ?ERX_SMP_REASON_PAIRING_NOT_SUPPORTED}}, timer_stop], idle};
admitted(waiting, _Request) -> {[{send, {pairing_failed, ?ERX_SMP_REASON_REPEATED_ATTEMPTS}}, timer_stop], idle};
admitted(bonded, _Request) -> fail(?ERX_SMP_REASON_UNSPECIFIED_REASON, already_bonded);
admitted({open, Mode, Fresh}, Request) ->
    Response = response(Mode),
    {[{send, {pairing_response, Response}}, timer],
     {public_key, #{method => method(Request, Mode), request => Request, response => Response, fresh => Fresh}}}.

%% The method a request reaches in a window of this mode, or the refusal (2.3.4,
%% 2.3.5.1, 3.5.1): Passkey Entry, erXos displaying, when the phone has a keyboard and
%% the window a display; Just Works in a nodisplay window, whose response sets no MITM.
method(#{io := Io, oob := Oob, auth := Auth, max_key := MaxKey, initiator_keys := Keys}, Mode) ->
    require(Io =< ?ERX_SMP_IO_CAPABILITY_KEYBOARD_DISPLAY andalso Oob =< ?ERX_SMP_OOB_PRESENT
            andalso MaxKey >= ?ERX_SMP_KEY_SIZE_MIN andalso MaxKey =< ?ERX_SMP_KEY_SIZE_MAX,
            ?ERX_SMP_REASON_INVALID_PARAMETERS, invalid),
    #{sc := Sc, bonding := Bonding} = erx_smp:auth(Auth),
    require(Sc, ?ERX_SMP_REASON_AUTHENTICATION_REQUIREMENTS, secure_connections_required),
    require(MaxKey >= ?ERX_SMP_KEY_SIZE_MAX, ?ERX_SMP_REASON_ENCRYPTION_KEY_SIZE, key_size),
    require(Oob =/= ?ERX_SMP_OOB_PRESENT, ?ERX_SMP_REASON_AUTHENTICATION_REQUIREMENTS, method),
    require(Bonding =:= ?ERX_SMP_BONDING andalso maps:get(id, erx_smp:keys(Keys)),
            ?ERX_SMP_REASON_AUTHENTICATION_REQUIREMENTS, bonding),
    Keyboard = Io =:= ?ERX_SMP_IO_CAPABILITY_KEYBOARD_ONLY orelse Io =:= ?ERX_SMP_IO_CAPABILITY_KEYBOARD_DISPLAY,
    case Mode of
        nodisplay -> just_works;
        display when Keyboard -> passkey;
        display -> fail(?ERX_SMP_REASON_AUTHENTICATION_REQUIREMENTS, method)
    end.

%% The Pairing Response: the window's IO capability, bonding, MITM in a display window,
%% Secure Connections, 16-octet keys, the phone's identity key asked for and nothing
%% else in either direction, the link key included (2.3.5.7, 3.6.1).
response(Mode) ->
    Io = case Mode of
             display -> ?ERX_SMP_IO_CAPABILITY_DISPLAY_ONLY;
             nodisplay -> ?ERX_SMP_IO_CAPABILITY_NO_INPUT_NO_OUTPUT
         end,
    #{io => Io, oob => 0,
      auth => erx_smp:auth_octet(#{bonding => ?ERX_SMP_BONDING, mitm => Mode =:= display, sc => true,
                                   keypress => false, ct2 => false}),
      max_key => ?ERX_SMP_KEY_SIZE_MAX,
      initiator_keys => erx_smp:keys_octet(#{enc => false, id => true, link => false}),
      responder_keys => erx_smp:keys_octet(#{enc => false, id => false, link => false})}.

%% The phone's public key (2.3.5.6.1): on the curve before any key agreement, never the
%% debug key, and never sharing erXos's X coordinate, so a reflected key fails.
public_key({X, _} = Key, #{method := Method, fresh := #{private := Private, public := {OwnX, _} = Own} = Fresh} = P) ->
    require(erx_smp_crypto:on_curve(Key), ?ERX_SMP_REASON_DHKEY_CHECK_FAILED, dhkey),
    require(Key =/= erx_smp_crypto:debug_key(), ?ERX_SMP_REASON_INVALID_PARAMETERS, invalid),
    require(X =/= OwnX, ?ERX_SMP_REASON_DHKEY_CHECK_FAILED, dhkey),
    Exchanged = P#{peer => Key, dhkey => erx_smp_crypto:dhkey(Private, Key)},
    case Method of
        just_works ->
            {[{send, {pairing_public_key, Own}}, {send, {pairing_confirm, confirm(0, Exchanged)}}, timer],
             {random, 0, none, Exchanged}};
        passkey ->
            {[{send, {pairing_public_key, Own}}, {passkey, maps:get(passkey, Fresh)}, timer],
             {confirm, 0, Exchanged}}
    end.

%% erXos's commitment of a round, Cb = f4(PKbx, PKax, Nb, Z) (2.2.6, Table 2.1).
confirm(Round, #{peer := {PeerX, _}, fresh := #{public := {OwnX, _}}} = P) ->
    erx_smp_crypto:f4(OwnX, PeerX, nonce(Round, P), z(Round, P)).

%% The phone's nonce: in Passkey Entry its commitment of the round must match, Ca =
%% f4(PKax, PKbx, Na, Z), before erXos reveals its own nonce (Figure 2.4, step 7a);
%% Just Works checks nothing here, the phone checking erXos's (2.3.5.6.2).
random(Na, Round, Confirm, #{method := Method, peer := {PeerX, _}, fresh := #{public := {OwnX, _}}} = P) ->
    Nb = nonce(Round, P),
    Last = Method =:= just_works orelse Round + 1 =:= ?ERX_SMP_PASSKEY_ROUNDS,
    Method =:= just_works orelse
        require(crypto:hash_equals(Confirm, erx_smp_crypto:f4(PeerX, OwnX, Na, z(Round, P))),
                ?ERX_SMP_REASON_CONFIRM_VALUE_FAILED, confirm),
    Next = case Last of
               true -> {dhkey_check, Na, Nb, P};
               false -> {confirm, Round + 1, P}
           end,
    {[{send, {pairing_random, Nb}}, timer], Next}.

%% Authentication stage 2 (2.3.5.6.5, Table 2.2): MacKey and the LTK from f5, the
%% phone's check value Ea verified, and erXos's Eb sent; the link takes the LTK.
dhkey_check(Ea, Na, Nb, #{method := Method, request := Request, response := Response, dhkey := DhKey} = P,
            #{central := Central, peripheral := Peripheral}) ->
    {MacKey, Ltk} = erx_smp_crypto:f5(DhKey, Na, Nb, Central, Peripheral),
    R = case Method of
            passkey -> <<(maps:get(passkey, maps:get(fresh, P))):128>>;
            just_works -> <<0:128>>
        end,
    Expected = erx_smp_crypto:f6(MacKey, Na, Nb, R, io_cap(Request), Central, Peripheral),
    require(crypto:hash_equals(Ea, Expected), ?ERX_SMP_REASON_DHKEY_CHECK_FAILED, dhkey),
    Eb = erx_smp_crypto:f6(MacKey, Nb, Na, R, io_cap(Response), Peripheral, Central),
    Level = case Method of
                passkey -> authenticated;
                just_works -> unauthenticated
            end,
    {[{send, {pairing_dhkey_check, Eb}}, {key, Ltk, Level}, timer], {encrypting, #{ltk => Ltk, level => Level}}}.

%% A nonce of the round: Passkey Entry draws one per round, Just Works uses the first.
nonce(Round, #{fresh := #{nonces := Nonces}}) -> lists:nth(Round + 1, Nonces).

%% f4's Z: zero for Just Works; for Passkey Entry 0x80 with the round's bit of the
%% passkey, the least significant first. 2.2.6 gives the 0x80 and 0x81; which bit a
%% round takes the specification leaves to Figure 2.4's "ra = ra1 | ... | ra20", and
%% Bumble v0.0.237's bumble/smp.py, lines 993 and 1682, takes bit Round.
z(_Round, #{method := just_works}) -> 0;
z(Round, #{method := passkey, fresh := #{passkey := Passkey}}) -> 16#80 bor ((Passkey bsr Round) band 1).

%% IOcapA or IOcapB: AuthReq, the OOB data flag and the IO capability, as sent (2.2.8).
io_cap(#{auth := Auth, oob := Oob, io := Io}) -> <<Auth, Oob, Io>>.

%% The identity address's type (3.6.5): public or static random.
identity_type(0) -> public;
identity_type(1) -> random;
identity_type(_) -> fail(?ERX_SMP_REASON_INVALID_PARAMETERS, invalid).

require(true, _Code, _Reason) -> ok;
require(false, Code, Reason) -> fail(Code, Reason).

-spec fail(byte(), reason()) -> no_return().
fail(Code, Reason) -> throw({fail, Code, Reason}).
