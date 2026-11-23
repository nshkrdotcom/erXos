%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_genet_core).
-moduledoc """
The Raspberry Pi 4 Ethernet controller's transport, erx_genet, as pure decisions
(docs/design-device-dma.md, "The register ring (GENET)"; docs/design-network-stack.md,
"The driver"): the register sequences it writes, the address it uses, how long it
retries `negotiate/2`, and what it makes of each receive completion and each frame to
send. Nothing here touches the device; erx_genet carries each step out through the
device NIF, which reaches every register and field by its name in the device's SVD
source (hw/svd/genet/genet.svd), so no step packs a bit by hand.

The sequences follow FreeBSD 975e3605ebb1, `sys/arm64/broadcom/genet/if_genet.c`, except
`reset/0`'s reset, which is the UEFI firmware's driver's (item 2):

1. `reset/0` first stops the controller, since a restart may find it receiving as its
   predecessor left it: the MAC's receive and transmit off and a full frame's time, as
   the MAC stops only at a frame's end, then both DMA engines stopped and the stop confirmed by the
   device NIF without the install (`dma_stop`, erx_device:stop_dma/1), so that no reset
   of item 2 lands while an engine runs. (The MAC's software reset hold of items 5 and 6
   comes and goes with the engines running, as the other published driver's release
   does; that no owned DMA register changes across it is the board pass's to confirm,
   docs/design-device-dma.md, "Register ownership".) This follows the other published driver's
   interface stop (the GENET facts record, docs/research-genet-bcm2711.md, "Stopping the
   DMA and confirming it stopped", steps 2, 3 and 5) with two differences: the hardware
   filter block, which that driver disables in step 2, is not written; and the NIF writes
   both directions' stops, transmit first, before it reads either idle report, its order
   for every GENET reset (docs/design-device-dma.md, "Install and reset"), where that
   driver confirms transmit's stop before it writes receive's and waits 10 to 20 ms
   between them. Neither step is FreeBSD's: FreeBSD turns receive off inside
   `gen_reset`, by writing the command register 0 after the receive buffer's reset
   (`if_genet.c:504, 873`), and again in `gen_disable` (`:554-556, 874`), never before
   that reset, and stops the DMA after it, unconfirmed (`:285-288, 873-875`).
2. Then the rest of `reset/0`. First both status blocks and the receive checksum check
   off, the values the UEFI firmware's driver runs with after the Pi 4's boot loader,
   which leaves all three 0 and which that driver never writes. Then that driver's reset,
   `GenetReset` (edk2-platforms 4db2845d1442,
   `Silicon/Broadcom/Drivers/Net/BcmGenetDxe/GenetUtil.c:300-335`), which its
   initialization runs first (`SimpleNetwork.c:147`), write for write: FreeBSD's
   `gen_reset` (`if_genet.c:488-514`) with the largest frame and two buffer settings
   after it:
   * pulse the receive buffer's reset, 10 us each side, write its flush control 0, and
     write the MAC's command register 0;
   * hold the MAC in software reset with local loopback, one write, for 10 us, then
     write the command register 0, which releases it with CRC forward clear, so no frame
     check sequence is counted in a receive length;
   * clear the MIB counters, one write and then 0, and set the largest frame to 1,536
     bytes;
   * the receive buffer's 2-byte alignment on and the size control
     (`RBUF_TBUF_SIZE_CTRL`) 1, the very last write.
   No flush: neither that driver's initialization nor FreeBSD's flushes the transmit
   path or the receive buffer. That driver's stop does flush the transmit path, between
   its DMA stop and turning transmit off (`GenetUtil.c:462-464`, run by its stop and
   shutdown, `SimpleNetwork.c:88, 256`), and item 1 stands for that stop at a restart
   without it, so a restart differs from that driver's shutdown and initialization by
   that one flush, which erXos leaves out on purpose: on the board every run that
   flushed the transmit path flooded the receive ring, and the flush did not cure short
   transmitted frames (~/erxos-history 19bc5cd, pi4/2026-11-22-rx-wedge). Both rings'
   buffers are as long as that driver's (`buffer/0`). erx_genet reads the five buffer
   settings back after `reset/0` and stops on a difference (`buffer_check/0`): a lost
   alignment setting would otherwise cut two bytes off every frame.
3. `configure/1`, the part of `gen_init_locked` before the rings
   (`if_genet.c:915-927`, `gen_set_enaddr` `:1016-1035`, `gen_setup_rxfilter`
   `:977-1013`): the port in external gigabit PHY mode, the unicast address, and the
   filter promiscuous with the MDF table off, as plan 1b-I (c) begins. Then the part of
   `gen_init_txring` and `gen_init_rxring` that is the driver's, not the NIF's
   (hw/svd/genet/genet.svd; docs/design-device-dma.md, "GENET"): both directions'
   burst size, and ring 16's transmit done threshold, transmit flow period and receive
   XON/XOFF thresholds, written before `negotiate/2` enables the ring and the engine,
   and after `reset/0`'s confirmed stop, as FreeBSD writes them after it has stopped
   the engine (`if_genet.c:286-288, 873-875`).
4. `negotiate/2` installs and starts both rings (the device NIF's sequence); its own
   stop finds both engines stopped already.
5. `start/0`: every interrupt masked and cleared first, as FreeBSD's `gen_disable_intr`
   does (`if_genet.c:540-546`), so no completion's interrupt is cleared after it lands;
   then the receive and transmit done interrupts unmasked, as `gen_enable_intr` does
   (`:710-715`). Of the rest of `gen_enable` (`:528-537`), the buffer settings are
   `reset/0`'s and the MAC's enables `link_up/1`'s: `start/0` holds the MAC in software
   reset with transmit and receive off, as the other published driver holds it until
   link-up (the GENET facts record, "MAC reset, RX buffer flush and TX flush"). On the
   board at 100 Mb/s, transmit enabled here, before link-up, put frames on the wire 5 or
   6 bytes short, and receive enabled here delivered each frame some 30 times, although
   `link_up/1` rewrote the speed afterwards (~/erxos-history 19bc5cd,
   pi4/2026-11-22-rx-wedge).
6. `link_up/1` at each `{link, up, Speed}` of erx_phy_c22: first both directions off, a
   frame's time and the MAC held, so that every link-up, a later one included, starts
   from the state `start/0` leaves and none leaves the MAC running from before it; then
   `gen_update_link_locked` (`if_genet.c:1729-1781`): the RGMII out-of-band control on,
   its link bit set and ID mode left enabled, since the board's PHY is wired
   `rgmii-rxid` (the PHY delays the receive clock, erx_phy_c22), then the command
   register's speed; then, as the other published driver's link handler does (the facts
   record, `L.mii` 79-91), the MAC released and, after a wait, receive and transmit
   enabled. A link down writes nothing, as in FreeBSD. The facts record shows that driver
   holding the MAC until link-up, not at a later one; the hold at every link-up is
   erXos's, from the board evidence above, and is the board's to confirm
   (docs/todo-drivers.md).
""".

