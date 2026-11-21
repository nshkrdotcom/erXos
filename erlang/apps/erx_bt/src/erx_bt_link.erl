%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_link).
-moduledoc """
A link process, one for each connection the controller's core names: the effects around
`erx_bt_link_core` (docs/design-bluetooth.md, "One owner, one step" and "The link's
messages"). The controller process starts it as a temporary child of `erx_bt_link_sup` with
the link's name, its `Conn`, its `Info` (the peer's address and type from LE Connection
Complete, `acl_tx_max` and its share of the controller's buffers) and the controller
process's pid; it ends at `link_down`, and any end of it is its disconnect.

- **Configuration.** At its start it builds the core's configuration: the phone's address
  from `Info`, its own from `erx_bt_store:address/0` (the static random identity address
  the controller advertises with), the share and `acl_tx_max` from `Info`, and the table,
  the handlers' values, whether pairing is enabled and the bond the phone's address
  resolved to from the start's `domain`. The registry's and the store's calls that answer
  these are not designed yet, so the controller process passes no `domain` and the link
  takes what the domain has without them: the GAP and GATT services alone, no values, no
  pairing and no bond (TODO.md, Bluetooth).
- **Inputs.** Each message is one input of the core, stepped at the monotonic clock:
  `{erx_bt_hci, Input}` from the controller process, and `{Owner, Input}` from the window
  (`erx_bt_fs`), the registry (`erx_gatt_srv`) and the store (`erx_bt_store`), each owner's
  inputs alone. One wake-up timer, at `next_deadline/1`, steps `expired`; the core changes
  nothing before its deadline, so a stale wake-up costs one look.
- **Actions.** A packet goes to the controller process as `{erx_bt_link, Name, {send,
  Boundary, Data}}` and a Long Term Key answer as `{erx_bt_link, Name, {ltk_reply, _}}`;
  what goes to the window, the registry and the store is sent to its registered name as
  `{erx_bt_link, Alias, Message}`, where `Alias` is the link's alias, to which the owner
  answers and which dies with the link; a notification's answer goes to its `From`; a
  `close` ends the process with `{shutdown, Reason}`.
- **Secrets.** The core holds the LTK and, while pairing, the private key, passkey and
  DHKey, and the window's verdict carries the fresh values. `format_status/1` shows the
  core's `facts/1` and each message as its owner and kind alone, and a raise in `step/3`,
  whose stack trace carries the core, ends the process with a reason built from `facts/1`
  alone. `sys:get_state/1` and sys tracing show the raw state and messages to whoever in
  the domain asks for them.
- **A disconnection mid-pairing.** The link remembers the pairing it asked the window to
  admit until it tells the window that pairing's outcome. If it ends before, however it
  ends short of a kill, it tells the window `{outcome, Tag, {failed, disconnected}}`, which
  counts it for the pairing wait (docs/design-bluetooth.md, "The pairing window").
""".
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

-record(link, {
    name :: erx_bt_hci_core:link(),
    conn :: reference(),
    hci :: pid(),
    alias :: reference(),                      % the window, the registry and the store answer here
    core :: erx_bt_link_core:core(),           % secret: never shown, see format_status/1
    timer = none :: none | {reference(), erx_bt_link_core:time()},
    awaiting = none :: none | erx_smp_core:tag()  % the pairing the window awaits an outcome for
}).

-doc """
Starts a link; `erx_bt_link_sup`'s child start. `domain`, when given, holds the table,
the values, the pairing flag and the resolved bond in place of what the domain has
without its registry and store.
""".
-spec start_link(#{name := erx_bt_hci_core:link(), conn := reference(), info := map(), hci := pid(),
                   domain => #{table := erx_gatt_db:table(), values := map(), pairing := boolean(),
                               bond := none | map()}}) ->
          gen_server:start_ret().
start_link(Start) ->
    gen_server:start_link(?MODULE, Start, []).

