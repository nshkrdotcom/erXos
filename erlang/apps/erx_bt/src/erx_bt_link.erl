%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_link).
-moduledoc """
A link process, one for each connection the core names (docs/design-bluetooth.md, "The
controller process's effects" and "Commands and data credits"). The controller process
starts it as a temporary child of `erx_bt_link_sup` with the link's name, its `Conn`, its
`Info` (the peer's address, `acl_tx_max` and its share of the controller's buffers) and the
controller process's pid; it ends at `link_down`, and any end of it is its disconnect.

It hands a packet over, as `{erx_bt_link, Name, {send, Boundary, Data}}` to the controller
process, only while its packets outstanding are below its share, and counts them back from
the `{completed, Count}` the core passes it; what waits for a credit waits in its own queue,
at most `bt_notify_queue`, past which `send/3` answers `{error, busy}`. A `busy` from the
core means the link miscounted: it ends, and its end disconnects it.

It has no channels yet: every ACL packet the controller sends it is dropped and counted,
and the fixed channels, which hand packets to `send/3`, come with the GATT server (stage 2).
""".
-behaviour(gen_server).

-include("generated/erx_abi.hrl").

-export([start_link/1, send/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-record(link, {
    name :: erx_bt_hci_core:link(),
    conn :: reference(),
    hci :: pid(),
    share :: pos_integer(),
    outstanding = 0 :: non_neg_integer(),      % packets handed over and not yet completed
    queue = queue:new() :: queue:queue({0..3, binary()}),
    dropped = 0 :: non_neg_integer()           % ACL packets dropped, no channel taking them
}).

-doc "Starts a link; `erx_bt_link_sup`'s child start.".
-spec start_link(#{name := erx_bt_hci_core:link(), conn := reference(), info := map(), hci := pid()}) ->
          gen_server:start_ret().
start_link(Start) ->
    gen_server:start_link(?MODULE, Start, []).

-doc "Queues one ACL packet to the peer, `ok`, or `{error, busy}` when the queue is full.".
-spec send(pid(), 0..3, binary()) -> ok | {error, busy}.
send(Link, Boundary, Data) ->
    gen_server:call(Link, {send, Boundary, Data}).

init(#{name := Name, conn := Conn, info := #{share := Share}, hci := Hci}) ->
    {ok, #link{name = Name, conn = Conn, hci = Hci, share = Share}}.

handle_call({send, Boundary, Data}, _From, #link{queue = Queue} = Link) ->
    case queue:len(Queue) >= ?ERX_BT_NOTIFY_QUEUE of
        true -> {reply, {error, busy}, Link};
        false -> {reply, ok, hand_over(Link#link{queue = queue:in({Boundary, Data}, Queue)})}
    end.

handle_info({erx_bt_hci, {completed, Count}}, #link{outstanding = Outstanding} = Link) ->
    {noreply, hand_over(Link#link{outstanding = Outstanding - Count})};
handle_info({erx_bt_hci, {acl, _Boundary, _Data}}, #link{dropped = Dropped} = Link) ->
    {noreply, Link#link{dropped = Dropped + 1}};
handle_info({erx_bt_hci, busy}, Link) ->
    {stop, busy, Link};
handle_info(_Message, Link) ->
    {noreply, Link}.

handle_cast(_Message, Link) ->
    {noreply, Link}.

%% A crash report shows how many packets wait, never their bytes.
format_status(#{state := #link{queue = Queue} = Link} = Status) ->
    Status#{state := Link#link{queue = {packets, queue:len(Queue)}}};
format_status(Status) ->
    Status.

%% Hands the queue's packets over while the outstanding packets are below the share.
hand_over(#link{outstanding = Outstanding, share = Share, queue = Queue, hci = Hci, name = Name} = Link)
  when Outstanding < Share ->
    case queue:out(Queue) of
        {{value, {Boundary, Data}}, Rest} ->
            Hci ! {?MODULE, Name, {send, Boundary, Data}},
            hand_over(Link#link{outstanding = Outstanding + 1, queue = Rest});
        {empty, _} ->
            Link
    end;
hand_over(Link) ->
    Link.
