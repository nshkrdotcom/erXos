%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_link_core).
-moduledoc """
The pure core of one link process (docs/design-bluetooth.md, "One owner, one step" and
"The link's messages"): L2CAP reassembly and the fixed channels, the link's one key and
whether the controller has encrypted with it, the ATT bearer through `erx_gatt_server`,
the Security Manager through `erx_smp_core`, the notifications waiting for the link's
share of the controller's buffers, and the deadlines of a handler's answer, an indication
and a pairing step. `step/3` takes one input and the time and returns the actions the
link performs and the next core; it reads no clock and keeps no timer.

**Roles.** Every input is `{Role, Message}`, but `expired`, and every action that goes to
an owner is `{Role, Message}`, where `Role` is `hci` (the controller process), `window`,
`registry` or `store`: the clauses of `input/3` are the one list of what each owner may
send the link. A message no clause takes is a defect of the domain's own code, and raises.
Each step of an `hci` input returns `{hci, taken}` first, the acknowledgement the
controller counts the link's backlog by ("Commands and data credits").

**Channels** (Core 6.3 Vol 3 Part A, 2.1): `erx_l2cap:reassemble/3` joins the ACL packets
into frames, and a malformed one ends the link. ATT's channel goes to `erx_gatt_server`;
SMP's to `erx_smp_core`, whose admission the window decides; LE signaling to
`erx_l2cap:signal/1`; a frame on any other channel is dropped and counted.

**The one key** (docs/design-bluetooth.md, "One table, one gate"): a link starts with the
key of the bond its address resolved to, or none, and takes its own pairing's key from
`erx_smp_core` only while it has none (`set_key/3` matches only a link without one, so a
second key raises). A link with a key never pairs: the window's `open` verdict reaches
the Security Manager as `bonded`, which refuses the pairing. At LE Long Term Key Request
the link answers Reply with its key when the request carries zero EDIV and Rand, as
Secure Connections has it, and Negative Reply otherwise (HCI 7.7.65.5, 7.8.25, 7.8.26); a
Reply the controller answers with a failure counts as no Reply. `encrypted` becomes true
at the controller's next report of encryption started, Encryption Change on with AES-CCM
(HCI 7.7.8) or Encryption Key Refresh Complete (7.7.39), each with status success, after a
Reply; any other report about encryption ends the link. The gate reads `#{key,
encrypted}` derived from these two facts alone, so no field a peer sends raises a link's
level.

**A resolved bond is a candidate** ("A link is its bond's only from its encryption"): an
address is whatever the peer sends, and only the key proves the bond. So the core holds
the bond's key from its start, and its kept subscriptions and table hash aside, taking
them on at the first encryption with the key: the subscriptions restored into the bearer
and told to the registry, the hash as the one the bond was last served. Before that the
link has the default configuration, and the ATT server answers a configuration write on
a keyed link Insufficient Encryption. `bonded` is true only on an encrypted link whose key
is a kept bond's.

**A pairing's outcome has one ordering point**: the step in which the Security Manager
ends its third phase sends `{keep, Tag, Bond, Subscriptions}` to the store and `{keeping,
Tag}` to the window. Before it, a failure is the link's to report (`{outcome, Tag,
{failed, Reason}}`); from it, the store tells the window the outcome, and the store's
`kept` tells the link whether its key is a kept bond's.

**Sending**: frames wait in the link's queue and are cut into ACL packets of at most the
controller's length, handed over only while the packets outstanding are below the link's
share; `{completed, Count}` returns them. A notification is refused `busy` while the
queue holds `bt_notify_queue` frames, and an answer on SMP or LE signaling arriving then
is dropped and counted, a refused SMP answer failing its pairing at the step's deadline.
ATT's responses and its one indication in flight queue past it, since an honest phone
sends a request only after it received the last response (Part F, 3.3.2); a frame of
theirs that would make the queue hold more than `bt_notify_queue` plus two frames means
the phone did not wait, and ends the link.

**Closing**: a step's actions end at its first `{close, Reason}`, after the packets the
step hands over, so a Pairing Failed sent with a failure that ends the link goes out
first; what is still queued is dropped with the link.

**Deadlines** (docs/design.md, "Deadlines in state"): a handler's answer to a write within
5 s ("The `ble` facet"), else Unlikely Error; an indication's confirmation within ATT's
30 s transaction timeout (Part F, 3.3.3), else the caller hears `{error, timeout}` and the
link ends; and the Security Manager Timer's 30 s (Part H, 3.4). `next_deadline/1` answers
the earliest, and `expired` runs each that has passed.

**Secrets**: the `key` and `smp` fields of the core hold the LTK and the pairing's private
key, passkey and DHKey, and the bond `new/1` takes and the one the store is asked to keep
carry an LTK. The link process shows `facts/1`, never the core, in crash reports and
status output, and since a crash's stack trace carries `step/3`'s arguments, it runs
`step/3` so that a raise ends the link with a reason built from `facts/1` alone.
""".

