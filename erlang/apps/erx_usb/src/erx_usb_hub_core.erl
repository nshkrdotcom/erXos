%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_hub_core).
-moduledoc """
A hub function's status pipe and the hub words the bus core reads
(docs/design-usb.md, "Hubs" and "Every port is a hub port").

step/2 is the hub function's machine. A hub function keeps at most one
status-change transfer posted on its interrupt endpoint and never has a
transfer posted while the bus process holds a bitmap of its own: it
reports `{changed, Set}`, and posts its next transfer only on `handled`,
the bus process's answer once every port the set named is dealt with. So
one bitmap per hub is in flight however fast the hub reports. Its first
report, at start, names the hub and every port, so a new instance, the
first or one restarted after a failure, has the bus core read every
port's status, and the change bits the hub latched while no transfer was
posted are not lost. A report that names nothing posts the next transfer
at once. A failed transfer ends the function (`{stop, {transfer, Reason}}`),
the one recovery a hub's pipe has: the bus resets the pipe and starts the
function again, within its restarts.

bitmap/2 decodes a status-change report as the design states it: bit 0
the hub itself, bit n port n, bit n in byte n div 8 at position n rem 8;
bits above the port count, and bytes past transfer_length/1, (Ports + 1)
bits rounded up to bytes, are ignored. A report shorter than that names
every port and the hub, so the bus core reads them all, as FreeBSD's
`uhub_intr_callback` reads none of the bitmap (sys/dev/usb/usb_hub.c:185-218)
and `uhub_explore` reads every port (usb_hub.c:993-1090). The bit layout rests on the
design and is not checked against a source.

hub_status/1 decodes GET_STATUS's answer for a hub, its status and change
words (`usb_hub_status`, usb.h:698-699); port_status/2 for a hub's port
(`usb_port_status` and `usb_port_change`, usb.h:706-741). An external
hub's port takes its speed from its status by the hub's own speed, as
FreeBSD's `uhub_reattach_port` does (sys/dev/usb/usb_hub.c:738-752,
release/15.1.0, 95719d8a): on a high-speed hub the high-speed bit, then
the low-speed bit, else full speed; on a full-speed hub the low-speed bit,
else full speed. A root port's words are the ones the controller process
fills from the port's PORTSC, and its speed is the PORTSC speed ID
(`xhci_speed` in `abi/formats/xhci.txt`); an ID outside that set gives
the speed `unsupported`, with the status and changes still decoded, so
the bus core can clear the port's changes and see it disconnect while
it refuses the device on it.

Every word and report comes from a device and is untrusted: each status
decoder takes exactly the bytes its format has, ignores bits it does not
know and answers `{error, Reason}` instead of raising; bitmap/2 cannot
fail, since every report names a bounded set; none creates an atom.
""".

-export([new/1, transfer_length/1, step/2, bitmap/2, hub_status/1, port_status/2]).

-export_type([state/0, event/0, action/0, change_set/0, port_state/0, hub_status/0, parent/0, reason/0]).

-include("generated/erx_abi.hrl").

-type ports() :: 1..?ERX_USB_HUB_PORTS_MAX.

-doc "What a status-change report names, an ordset: each port's number, then `hub` for the hub itself.".
-type change_set() :: ordsets:ordset(hub | ports()).

-type event() :: start | handled | {transfer, {ok, binary()} | {error, term()}}.

-doc "Post one status transfer of Length bytes; report a change set to the bus process; end the function.".
-type action() :: {post, pos_integer()} | {changed, change_set()} | {stop, {transfer, term()}}.

-opaque state() :: #{ports := ports(), phase := idle | posted | reporting | stopped}.

-doc "Whose port a status answer is: an external hub's, by the hub's speed, or a root port's, by its PORTSC speed ID.".
-type parent() :: {hub, full | high} | {root, byte()}.

-type port_change() :: connection | enabled | suspend | over_current | reset.

-doc "A port's status, the changes it reports, and the speed of a device on it.".
-type port_state() :: #{connected := boolean(), enabled := boolean(), suspended := boolean(),
                  over_current := boolean(), reset := boolean(), powered := boolean(),
                  speed := erx_usb_claim:speed() | unsupported, changes := ordsets:ordset(port_change())}.

-type hub_status() :: #{local_power := boolean(), over_current := boolean(),
                        changes := ordsets:ordset(local_power | over_current)}.

-type reason() :: malformed_status.

-doc "A hub function's machine for a hub of Ports ports, as its hub descriptor gives them.".
-spec new(ports()) -> state().
new(Ports) when is_integer(Ports), Ports >= 1, Ports =< ?ERX_USB_HUB_PORTS_MAX ->
    #{ports => Ports, phase => idle}.