init(#{name := Name, conn := Conn, info := Info, hci := Hci} = Start) ->
    %% Trapping exits runs terminate/2 at the supervisor's shutdown, so a link_down
    %% mid-pairing reaches the window.
    process_flag(trap_exit, true),
    Domain = maps:get(domain, Start, without_registry()),
    Core = erx_bt_link_core:new(config(Info, Domain)),
    {ok, wake_up(#link{name = Name, conn = Conn, hci = Hci, alias = alias(), core = Core})}.

%% What the core is configured with: the phone's address and the link's own, the share and
%% the packet length from the controller, and the domain's parts.
config(#{peer_type := PeerType, peer := Peer, share := Share, acl_tx_max := AclTxMax}, Domain) ->
    Domain#{addresses => #{central => {address_type(PeerType), Peer}, peripheral => {random, erx_bt_store:address()}},
            share => Share, acl_tx_max => AclTxMax}.

%% Peer_Address_Type of LE Connection Complete (HCI 7.7.65.1): the controller resolves no
%% address for erXos, so only a public or a random device address is reported.
address_type(16#00) -> public;
address_type(16#01) -> random.

%% What the domain has before its registry and store answer a link: no services but GAP's
%% and GATT's, no values, no pairing and no bond.
without_registry() ->
    #{table => erx_gatt_db:build([]), values => #{}, pairing => false, bond => none}.

handle_info({timeout, Timer, wake}, #link{timer = {Timer, _Deadline}} = Link) ->
    step(expired, Link#link{timer = none});
handle_info({Owner, Input}, Link) when is_atom(Owner) ->
    case accepts(Owner, kind(Input)) of
        true -> step(Input, Link);
        false -> {noreply, Link}
    end;
handle_info(_Message, Link) ->
    {noreply, Link}.

%% Which owner sends which of the core's inputs (docs/design-bluetooth.md, "The link's
%% messages").
accepts(erx_bt_hci, Kind) ->
    lists:member(Kind, [acl, completed, busy, le_long_term_key_request, encryption_change,
                        encryption_key_refresh_complete, le_connection_update_complete, ltk_reply_complete]);
accepts(erx_bt_fs, Kind) -> lists:member(Kind, [admission, withdraw]);
accepts(erx_gatt_srv, Kind) -> lists:member(Kind, [answer, set, notify]);
accepts(erx_bt_store, Kind) -> Kind =:= kept;
accepts(_Owner, _Kind) -> false.

handle_call(_Request, _From, Link) ->
    {reply, {error, unsupported}, Link}.

handle_cast(_Message, Link) ->
    {noreply, Link}.

%% A link that ends while the window awaits its pairing's outcome tells the window.
terminate(_Reason, #link{awaiting = none}) ->
    ok;
terminate(_Reason, #link{awaiting = Tag} = Link) ->
    tell(erx_bt_fs, {outcome, Tag, {failed, disconnected}}, Link).

%% A crash report and sys:get_status/1 show the core's facts, never the core, and a
%% message as its owner and kind alone: the window's verdict carries the fresh private key
%% and passkey, and a peer's packet its data. The log of sys events holds messages too,
%% so it shows empty: gen_server's report formats a list there.
format_status(#{state := #link{name = Name, conn = Conn, core = Core}} = Status) ->
    Shown = Status#{state := #{name => Name, conn => Conn, core => erx_bt_link_core:facts(Core)}},
    hide_log(hide_message(Shown));
format_status(Status) ->
    Status.

hide_message(#{message := {Owner, Input}} = Status) when is_atom(Owner) -> Status#{message := {Owner, kind(Input)}};
hide_message(#{message := _} = Status) -> Status#{message := message};
hide_message(Status) -> Status.

hide_log(#{log := [_ | _]} = Status) -> Status#{log := []};
hide_log(Status) -> Status.

kind(Input) when is_tuple(Input), tuple_size(Input) > 0, is_atom(element(1, Input)) -> element(1, Input);
kind(Input) when is_atom(Input) -> Input;
kind(_Input) -> input.

%% Steps one input at the clock and performs its actions in order; a close, always last,
%% ends the process. A raise ends it with the facts of the core before the input, never
%% the raise's reason or stack trace, which carry the core.
step(Input, #link{core = Core} = Link) ->
    try erx_bt_link_core:step(Input, erlang:monotonic_time(millisecond), Core) of
        {Actions, Next} ->
            case erx_actions:perform(lists:map(fun close_to_stop/1, Actions), fun perform/2, Link#link{core = Next}) of
                {continue, Performed} -> {noreply, wake_up(Performed)};
                {stop, Reason, Performed} -> {stop, Reason, Performed}
            end
    catch
        Class:_Raised ->
            {stop, {step_raised, Class, erx_bt_link_core:facts(Core)}, Link}
    end.

%% A close is an end the core decided, often at a peer's misstep, not a crash: it ends the
%% process with a shutdown, so a peer that loses its link costs no error report
%% (docs/design-bluetooth.md, "What a radio peer can make the domain spend").
close_to_stop({close, Reason}) -> {stop, {shutdown, Reason}};
close_to_stop(Action) -> Action.

perform({acl, Boundary, Data},#link{hci = Hci, name = Name} = Link) ->
    Hci ! {?MODULE, Name, {send, Boundary, Data}},
    Link;
perform({ltk_reply, _Key} = Reply, #link{hci = Hci, name = Name} = Link) ->
    Hci ! {?MODULE, Name, Reply},
    Link;
perform({reply, From, Answer}, Link) ->
    gen_server:reply(From, Answer),
    Link;
perform({window, {admit, Tag, _Address} = Message}, Link) ->
    tell(erx_bt_fs, Message, Link),
    Link#link{awaiting = Tag};
perform({window, {outcome, Tag, _Outcome} = Message}, #link{awaiting = Tag} = Link) ->
    tell(erx_bt_fs, Message, Link),
    Link#link{awaiting = none};
perform({window, Message}, Link) ->
    tell(erx_bt_fs, Message, Link),
    Link;
perform({registry, Message}, Link) ->
    tell(erx_gatt_srv, Message, Link),
    Link;
perform({store, Message}, Link) ->
    tell(erx_bt_store, Message, Link),
    Link.

%% Sends an owner a message by its registered name; one that is not running drops it, as
%% a message to an ended process is dropped.
tell(Name, Message, #link{alias = Alias}) ->
    {Name, node()} ! {?MODULE, Alias, Message},
    ok.

%% One wake-up timer, at the core's earliest deadline.
wake_up(#link{core = Core, timer = Timer} = Link) ->
    case {erx_bt_link_core:next_deadline(Core), Timer} of
        {Deadline, {_Ref, Deadline}} ->
            Link;
        {Deadline, _} ->
            cancel(Timer),
            Link#link{timer = arm(Deadline)}
    end.

arm(infinity) -> none;
arm(Deadline) -> {erlang:start_timer(Deadline, self(), wake, [{abs, true}]), Deadline}.

cancel(none) -> ok;
cancel({Ref, _Deadline}) -> _ = erlang:cancel_timer(Ref), ok.