-include("generated/erx_abi.hrl").

-export([new/1, step/3, next_deadline/1, facts/1]).
-export_type([core/0, config/0, resolved/0, input/0, action/0, time/0]).

%% The handler's answer to a write (docs/design-bluetooth.md, "The `ble` facet"), ATT's
%% transaction timeout (Part F, 3.3.3) and the Security Manager Timer (Part H, 3.4).
-define(HANDLER_TIMEOUT_MS, 5000).
-define(ATT_TRANSACTION_MS, 30000).
-define(SMP_TIMEOUT_MS, 30000).
%% Encryption_Enabled's value for encryption on with AES-CCM on LE (HCI 7.7.8).
-define(ENCRYPTION_ON_LE, 16#01).

-type time() :: integer().                    % milliseconds, the link process's monotonic clock
-type key() :: erx_gatt_db:key().
-type ref() :: erx_gatt_server:ref().
-type tag() :: erx_smp_core:tag().
-type subscription() :: erx_gatt_server:subscription().
-type key_level() :: authenticated | unauthenticated.
-doc """
The bond the store resolved the phone's address to (`erx_bt_store:resolve/1`), without
its IRK: a candidate, whose key the link holds from its start and whose subscriptions and
table hash it takes on at its encryption with that key.
""".
-type resolved() :: #{ltk := erx_smp_crypto:value(), level := key_level(), identity := erx_smp_crypto:address(),
                      hash := binary(), subscriptions := #{key() => subscription()}}.
-type config() :: #{table := erx_gatt_db:table(), values := #{key() => binary()},
                    addresses := #{central := erx_smp_crypto:address(), peripheral := erx_smp_crypto:address()},
                    bond := none | resolved(), share := pos_integer(), acl_tx_max := pos_integer()}.