-doc "The bytes a status-change report of a hub of Ports ports holds at least: one bit for the hub and one a port.".
-spec transfer_length(ports()) -> pos_integer().
transfer_length(Ports) -> Ports div 8 + 1.

-doc "The next state on Event and the actions the hub function performs.".
-spec step(event(), state()) -> {state(), [action()]}.
step(start, State = #{ports := Ports, phase := idle}) ->
    {State#{phase := reporting}, [{changed, lists:seq(1, Ports) ++ [hub]}]};
step(handled, State = #{phase := reporting}) ->
    post(State);
step({transfer, {ok, Bytes}}, State = #{ports := Ports, phase := posted}) ->
    case bitmap(Ports, Bytes) of
        [] -> post(State);
        Set -> {State#{phase := reporting}, [{changed, Set}]}
    end;
step({transfer, {error, Reason}}, State = #{phase := posted}) ->
    {State#{phase := stopped}, [{stop, {transfer, Reason}}]}.

post(State = #{ports := Ports}) ->
    {State#{phase := posted}, [{post, transfer_length(Ports)}]}.

-doc "The hub and ports a status-change report of a hub of Ports ports names; a short report names them all.".
-spec bitmap(ports(), binary()) -> change_set().
bitmap(Ports, Bytes) ->
    Length = transfer_length(Ports),
    case Bytes of
        <<Head:Length/binary, _/binary>> ->
            Bits = binary:decode_unsigned(Head, little),
            [Port || Port <- lists:seq(1, Ports), Bits band (1 bsl Port) =/= 0] ++
                [hub || Bits band 1 =/= 0];
        _Short ->
            lists:seq(1, Ports) ++ [hub]
    end.

-doc "A hub's own status and changes, from GET_STATUS's 4-byte answer.".
-spec hub_status(binary()) -> {ok, hub_status()} | {error, malformed_status}.
hub_status(<<Status:16/little, Change:16/little>>) ->
    {ok, #{local_power => has(Status, ?ERX_USB_HUB_STATUS_LOCAL_POWER),
           over_current => has(Status, ?ERX_USB_HUB_STATUS_OVER_CURRENT),
           changes => named(Change, [{local_power, ?ERX_USB_HUB_STATUS_LOCAL_POWER},
                                     {over_current, ?ERX_USB_HUB_STATUS_OVER_CURRENT}])}};
hub_status(_Bytes) ->
    {error, malformed_status}.

-doc "A port's status, changes and speed, from its 4-byte status and change words.".
-spec port_status(binary(), parent()) -> {ok, port_state()} | {error, malformed_status}.
port_status(<<Status:16/little, Change:16/little>>, Parent) ->
    {ok, #{connected => has(Status, ?ERX_USB_PORT_STATUS_CONNECTION),
           enabled => has(Status, ?ERX_USB_PORT_STATUS_ENABLED),
           suspended => has(Status, ?ERX_USB_PORT_STATUS_SUSPEND),
           over_current => has(Status, ?ERX_USB_PORT_STATUS_OVER_CURRENT),
           reset => has(Status, ?ERX_USB_PORT_STATUS_RESET),
           powered => has(Status, ?ERX_USB_PORT_STATUS_POWER),
           speed => speed(Status, Parent),
           changes => named(Change, [{connection, ?ERX_USB_PORT_CHANGE_CONNECTION},
                                     {enabled, ?ERX_USB_PORT_CHANGE_ENABLED},
                                     {suspend, ?ERX_USB_PORT_CHANGE_SUSPEND},
                                     {over_current, ?ERX_USB_PORT_CHANGE_OVER_CURRENT},
                                     {reset, ?ERX_USB_PORT_CHANGE_RESET}])}};
port_status(_Bytes, _Parent) ->
    {error, malformed_status}.

speed(Status, {hub, high}) ->
    if
        Status band ?ERX_USB_PORT_STATUS_HIGH_SPEED =/= 0 -> high;
        Status band ?ERX_USB_PORT_STATUS_LOW_SPEED =/= 0 -> low;
        true -> full
    end;
speed(Status, {hub, full}) ->
    if
        Status band ?ERX_USB_PORT_STATUS_LOW_SPEED =/= 0 -> low;
        true -> full
    end;
speed(_Status, {root, ?ERX_XHCI_SPEED_LOW}) -> low;
speed(_Status, {root, ?ERX_XHCI_SPEED_FULL}) -> full;
speed(_Status, {root, ?ERX_XHCI_SPEED_HIGH}) -> high;
speed(_Status, {root, ?ERX_XHCI_SPEED_SUPER}) -> super;
speed(_Status, {root, _Id}) -> unsupported.

%% The names of the masks Word has, as an ordset.
named(Word, Masks) -> ordsets:from_list([Name || {Name, Mask} <- Masks, has(Word, Mask)]).

has(Word, Mask) -> Word band Mask =/= 0.