-export([identify/1, lladdr/1, reset/0, configure/1, start/0, link_up/1]).
-export([stop_retry/1, frames/2, pieces/1]).
-export([buffer/0, buffer_check/0, evidence/0, rx_fault/1]).
-export_type([step/0, address_step/0, rx_fault/0]).

-include("generated/erx_abi.hrl").
-include("generated/erx_hw_genet.hrl").

-define(REV_MAJOR_V5, 6).
-define(PORT_MODE_EXT_GPHY, 3).
-define(MAX_FRAME_LEN, 1536).
-define(TBUF_SIZE, 1).
-define(ALL_IRQS, 16#ffffffff).
%% The ring the device NIF drives, FreeBSD's default queue (if_genetreg.h:118).
-define(RING, ?ERX_GENET_RING).
%% The ring settings FreeBSD writes at start (if_genet.c:738, 752-753, 784, 798-799),
%% taken as its values: no source read gives their units or meaning beyond the
%% register names (hw/svd/genet/genet.svd).
-define(SCB_BURST_SIZE, 8).
-define(TX_MBUF_DONE_THRES, 1).
-define(TX_FLOW_PERIOD, 0).
-define(RX_XON_XOFF_LO, 5).
%% FreeBSD's RX_DESC_COUNT >> 4: the ring's receive descriptors, 256 in FreeBSD as
%% here (if_genet.c:89, if_genetreg.h:116), over 16.
-define(RX_XON_XOFF_HI, (?ERX_GENET_RING_SIZE bsr 4)).
-define(RESET_US, 10).
%% A frame of the largest length at the slowest speed, 1,536 bytes at 10 Mb/s, is 1.23 ms
%% on the wire; the other published driver sleeps 1 to 2 ms after turning receive off
%% (the GENET facts record, "Stopping the DMA and confirming it stopped").
-define(FRAME_US, 2000).
%% An Ethernet header: destination, source and type.
-define(ETHER_HDR_LEN, 14).
%% The device NIF's limit on a transmit post's pieces.
-define(MAX_PIECES, ?ERX_GENET_PIECES_MAX).
-define(OWN_PIECES, (?MAX_PIECES - 1)).
%% The shortest frame on the wire without its FCS (IEEE 802.3's 64 bytes less 4).
-define(MIN_FRAME, 60).
%% erx_device:stop_dma/1 and negotiate/2 answer ebusy until both directions' DMA shows the
%% stop. The one published bound on a stop is 5,000 reads 1 us apart, about 5 ms
%% (docs/design-device-dma.md, "The descriptor forms"); erx_genet retries every
%% millisecond for four times that, then fails.
-define(STOP_RETRY_MS, 1).
-define(STOP_TRIES, 20).

-doc """
One effect on the controller: a whole register written, one named field written (a
read, the field replaced, a write, except on a one-to-clear field, which is one write),
a pause of that many microseconds, or `dma_stop`, both DMA engines stopped and the stop
confirmed without the install (erx_device:stop_dma/1, retried as `stop_retry/1` says; a
stop never confirmed ends the sequence). A register is named as erx_device names it: an
atom, or `{Name, Element}` for one element of an array such as a ring's registers.
""".
-type step() :: {write, erx_device:register_name(), 0..16#ffffffff}
              | {field, erx_device:register_name(), atom(), non_neg_integer()}
              | {wait_us, pos_integer()}
              | dma_stop.

-doc """
What finding the address does next: `{done, Address}`; `{read, Register, Field, Next}`,
read that field and pass its value to `Next`; or `{entropy, Next}`, draw six bytes and
pass them to `Next`. Each `Next` is pure and returns the following step, so the reads
and the draw happen only where `lladdr/1` asks for them, in its order.
""".
-type address_step() :: {done, <<_:48>>}
                      | {read, erx_device:register_name(), atom(), fun((non_neg_integer()) -> address_step())}
                      | {entropy, fun((<<_:48>>) -> address_step())}.

%% --- Identification and the address -----------------------------------------------

-doc "Whether the revision register's major field names GENET v5, the Pi 4's (`if_genet.c:264-268`).".
-spec identify(non_neg_integer()) -> ok | {error, {revision, non_neg_integer()}}.
identify(?REV_MAJOR_V5) -> ok;
identify(Major) when is_integer(Major), Major >= 0 -> {error, {revision, Major}}.

-doc """
The interface's address, in FreeBSD's order (`gen_get_eaddr`, `if_genet.c:446-485`),
as steps: the device tree's, which the device record carries as `mac`; else the one the
firmware left in the controller, MAC0 holding the first four bytes and MAC1's low half
the last two, unless both words are 0; else a random locally administered unicast
address from six bytes of entropy. An address from the record or the controller that is
a group address or all zeros is not used. The controller's address registers are read
only when the record gives no usable address, and only after the receive buffer's reset
bit (bit 1 of SYS_RBUF_FLUSH_CTRL) reads clear, as FreeBSD reads them
(`if_genet.c:465-469`); FreeBSD gives no reason, and what a read of them returns, or
whether it raises a bus error, while that bit is set is unverified.
""".
-spec lladdr(none | 1..16#ffffffffffff) -> address_step().
lladdr(none) -> controller();
lladdr(Record) -> unicast_or(<<Record:48>>, fun controller/0).

controller() ->
    {read, sys_rbuf_flush_ctrl, reset, fun(0) -> controller_words(); (_Reset) -> random() end}.

controller_words() ->
    {read, umac_mac0, addr,
     fun(Mac0) -> {read, umac_mac1, addr, fun(Mac1) -> unicast_or(<<Mac0:32, Mac1:16>>, fun random/0) end} end}.

random() -> {entropy, fun(Entropy) -> {done, local_unicast(Entropy)} end}.

unicast_or(Address, Else) ->
    case unicast(Address) of
        true -> {done, Address};
        false -> Else()
    end.

unicast(<<0:48>>) -> false;
unicast(<<_:7, Group:1, _:40>>) -> Group =:= 0.

%% A random address with the locally administered bit set and the group bit clear.
local_unicast(<<High:6, _:2, Rest:40>>) -> <<High:6, 1:1, 0:1, Rest:40>>.

%% --- The sequences ------------------------------------------------------------------

-doc """
The MAC's receive and transmit stopped at a frame's end and both DMA engines stopped and
confirmed, the status blocks and the receive checksum check off, then the UEFI firmware's
driver's reset as a whole: the receive buffer's reset, the MAC's, the MIB counters, the
largest frame and the buffers' settings, the size control last.
""".
-spec reset() -> [step()].
reset() ->
    [{field, umac_cmd, rxen, 0}, {field, umac_cmd, txen, 0}, {wait_us, ?FRAME_US}, dma_stop]
        ++ held_settings() ++
    [{field, sys_rbuf_flush_ctrl, reset, 1}, {wait_us, ?RESET_US},
     {field, sys_rbuf_flush_ctrl, reset, 0}, {wait_us, ?RESET_US},
     {write, sys_rbuf_flush_ctrl, 0}, {wait_us, ?RESET_US},
     {write, umac_cmd, 0},
     {write, umac_cmd,
      ?ERX_HW_GENET_UMAC_CMD_LCL_LOOP_EN_MASK bor ?ERX_HW_GENET_UMAC_CMD_SW_RESET_MASK},
     {wait_us, ?RESET_US},
     {write, umac_cmd, 0},
     {write, umac_mib_ctrl, ?ERX_HW_GENET_UMAC_MIB_CTRL_RESET_RUNT_MASK bor
                            ?ERX_HW_GENET_UMAC_MIB_CTRL_RESET_RX_MASK bor
                            ?ERX_HW_GENET_UMAC_MIB_CTRL_RESET_TX_MASK},
     {write, umac_mib_ctrl, 0},
     {field, umac_max_frame_len, length, ?MAX_FRAME_LEN}]
        ++ buffer_settings().

%% Both status blocks and the receive checksum check off, the values the UEFI firmware's
%% driver runs with after the Pi 4's boot loader, which leaves all three 0 and which that
%% driver never writes; written before its reset, so that what follows is its reset alone.
held_settings() ->
    [{field, rbuf_ctrl, status_64b, 0}, {field, rbuf_check_ctrl, en, 0},
     {field, tbuf_ctrl, status_64b, 0}].

%% That driver's own buffer settings, its reset's last two writes (GenetUtil.c:330-334): the
%% receive buffer's 2-byte alignment and the size control.
buffer_settings() ->
    [{field, rbuf_ctrl, align_2b, 1}, {field, rbuf_tbuf_size_ctrl, size, ?TBUF_SIZE}].

-doc """
The length of every buffer of both rings, the largest frame, 1,536 bytes: the UEFI
firmware's driver writes its one `GENET_MAX_PACKET_SIZE` as the largest frame and as both
rings' buffer length (`BcmGenetDxe.h:55`, `GenetUtil.c:328, 560-562, 582-584`). A frame of
the MTU with its Ethernet header, a VLAN tag and the 2-byte pad fits one buffer.
""".
-spec buffer() -> pos_integer().
buffer() -> ?MAX_FRAME_LEN.

-doc """
The port, the address `Lladdr`, the promiscuous filter and the driver's ring settings,
before the rings.
""".
-spec configure(<<_:48>>) -> [step()].
configure(<<Mac0:32, Mac1:16>>) ->
    [{field, sys_port_ctrl, mode, ?PORT_MODE_EXT_GPHY},
     {field, umac_mac0, addr, Mac0}, {field, umac_mac1, addr, Mac1},
     {field, umac_cmd, promisc, 1}, {write, umac_mdf_ctrl, 0}]
        ++ ring_settings().

%% gen_init_txring's (if_genet.c:738, 752-753), then gen_init_rxring's (:784, 798-799).
ring_settings() ->
    [{write, tx_scb_burst_size, ?SCB_BURST_SIZE},
     {write, {tx_ring_mbuf_done_thres, ?RING}, ?TX_MBUF_DONE_THRES},
     {write, {tx_ring_flow_period, ?RING}, ?TX_FLOW_PERIOD},
     {write, rx_scb_burst_size, ?SCB_BURST_SIZE},
     {field, {rx_ring_xon_xoff_thres, ?RING}, lo, ?RX_XON_XOFF_LO},
     {field, {rx_ring_xon_xoff_thres, ?RING}, hi, ?RX_XON_XOFF_HI}].

-doc """
The interrupts, after the rings, with the MAC held in software reset and transmit and
receive off until `link_up/1` sets the link's speed.
""".
-spec start() -> [step()].
start() ->
    [{write, intrl2_cpu_set_mask, ?ALL_IRQS}, {write, intrl2_cpu_clear, ?ALL_IRQS},
     {field, umac_cmd, sw_reset, 1}, {wait_us, ?RESET_US},
     {field, intrl2_cpu_clear_mask, rxdma_done, 1}, {field, intrl2_cpu_clear_mask, txdma_done, 1}].

-doc """
The MAC set for a link up at `Speed` Mb/s: both directions off at a frame's end and the
MAC held, as `start/0` leaves it, then the RGMII out-of-band control and the speed, then
the MAC released, and receive and transmit enabled only after that.
""".
-spec link_up(10 | 100 | 1000) -> [step()].
link_up(Speed) ->
    [{field, umac_cmd, rxen, 0}, {field, umac_cmd, txen, 0}, {wait_us, ?FRAME_US},
     {field, umac_cmd, sw_reset, 1}, {wait_us, ?RESET_US},
     {field, ext_rgmii_oob_ctrl, oob_disable, 0}, {field, ext_rgmii_oob_ctrl, rgmii_link, 1},
     {field, ext_rgmii_oob_ctrl, rgmii_mode_en, 1}, {field, ext_rgmii_oob_ctrl, id_mode_disable, 0},
     {field, umac_cmd, speed, speed_code(Speed)},
     {field, umac_cmd, sw_reset, 0}, {wait_us, ?RESET_US},
     {field, umac_cmd, rxen, 1}, {field, umac_cmd, txen, 1}].

%% The command register's speed field (if_genetreg.h:80-83).
speed_code(10) -> 0;
speed_code(100) -> 1;
speed_code(1000) -> 2.

-doc """
What to do after the `Tries`-th call that waits on both DMA engines' stop,
erx_device:stop_dma/1 or `negotiate/2`, answered `{error, ebusy}`: wait that many
milliseconds and try again, or give up.
""".
-spec stop_retry(pos_integer()) -> {retry, pos_integer()} | {error, stop_timeout}.
stop_retry(Tries) when is_integer(Tries), Tries >= 1, Tries < ?STOP_TRIES ->
    {retry, ?STOP_RETRY_MS};
stop_retry(Tries) when is_integer(Tries), Tries >= ?STOP_TRIES ->
    {error, stop_timeout}.

-doc """
The buffer settings `reset/0` writes, as the fields to read back after it and the value
each must hold. No source says whether the resets keep the three written before them, or
whether the controller keeps every one as written, and a lost one is not seen in a frame:
without the alignment every frame would lose its first two bytes to the pad erx_genet_rx
strips. The driver stops when a field reads otherwise.
""".
-spec buffer_check() -> [{erx_device:register_name(), atom(), non_neg_integer()}].
buffer_check() ->
    [{Register, Field, Value}
     || {field, Register, Field, Value} <- held_settings() ++ buffer_settings()].

%% --- What a failure shows -------------------------------------------------------------

-doc """
The registers whose words the driver logs when the device NIF breaks a queue or
erx_device:stop_dma/1 or `negotiate/2` never sees the stop: each direction's DMA control and DMA status, then the
receive ring's producer and consumer index and the transmit ring's consumer and producer
index, for the ring the NIF drives. The NIF owns all but the two status registers, and the
driver only reads them, which has no side effect. The words settle on the board what the
sources leave open (docs/research-genet-bcm2711.md, "What only the board can settle"):
which bit of the idle report a stop that never shows lacks, and how far the indexes stand
apart when a queue breaks.
""".
-spec evidence() -> [erx_device:register_name()].
evidence() ->
    [rx_dma_ctrl, rx_dma_status, tx_dma_ctrl, tx_dma_status,
     {rx_ring_prod_index, ?RING}, {rx_ring_cons_index, ?RING},
     {tx_ring_cons_index, ?RING}, {tx_ring_prod_index, ?RING}].

-doc """
Whether a broken receive queue met the device NIF's one receive bound, read again from
the controller (docs/design-device-dma.md, "The register ring (GENET)"): `{index, Ahead}`,
the producer index more than the ring's size ahead of the consumer index; else
`unexplained`, when the controller no longer shows it. A descriptor's status breaks no
queue: one whose length passes the buffer is a frame of no bytes.

`Evidence` is the words of `evidence/0`'s registers, read once, so the indexes come from
the same reads the driver logs. Every word is untrusted.
""".
-type rx_fault() :: {index, (?ERX_GENET_RING_SIZE + 1)..16#ffff} | unexplained.
-spec rx_fault([{erx_device:register_name(), non_neg_integer()}]) -> rx_fault().
rx_fault(Evidence) ->
    {_, ProdWord} = lists:keyfind({rx_ring_prod_index, ?RING}, 1, Evidence),
    {_, ConsWord} = lists:keyfind({rx_ring_cons_index, ?RING}, 1, Evidence),
    Prod = ?ERX_HW_GENET_RX_RING_PROD_INDEX_INDEX_GET(ProdWord),
    Cons = ?ERX_HW_GENET_RX_RING_CONS_INDEX_INDEX_GET(ConsWord),
    case (Prod - Cons) band 16#ffff of
        Ahead when Ahead > ?ERX_GENET_RING_SIZE -> {index, Ahead};
        _Ahead -> unexplained
    end.

%% --- Frames ---------------------------------------------------------------------------

-doc """
The cut of a batch of receive completions into its drops and its frames, in order. Each
completion is the device NIF's `{Status, Bytes}`, which erx_genet_rx:frame/2 judges: the
descriptor's whole status word and the bytes the controller wrote, as many as its length
field said or none past the buffer, the 2-byte alignment pad first. Both are untrusted. Its
drops pass through, and a frame longer than the MTU and its Ethernet header is dropped
as `too_long` as well.
""".
-spec frames([{erx_genet_rx:status(), binary()}], pos_integer()) ->
          {[{dropped, erx_genet_rx:drop()}], [binary()]}.
frames(Completions, Mtu) ->
    lists:foldr(fun(Completion, Acc) -> frame(Completion, Mtu, Acc) end, {[], []}, Completions).

frame({Status, Bytes}, Mtu, {Drops, Frames}) ->
    case erx_genet_rx:frame(Status, Bytes) of
        {frame, Frame} when byte_size(Frame) =< Mtu + ?ETHER_HDR_LEN -> {Drops, [Frame | Frames]};
        {frame, _Long} -> {[{dropped, too_long} | Drops], Frames};
        {drop, Reason} -> {[{dropped, Reason} | Drops], Frames}
    end.

-doc """
A frame's pieces for a transmit post: its non-empty binaries in order, a frame shorter
than 60 bytes padded with zeros to 60, since whether and with what the controller pads
a short frame is unknown and a buffer it pads from may hold an earlier frame's bytes;
or, when it has
more than the device NIF takes, all but the last three joined into the first, so a frame
of headers and a payload of one or two binaries goes out with no join in Erlang.
""".
-spec pieces(iodata()) -> [{out, binary()}].
pieces(Frame) ->
    case leaves([Frame | pad(iolist_size(Frame))]) of
        Leaves when length(Leaves) =< ?MAX_PIECES ->
            [{out, B} || B <- Leaves];
        Leaves ->
            {Joined, Own} = lists:split(length(Leaves) - ?OWN_PIECES, Leaves),
            [{out, iolist_to_binary(Joined)} | [{out, B} || B <- Own]]
    end.

pad(Size) when Size < ?MIN_FRAME -> [<<0:((?MIN_FRAME - Size) * 8)>>];
pad(_Size) -> [].

%% The binaries of an iodata term in order, a byte of a list as a binary of its own, an
%% empty binary as none.
leaves(<<>>) -> [];
leaves(B) when is_binary(B) -> [B];
leaves(Byte) when is_integer(Byte) -> [<<Byte>>];
leaves([]) -> [];
leaves([Head | Tail]) -> leaves(Head) ++ leaves(Tail).