-doc """
What reaches the link, keyed by the owner that sends it: from the controller process, an
ACL packet, completed packets, its `busy`, the controller's reports about encryption as
`erx_hci` decodes them, its report of new connection parameters, which changes nothing
here, and the controller's answer to the link's `ltk_reply`; from the window, its verdict
on a Pairing Request and its withdrawal; from the registry, a handler's answer to a
write, a value a handler set and a notification or indication with the caller's `From`;
from the store, its answer to `keep` and the bond's forgetting; and `expired`, when the
earliest deadline is due.
""".
-type input() :: {hci, {acl, 0..3, binary()} | {completed, pos_integer()} | busy
                       | {le_long_term_key_request, erx_hci:handle(), <<_:64>>, 0..16#FFFF}
                       | {encryption_change, byte(), erx_hci:handle(), byte()}
                       | {encryption_key_refresh_complete, byte(), erx_hci:handle()}
                       | {le_connection_update_complete, byte(), erx_hci:handle()}
                       | {ltk_reply_complete, ok | {failed, byte()}}}
               | {window, {admission, tag(), erx_smp_core:verdict()} | {withdraw, tag()}}
               | {registry, {answer, ref(), term()} | {set, key(), binary()}
                            | {notify, From :: term(), notify | indicate, key(), binary()}}
               | {store, {kept, ok | {error, atom()}} | forgotten}
               | expired.
-doc """
What the link does, in order, each but a notification's answer and the end sent to an
owner: to the controller process, an ACL packet, the answer to its Long Term Key Request
and `taken`; to the registry, a write for its handler, a subscription, a new MTU or the
link's security; to the window, a Pairing Request to admit, the passkey, a failure of the
pairing it admitted, or `keeping` when the bond goes to the store; to the store, the bond
to keep with the link's subscriptions; a notification's answer to its caller; or the
link's end, which disconnects it.
""".
-type action() :: {hci, {send, 0..3, binary()} | {ltk_reply, erx_smp_crypto:value() | none} | taken}
                | {registry, {write, ref(), key(), binary()} | {subscribed, key(), subscription()}
                             | {mtu, pos_integer()} | {security, #{level := erx_gatt_gate:level(), bonded := boolean()}}}
                | {window, {admit, tag(), erx_smp_crypto:address()} | {passkey, tag(), 0..?ERX_SMP_PASSKEY_MAX}
                           | {outcome, tag(), {failed, erx_smp_core:reason()}} | {keeping, tag()}}
                | {store, {keep, tag(), erx_smp_core:bond(), #{key() => subscription()}}}
                | {reply, From :: term(), ok | {error, atom()}}
                | {close, term()}.

-record(core, {
    table :: erx_gatt_db:table(),
    values :: #{key() => binary()},                       % what the handlers last set
    central :: erx_smp_crypto:address(),                  % the phone's address, for the window
    partial = none :: erx_l2cap:partial(),
    bearer :: erx_gatt_server:bearer(),
    key :: none | {erx_smp_crypto:value(), key_level()},  % secret: the LTK
    kept :: boolean(),                                    % the key is a kept bond's
    %% A resolved bond's subscriptions and table hash, held aside until the link is
    %% encrypted with its key; then the hash the bond was last served.
    candidate = none :: none | #{hash := binary(), subscriptions := #{key() => subscription()}},
    served = none :: none | binary(),
    encrypted = false :: boolean(),
    ltk_answer = none :: none | replied | refused,        % the answer to the last request, until a report
    smp :: erx_smp_core:state(),                          % secret: the pairing's private key, passkey, DHKey
    awaiting = none :: none | tag(),                      % the admitted pairing, until its failure or `keeping`
    keeping = false :: boolean(),                         % the store is asked to keep the pairing's bond
    smp_deadline = none :: none | time(),
    write = none :: none | {ref(), time()},              % the write a handler answers
    indication = none :: none | {From :: term(), time()},
    share :: pos_integer(),
    acl_tx_max :: pos_integer(),
    outstanding = 0 :: non_neg_integer(),                 % packets handed over and not completed
    current = [] :: [{0..3, binary()}],                   % the packets left of the frame being handed over
    queue = queue:new() :: queue:queue({erx_l2cap:cid(), binary()}),
    dropped = 0 :: non_neg_integer(),                     % frames on a channel the link does not serve
    refused = 0 :: non_neg_integer(),                     % SMP and signaling answers met by a full queue
    discarded = 0 :: non_neg_integer()                    % write commands past bt_write_queue
}).
-opaque core() :: #core{}.

-doc "A link at its start, holding the key of the bond its address resolved to, if any.".
-spec new(config()) -> core().
new(#{table := Table, values := Values, addresses := #{central := Central} = Addresses, bond := Bond,
      share := Share, acl_tx_max := AclTxMax}) ->
    {Key, Candidate} = case Bond of
                           none -> {none, none};
                           #{ltk := Ltk, level := Level, hash := Hash, subscriptions := Subscriptions} ->
                               {{Ltk, Level}, #{hash => Hash, subscriptions => Subscriptions}}
                       end,
    #core{table = Table, values = Values, central = Central, bearer = erx_gatt_server:new(),
          key = Key, kept = Bond =/= none, candidate = Candidate, smp = erx_smp_core:new(Addresses),
          share = Share, acl_tx_max = AclTxMax}.

-doc "Takes one input at time `Now`; returns the link's actions and the next core.".
-spec step(input(), time(), core()) -> {[action()], core()}.
step(Input, Now, Core) ->
    {Actions, Next} = input(Input, Now, Core),
    {Packets, Handed} = hand_over([], Next),
    case lists:splitwith(fun(Action) -> not is_close(Action) end, Actions) of
        {Before, [Close | _]} -> {Before ++ Packets ++ [Close], Handed};
        {All, []} -> {All ++ Packets, Handed}
    end.

is_close({close, _Reason}) -> true;
is_close(_Action) -> false.

-doc "The earliest deadline the core holds, `infinity` when it holds none.".
-spec next_deadline(core()) -> time() | infinity.
next_deadline(#core{smp_deadline = Smp, write = Write, indication = Indication}) ->
    lists:min([infinity | [D || D <- [Smp, deadline(Write), deadline(Indication)], D =/= none]]).

-doc """
What the link may show about itself: its security, its bearer's MTU, its queue and its
counters. Nothing here is secret, so a crash report or `/proc` may print it whole.
""".
-spec facts(core()) -> map().
facts(#core{} = Core) ->
    #{key => key_level(Core#core.key), encrypted => Core#core.encrypted, bonded => bonded(Core),
      ltk_answer => Core#core.ltk_answer, pairing => Core#core.smp_deadline =/= none,
      mtu => erx_gatt_server:mtu(Core#core.bearer), queued => queue:len(Core#core.queue),
      outstanding => Core#core.outstanding, dropped => Core#core.dropped, refused => Core#core.refused,
      discarded => Core#core.discarded}.

%% ---- the inputs, by role ----

input({hci, Event}, Now, Core) ->
    {Actions, Next} = hci(Event, Now, Core),
    {[{hci, taken} | Actions], Next};
input({window, {admission, Tag, {open, _Mode, _Fresh}}}, Now, #core{key = {_, _}} = Core) ->
    smp({admission, Tag, bonded}, Now, Core);
input({window, {admission, _Tag, _Verdict} = Admission}, Now, Core) ->
    smp(Admission, Now, Core);
input({window, {withdraw, _Tag} = Withdraw}, Now, Core) ->
    smp(Withdraw, Now, Core);
input({registry, {answer, Ref, Answer}}, Now, #core{write = {Ref, _}} = Core) ->
    att(erx_gatt_server:reply(Ref, Answer, server(Core), Core#core.bearer), Now, Core#core{write = none});
input({registry, {answer, _Ref, _Answer}}, _Now, Core) ->
    {[], Core};
input({registry, {set, Key, Value}}, _Now, #core{values = Values} = Core) ->
    {[], Core#core{values = Values#{Key => Value}}};
input({registry, {notify, From, Kind, Key, Value}}, Now, Core) ->
    notify(From, Kind, erx_gatt_server:notify(Kind, Key, Value, server(Core), Core#core.bearer), Now, Core);
input({store, {kept, ok}}, _Now, #core{keeping = true} = Core) ->
    Kept = Core#core{kept = true, keeping = false},
    {security(Kept), Kept};
input({store, {kept, {error, Reason}}}, _Now, #core{keeping = true} = Core) ->
    {[{close, {store, Reason}}], Core#core{keeping = false}};
input({store, forgotten}, _Now, Core) ->
    {[{close, forgotten}], Core};
input(expired, Now, Core) ->
    expire(Now, Core).

%% What the controller process sends.
hci({acl, Boundary, Data}, Now, #core{partial = Partial} = Core) ->
    case erx_l2cap:reassemble(Boundary, Data, Partial) of
        {more, More} -> {[], Core#core{partial = More}};
        {frame, Cid, Payload} -> channel(Cid, Payload, Now, Core#core{partial = none});
        {error, Reason} -> {[{close, {l2cap, Reason}}], Core}
    end;
hci({completed, Count}, _Now, #core{outstanding = Outstanding} = Core) ->
    {[], Core#core{outstanding = Outstanding - Count}};
hci(busy, _Now, Core) ->
    {[{close, busy}], Core};
hci({le_long_term_key_request, _Handle, <<0:64>>, 0}, _Now, #core{key = {Ltk, _}} = Core) ->
    {[{hci, {ltk_reply, Ltk}}], Core#core{ltk_answer = replied}};
hci({le_long_term_key_request, _Handle, _Random, _Ediv}, _Now, Core) ->
    {[{hci, {ltk_reply, none}}], Core#core{ltk_answer = refused}};
%% A Reply the controller answers with a failure counts as none, so the next report about
%% encryption ends the link: HCI 7.8.25's Status says only that the command failed, not
%% whether the controller kept the key, and ending the link is the safe reading.
hci({ltk_reply_complete, {failed, _Status}}, _Now, #core{ltk_answer = replied} = Core) ->
    {[], Core#core{ltk_answer = refused}};
hci({ltk_reply_complete, _Answer}, _Now, Core) ->
    {[], Core};
hci({encryption_change, ?ERX_HCI_STATUS_SUCCESS, _Handle, ?ENCRYPTION_ON_LE}, Now,
    #core{ltk_answer = replied} = Core) ->
    encrypted(Now, Core);
hci({encryption_key_refresh_complete, ?ERX_HCI_STATUS_SUCCESS, _Handle}, Now, #core{ltk_answer = replied} = Core) ->
    encrypted(Now, Core);
hci({encryption_change, _Status, _Handle, _Enabled}, _Now, Core) ->
    {[{close, {encryption, encryption_change}}], Core};
hci({encryption_key_refresh_complete, _Status, _Handle}, _Now, Core) ->
    {[{close, {encryption, encryption_key_refresh_complete}}], Core};
%% The design has the controller process take this report and forward nothing; until
%% erx_bt_hci_core stops forwarding it, the link takes it and changes nothing.
hci({le_connection_update_complete, _Status, _Handle}, _Now, Core) ->
    {[], Core}.

%% The controller encrypted with the link's key: a resolved bond's candidate becomes the
%% link's, the registry tells the handlers the level, and the Security Manager runs its
%% third phase.
encrypted(Now, #core{encrypted = Was} = Core) ->
    {Restored, Proven} = proven(Core#core{encrypted = true, ltk_answer = none}),
    {Smp, Next} = smp(encrypted, Now, Proven),
    Told = case Was of
               true -> [];
               false -> security(Proven)
           end,
    {Told ++ Restored ++ Smp, Next}.

%% A resolved bond's subscriptions and table hash, taken on at the first encryption with
%% its key: the subscriptions the table still declares go into the bearer, and the
%% registry hears each.
proven(#core{candidate = none} = Core) ->
    {[], Core};
proven(#core{candidate = #{hash := Hash, subscriptions := Kept}, table = Table, bearer = Bearer} = Core) ->
    {Restored, Next} = erx_gatt_server:restore(Kept, Table, Bearer),
    {[{registry, {subscribed, Key, Kind}} || Key := Kind <- maps:iterator(Restored, ordered)],
     Core#core{candidate = none, served = Hash, bearer = Next}}.

%% The deadlines that have passed at `Now`, the Security Manager's first.
expire(Now, Core0) ->
    {Smp, Core1} = case due(Core0#core.smp_deadline, Now) of
                       true -> smp(timeout, Now, Core0#core{smp_deadline = none});
                       false -> {[], Core0}
                   end,
    {Indication, Core2} = case Core1#core.indication of
                              {From, Deadline} when Deadline =< Now ->
                                  {[{reply, From, {error, timeout}}, {close, att_timeout}], Core1#core{indication = none}};
                              _ -> {[], Core1}
                          end,
    {Write, Core3} = case Core2#core.write of
                         {Ref, Deadline2} when Deadline2 =< Now ->
                             att(erx_gatt_server:reply(Ref, timeout, server(Core2), Core2#core.bearer), Now,
                                 Core2#core{write = none});
                         _ -> {[], Core2}
                     end,
    {Smp ++ Indication ++ Write, Core3}.

due(none, _Now) -> false;
due(Deadline, Now) -> Deadline =< Now.

deadline(none) -> none;
deadline({_, Deadline}) -> Deadline.

%% ---- the channels ----

channel(?ERX_L2CAP_CID_ATT, Pdu, Now, Core) ->
    att(erx_gatt_server:request(Pdu, server(Core), Core#core.bearer), Now, Core);
channel(?ERX_L2CAP_CID_SMP, Pdu, Now, Core) ->
    smp({pdu, erx_smp:decode(Pdu)}, Now, Core);
channel(?ERX_L2CAP_CID_LE_SIGNALING, Frame, _Now, Core) ->
    case erx_l2cap:signal(Frame) of
        {reply, Reply} -> queue(?ERX_L2CAP_CID_LE_SIGNALING, Reply, droppable, Core);
        drop -> {[], Core}
    end;
channel(_Cid, _Payload, _Now, #core{dropped = Dropped} = Core) ->
    {[], Core#core{dropped = Dropped + 1}}.

%% ---- the ATT bearer ----

%% What the ATT server is shown: the table, the handlers' values and the link's security.
server(#core{table = Table, values = Values, key = Key, encrypted = Encrypted}) ->
    #{table => Table, values => Values, security => #{key => gate_key(Key), encrypted => Encrypted}}.

att({Actions, Bearer}, Now, Core) ->
    each(fun att_action/3, Actions, Now, Core#core{bearer = Bearer}).

att_action({send, Pdu}, _Now, Core) ->
    queue(?ERX_L2CAP_CID_ATT, Pdu, always, Core);
att_action({write, Ref, Key, Value}, Now, Core) ->
    {[{registry, {write, Ref, Key, Value}}], Core#core{write = {Ref, Now + ?HANDLER_TIMEOUT_MS}}};
att_action({subscribed, Key, Subscription}, _Now, Core) ->
    {[{registry, {subscribed, Key, Subscription}}], Core};
att_action({mtu, Mtu}, _Now, Core) ->
    {[{registry, {mtu, Mtu}}], Core};
att_action({confirmed, _Key}, _Now, #core{indication = {From, _}} = Core) ->
    {[{reply, From, ok}], Core#core{indication = none}};
att_action({confirmed, _Key}, _Now, Core) ->
    {[], Core};
att_action(discarded, _Now, #core{discarded = Discarded} = Core) ->
    {[], Core#core{discarded = Discarded + 1}};
att_action({close, Reason}, _Now, Core) ->
    {[{close, {att, Reason}}], Core}.

%% A notification is answered once queued, or `busy` at a full queue; an indication once
%% the phone confirms it, within ATT's transaction timeout.
notify(From, _Kind, {error, Reason}, _Now, Core) ->
    {[{reply, From, {error, Reason}}], Core};
notify(From, notify, {ok, Pdu, Bearer}, _Now, #core{queue = Queue} = Core) ->
    case full(Queue) of
        true -> {[{reply, From, {error, busy}}], Core};
        false ->
            {Queued, Next} = queue(?ERX_L2CAP_CID_ATT, Pdu, always, Core#core{bearer = Bearer}),
            {[{reply, From, ok} | Queued], Next}
    end;
notify(From, indicate, {ok, Pdu, Bearer}, Now, Core) ->
    queue(?ERX_L2CAP_CID_ATT, Pdu, always, Core#core{bearer = Bearer, indication = {From, Now + ?ATT_TRANSACTION_MS}}).

%% ---- the Security Manager ----

smp(Input, Now, #core{smp = Smp} = Core) ->
    {Actions, Next} = erx_smp_core:step(Input, Smp),
    each(fun smp_action/3, Actions, Now, Core#core{smp = Next}).

smp_action({admit, Tag}, _Now, #core{central = Central} = Core) ->
    {[{window, {admit, Tag, Central}}], Core#core{awaiting = Tag}};
smp_action(timer, Now, Core) ->
    {[], Core#core{smp_deadline = Now + ?SMP_TIMEOUT_MS}};
smp_action(timer_stop, _Now, Core) ->
    {[], Core#core{smp_deadline = none}};
smp_action({send, Pdu}, _Now, Core) ->
    queue(?ERX_L2CAP_CID_SMP, erx_smp:encode(Pdu), droppable, Core);
smp_action({passkey, Passkey}, _Now, #core{awaiting = Tag} = Core) ->
    {[{window, {passkey, Tag, Passkey}}], Core};
smp_action({key, Ltk, Level}, _Now, Core) ->
    {[], set_key(Ltk, Level, Core)};
%% The ordering point: from this step the pairing is the store's, so the window hears
%% `keeping` and no failure of the link's after it.
smp_action({bonded, Bond}, _Now, #core{awaiting = Tag, bearer = Bearer} = Core) when Tag =/= none ->
    {[{store, {keep, Tag, Bond, erx_gatt_server:subscriptions(Bearer)}}, {window, {keeping, Tag}}],
     Core#core{awaiting = none, keeping = true}};
%% A failure reaches the window only for the pairing it admitted, before `keeping`; the
%% refusal of a Pairing Request after the bond, in the Security Manager's `done`, is not
%% that pairing's outcome.
smp_action({failed, Reason}, _Now, #core{awaiting = Tag} = Core) when Tag =/= none ->
    {[{window, {outcome, Tag, {failed, Reason}}}], Core#core{awaiting = none}};
smp_action({failed, _Reason}, _Now, Core) ->
    {[], Core};
smp_action(end_link, _Now, Core) ->
    {[{close, pairing}], Core}.

%% A link takes a key only when it has none, so a key, once a link has one, never changes.
set_key(Ltk, Level, #core{key = none} = Core) ->
    Core#core{key = {Ltk, Level}}.

%% ---- security, as the gate and the registry see it ----

gate_key(none) -> none;
gate_key({_Ltk, unauthenticated}) -> encrypted;
gate_key({_Ltk, authenticated}) -> authenticated.

key_level(none) -> none;
key_level({_Ltk, Level}) -> Level.

%% A link is its bond's once it is encrypted with a kept bond's key.
bonded(#core{kept = Kept, encrypted = Encrypted}) -> Kept andalso Encrypted.

%% The level the link reaches, `open` until it is encrypted and then its key's.
security(#core{encrypted = false} = Core) ->
    [{registry, {security, #{level => open, bonded => bonded(Core)}}}];
security(#core{key = Key} = Core) ->
    [{registry, {security, #{level => gate_key(Key), bonded => bonded(Core)}}}].

%% ---- sending ----

%% Queues a frame: `droppable` for SMP's and signaling's answers, which a full queue
%% refuses and counts; `always` for ATT's responses, its one indication and a notification
%% `notify/5` found room for. An honest phone sends its next request only after it has
%% received the last response, which is then off the queue, so past bt_notify_queue and
%% the two ATT may add an `always` frame means the phone did not wait (Part F, 3.3.2),
%% and ends the link.
queue(Cid, Payload, droppable, #core{queue = Queue, refused = Refused} = Core) ->
    case full(Queue) of
        true -> {[], Core#core{refused = Refused + 1}};
        false -> {[], Core#core{queue = queue:in({Cid, Payload}, Queue)}}
    end;
queue(Cid, Payload, always, #core{queue = Queue} = Core) ->
    case queue:len(Queue) >= ?ERX_BT_NOTIFY_QUEUE + 2 of
        true -> {[{close, queue_overflow}], Core};
        false -> {[], Core#core{queue = queue:in({Cid, Payload}, Queue)}}
    end.

full(Queue) -> queue:len(Queue) >= ?ERX_BT_NOTIFY_QUEUE.

%% Hands packets over while the outstanding packets are below the share: the rest of the
%% frame being handed over, then the next frame's.
hand_over(Acc, #core{outstanding = Outstanding, share = Share} = Core) when Outstanding >= Share ->
    {lists:reverse(Acc), Core};
hand_over(Acc, #core{current = [{Boundary, Data} | Rest], outstanding = Outstanding} = Core) ->
    hand_over([{hci, {send, Boundary, Data}} | Acc], Core#core{current = Rest, outstanding = Outstanding + 1});
hand_over(Acc, #core{current = [], queue = Queue, acl_tx_max = AclTxMax} = Core) ->
    case queue:out(Queue) of
        {{value, {Cid, Payload}}, Rest} ->
            hand_over(Acc, Core#core{current = erx_l2cap:fragments(Cid, Payload, AclTxMax), queue = Rest});
        {empty, _} ->
            {lists:reverse(Acc), Core}
    end.

%% Runs `Fun` over a sub-core's actions in order, gathering the link's actions.
each(Fun, Actions, Now, Core) ->
    lists:foldl(fun(Action, {Acc, C}) ->
                        {More, Next} = Fun(Action, Now, C),
                        {Acc ++ More, Next}
                end, {[], Core}, Actions).
