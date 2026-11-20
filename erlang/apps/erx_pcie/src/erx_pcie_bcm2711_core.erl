%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pcie_bcm2711_core).
-moduledoc """
The BCM2711 bridge driver's decisions (docs/design-usb.md, "The BCM2711
bridge"; docs/design-pcie.md, "The bridge seam") as a pure state machine
over the bridge's register readings. Each step takes the answer to the
last operation and returns the next one, so the driver makes every
register access and every wait, and this module decides each from what
the last ones answered. Register values come from
hw/svd/bcm2711_pcie/bcm2711_pcie.svd, whose sources are the clean-room
facts record docs/research-brcmstb-pcie.md and FreeBSD's bcm2838_pci.c.

Three machines share step/2:

* start/2, at each start of the PCIe domain: the keep-or-reset decision
  from the link and the endpoint's firmware register, then either the
  keep (the windows and MISC_CTRL written again) or the clean turn-off,
  when the link is up, and bring-up in the vendor's order. It ends
  `{up, Up}` or `{error, Reason}`.
* firmware/1, after the enumerator has numbered the root port and the
  endpoint reads present: on a bridge whose bring-up cycled PERST#, the
  firmware notification, 1 ms, and the firmware register read again; on
  a kept bridge nothing, since its firmware was read present. It ends
  `{firmware, State}` or `{error, link_down}`.
* access/2, one configuration access: absent, with no operation, at a
  place erx_pcie_bridge:reaches/2 refuses; the root port's own space at
  its window offset; any other place between two reads of the link, the
  value kept only when the link was up before and after.

Every tree value the windows take is checked before the first operation,
so a refused tree touches no register. PERST# is asserted only on the
reset path, by the turn-off and by bring-up's first step, and the reset
path is the only one whose firmware/1 notifies, so the VL805's firmware
is asked for after every PERST# cycle and never on a kept bridge.

An access below the root port is an index write and a data access, so
the driver runs one machine at a time, as the one enumerator process
does. The bridge's root bus is bus 0, which the index register numbers
absolutely; the root port is at device 0, function 0 there.
""".

-export([start/2, firmware/1, access/2, step/2]).
-export([link_up/1, firmware_present/1]).
-export_type([core/0, register/0, op/0, answer/0, action/0, up/0, reason/0, result/0]).

-include("generated/erx_hw_bcm2711_pcie.hrl").

-doc "A register of the bridge's SVD peripheral, by the name the device NIF takes.".
-type register() :: atom() | {atom(), 0..3}.

-doc """
One operation for the driver: a register read or a write of a whole
word; a wait of at least that many microseconds, a deadline the driver
keeps; a configuration access at an offset of the bridge's window (the
root port's space at 0, the endpoint's data window at 16#8000); or the
VL805's firmware notification (docs/design-pcie.md, "The bridge seam").
""".
-type op() :: {read, register()}
            | {write, register(), 0..16#ffffffff}
            | {wait, Microseconds :: pos_integer()}
            | {cfg_read, WindowOffset :: 0..16#8fff, Width :: 1 | 2 | 4}
            | {cfg_write, WindowOffset :: 0..16#8fff, Width :: 1 | 2 | 4, Value :: 0..16#ffffffff}
            | notify_firmware.

-doc """
The driver's answer to the last operation: a read's value; `ok` for a
write or a wait; the notification's answer.
""".
-type answer() :: non_neg_integer() | ok | {error, atom()}.

-doc "What the driver does next: an operation, or the machine's result.".
-type action() :: op() | {done, result()}.

-doc """
A bridge that is up: whether it was kept or reset, how the turn-off's L23
request went (`not_run` on a kept bridge or a link found down), and the
link's speed and width from the root port's link status.
""".
-type up() :: #{path := kept | reset,
                turn_off := not_run | l23 | l23_timed_out,
                speed := 0..15,
                width := 0..63}.

-doc """
Why start/2 failed: the tree's `dma-ranges` or `ranges` break the
windows' rules, the block is in endpoint mode, or the link did not come
up within 100 ms after the PCIe rule's 100 ms.
""".
-type reason() :: dma_ranges | ranges | endpoint_mode | link_down.

-doc "A machine's result.".
-type result() :: {up, up()} | {error, reason()}
                | {firmware, present | absent | not_loaded}
                | erx_pcie_bridge:result().

%% One item of the agenda: an operation and what follows from its answer,
%% the items to run before the rest; or the machine's result.
-type item() :: {op(), fun((answer()) -> [item()])} | {done, result()}.

%% What every item of a machine may read, fixed when the machine starts: the
%% bridge, its endpoint (the closed bus's listed place), and the tree's window
%% writes and memory controller size.
-record(plan, {bridge :: erx_abi_layout:erx_pcie_bridge(),
               endpoint :: erx_pcie:place(),
               inbound = [] :: [{register(), 0..16#ffffffff}],
               outbound = [] :: [{register(), 0..16#ffffffff}],
               scb0_size = 0 :: 0..31}).

%% A machine: its plan, the items still to run, and whether start/2 kept the
%% bridge or cycled PERST#, which run/1 takes from start/2's result.
-record(core, {plan :: #plan{},
               path = none :: none | kept | reset,
               agenda = [] :: [item()]}).

-opaque core() :: #core{}.

%% The PCIe rule between PERST#'s release and the first configuration request,
%% then link-up polled every 5 ms for at most 100 ms more (record, section 1, step 6).
-define(PERST_SETTLE_US, 100000).
-define(LINK_POLL_US, 5000).
-define(LINK_POLLS, 21).
%% The bridge reset's and the SerDes's settling time (record, section 1, steps 3c, 3e).
-define(RESET_SETTLE_US, 100).
%% L23 polled 15 times 2 ms apart (record, section 6).
-define(L23_POLL_US, 2000).
-define(L23_POLLS, 15).
%% After the notification, before the firmware register is read again
%% (bcm2838_xhci.c:171-172).
-define(FIRMWARE_SETTLE_US, 1000).
%% The VL805's firmware version register in its configuration space (record, section 5).
-define(FIRMWARE_REGISTER, 16#50).
%% The endpoint's configuration window, behind EXT_CFG_INDEX (record, section 3).
-define(EXT_CFG_DATA, 16#8000).
-define(MIB, 16#100000).
-define(GIB, 16#40000000).

%% Public entries

-doc """
The start of the PCIe domain over a bridge and the tree's inbound range,
its `dma-ranges` (one window, `erx_abi_layout:erx_pcie_window()`): the keep-or-reset
decision and what it decides. The bridge's first listed place is its
endpoint, the VL805.
""".
-spec start(erx_abi_layout:erx_pcie_bridge(), erx_abi_layout:erx_pcie_window()) -> {core(), action()}.
start(#{bus_first := 0} = Bridge, Inbound) ->
    Plan = plan(Bridge),
    case {inbound(Inbound), outbound(erx_pcie:windows(Bridge))} of
        {{error, _} = Error, _} -> run(#core{plan = Plan, agenda = [{done, Error}]});
        {_, {error, _} = Error} -> run(#core{plan = Plan, agenda = [{done, Error}]});
        {{ok, InboundWrites, Scb0}, {ok, OutboundWrites}} ->
            Planned = Plan#plan{inbound = InboundWrites, outbound = OutboundWrites, scb0_size = Scb0},
            run(#core{plan = Planned, agenda = decide(Planned)})
    end.

-doc """
The endpoint's firmware after start/2 ended `{up, _}`: notified and read
again when PERST# was cycled, present without an operation when kept.
""".
-spec firmware(core()) -> {core(), action()}.
firmware(#core{path = kept} = Core) ->
    run(Core#core{agenda = [{done, {firmware, present}}]});
firmware(#core{path = reset, plan = Plan} = Core) ->
    run(Core#core{agenda = [{notify_firmware, fun(Answer) -> notified(Plan, Answer) end}]}).

-doc "One configuration access through the bridge.".
-spec access(erx_pcie_bridge:access(), erx_abi_layout:erx_pcie_bridge()) -> {core(), action()}.
access(Access, #{bus_first := 0} = Bridge) ->
    run(#core{plan = plan(Bridge), agenda = config(Bridge, Access, fun(Result) -> [{done, Result}] end)}).

-doc "The machine's next action from the answer to its last operation.".
-spec step(answer(), core()) -> {core(), action()}.
step(Answer, #core{agenda = [{_Op, Then} | Rest]} = Core) ->
    run(Core#core{agenda = Then(Answer) ++ Rest}).

-doc "Whether MISC_PCIE_STATUS reads the link up: PHYLINKUP and DL_ACTIVE both set.".
-spec link_up(non_neg_integer()) -> boolean().
link_up(Status) ->
    ?ERX_HW_BCM2711_PCIE_MISC_PCIE_STATUS_PHYLINKUP_GET(Status) =:= 1
        andalso ?ERX_HW_BCM2711_PCIE_MISC_PCIE_STATUS_DL_ACTIVE_GET(Status) =:= 1.

-doc """
Whether the VL805's firmware register reads its firmware loaded: neither
0 nor all ones (bcm2838_xhci.c:119-120).
""".
-spec firmware_present(0..16#ffffffff) -> boolean().
firmware_present(Version) ->
    Version =/= 0 andalso Version =/= 16#ffffffff.

%% The machine

plan(Bridge) ->
    [Endpoint | _] = erx_pcie:places(Bridge),
    #plan{bridge = Bridge, endpoint = Endpoint}.

%% Runs the agenda to its next operation or its result. A result ends the
%% machine; the agenda after it is never reached. A bridge that came up keeps
%% its path for firmware/1.
run(#core{agenda = [{done, {up, #{path := Path}} = Result} | _]} = Core) ->
    {Core#core{path = Path, agenda = []}, {done, Result}};
run(#core{agenda = [{done, Result} | _]} = Core) ->
    {Core#core{agenda = []}, {done, Result}};
run(#core{agenda = [{Op, _Then} | _]} = Core) ->
    {Core, Op}.

op(Op, Then) -> {Op, Then}.

read(Register, Then) -> op({read, Register}, Then).

write(Register, Word) -> op({write, Register, Word}, fun(ok) -> [] end).

wait(Microseconds) -> op({wait, Microseconds}, fun(ok) -> [] end).

%% A read-modify-write: the register read, Change applied, the word written.
update(Register, Change) ->
    read(Register, fun(Word) -> [write(Register, Change(Word))] end).

%% Polls Register up to Tries times, Interval microseconds apart, until Met
%% holds of a reading; Then is given `met` or `timed_out`.
poll(Register, Met, Tries, Interval, Then) ->
    read(Register, fun(Word) ->
                           case {Met(Word), Tries} of
                               {true, _} -> Then(met);
                               {false, 1} -> Then(timed_out);
                               {false, _} -> [wait(Interval), poll(Register, Met, Tries - 1, Interval, Then)]
                           end
                   end).

%% Keep or reset (docs/design-usb.md, "Keep or reset, decided from what the
%% bridge reads"): with the link up, the firmware register decides.
decide(#plan{bridge = Bridge, endpoint = Endpoint} = Plan) ->
    [read(misc_pcie_status,
          fun(Status) ->
                  case link_up(Status) of
                      false -> bring_up(Plan, not_run);
                      true -> config(Bridge, {read, Endpoint, ?FIRMWARE_REGISTER, 4},
                                     fun(Firmware) -> kept_or_reset(Plan, Firmware) end)
                  end
          end)].

kept_or_reset(Plan, {ok, Version}) ->
    case firmware_present(Version) of
        true -> keep(Plan);
        false -> turn_off(Plan)
    end;
kept_or_reset(Plan, {error, _}) ->
    bring_up(Plan, not_run).

%% The keep: nothing reset; MISC_CTRL and the windows written again with the
%% values the tree gives, which a running VL805 already uses.
keep(#plan{inbound = Inbound, outbound = Outbound} = Plan) ->
    [update(misc_ctrl, fun(Word) -> scb0(Plan, misc_ctrl(Word)) end)
     | writes(Inbound ++ Outbound)]
        ++ [link_status(kept, not_run)].

%% The clean shutdown before a reset of a bridge whose link is up (record,
%% section 6): L23 requested and polled, PERST# asserted, the request cleared,
%% the SerDes powered down, the bridge put in reset; then bring-up.
turn_off(Plan) ->
    [update(misc_pcie_ctrl, fun(Word) -> l23_request(Word, 1) end),
     poll(misc_pcie_status,
          fun(Status) -> ?ERX_HW_BCM2711_PCIE_MISC_PCIE_STATUS_LINK_IN_L23_GET(Status) =:= 1 end,
          ?L23_POLLS, ?L23_POLL_US,
          fun(L23) ->
                  TurnOff = case L23 of met -> l23; timed_out -> l23_timed_out end,
                  [update(rgr1_sw_init_1, fun(Word) -> perst(Word, 1) end),
                   update(misc_pcie_ctrl, fun(Word) -> l23_request(Word, 0) end),
                   update(hard_debug, fun(Word) -> serdes_iddq(Word, 1) end),
                   update(rgr1_sw_init_1, fun(Word) -> bridge_reset(Word, 1) end)
                   | bring_up(Plan, TurnOff)]
          end)].

%% Bring-up in the vendor's order (record, section 1, steps 3 and 6;
%% docs/design-usb.md, "Bring-up"), each wait a deadline; TurnOff is how the
%% turn-off before it went, for the result.
bring_up(#plan{inbound = Inbound} = Plan, TurnOff) ->
    [update(rgr1_sw_init_1, fun(Word) -> bridge_reset(Word, 1) end),
     update(rgr1_sw_init_1, fun(Word) -> perst(Word, 1) end),
     wait(?RESET_SETTLE_US),
     update(rgr1_sw_init_1, fun(Word) -> bridge_reset(Word, 0) end),
     update(hard_debug, fun(Word) -> serdes_iddq(Word, 0) end),
     wait(?RESET_SETTLE_US),
     update(misc_ctrl, fun misc_ctrl/1)
     | writes(Inbound)]
        ++ [read(misc_pcie_status, fun(Status) -> root_complex(Plan, TurnOff, Status) end)].

%% Bring-up from the root-complex check on (record, section 1, steps 3h to 3n
%% and 6; docs/design-usb.md, "Bring-up", steps 4 to 8).
root_complex(#plan{outbound = Outbound} = Plan, TurnOff, Status) ->
    case ?ERX_HW_BCM2711_PCIE_MISC_PCIE_STATUS_PORT_GET(Status) of
        ?ERX_HW_BCM2711_PCIE_MISC_PCIE_STATUS_PORT_ENDPOINT -> [{done, {error, endpoint_mode}}];
        ?ERX_HW_BCM2711_PCIE_MISC_PCIE_STATUS_PORT_ROOT_COMPLEX ->
            [update(misc_ctrl, fun(Word) -> scb0(Plan, Word) end),
             update(rc_cfg_priv1_id_val3, fun class_code/1)
             | writes(Outbound)]
                ++ [update(rc_cfg_vendor_specific_reg1, fun endian_little/1),
                    update(hard_debug, fun clock_power_management_off/1),
                    update(rgr1_sw_init_1, fun(Word) -> perst(Word, 0) end),
                    wait(?PERST_SETTLE_US),
                    poll(misc_pcie_status, fun link_up/1, ?LINK_POLLS, ?LINK_POLL_US,
                         fun(met) -> [link_status(reset, TurnOff)];
                            (timed_out) -> [{done, {error, link_down}}]
                         end)]
    end.

%% The root port's negotiated speed and width, with how the bridge came up: the
%% machine's result.
link_status(Path, TurnOff) ->
    read(rc_cfg_link_control_status,
         fun(Word) ->
                 [{done, {up, #{path => Path, turn_off => TurnOff,
                                speed => ?ERX_HW_BCM2711_PCIE_RC_CFG_LINK_CONTROL_STATUS_SPEED_GET(Word),
                                width => ?ERX_HW_BCM2711_PCIE_RC_CFG_LINK_CONTROL_STATUS_WIDTH_GET(Word)}}}]
         end).

writes(Words) -> [write(Register, Word) || {Register, Word} <- Words].

%% The notification's answer: on `ok`, 1 ms, then the firmware register read
%% again; an error is `not_loaded`, and the register is not read
%% (docs/design-pcie.md, "The bridge seam", the endpoint's firmware).
notified(#plan{bridge = Bridge, endpoint = Endpoint}, ok) ->
    [wait(?FIRMWARE_SETTLE_US)
     | config(Bridge, {read, Endpoint, ?FIRMWARE_REGISTER, 4},
              fun({ok, Version}) ->
                      [{done, {firmware, case firmware_present(Version) of true -> present; false -> absent end}}];
                 ({error, _}) -> [{done, {error, link_down}}]
              end)];
notified(_Core, {error, _}) ->
    [{done, {firmware, not_loaded}}].

%% One configuration access (docs/design-pcie.md, "The bridge seam"): a place
%% the bridge does not reach answers absent before any operation; the root
%% port's space is at its window offset; any other place is reached through
%% EXT_CFG_INDEX between two reads of the link, and its answer is kept only when
%% the link was up at both.
config(Bridge, Access, Then) ->
    Place = element(2, Access),
    case {Place, erx_pcie_bridge:reaches(Bridge, Place)} of
        {{0, 0, 0}, _} -> [window_access(Access, 0, Then)];
        %% Any other place on bus 0 locks up the memory controller, whatever the
        %% record says (bcm2838_pci.c:300-307).
        {{0, _, _}, _} -> Then({error, absent});
        {_, false} -> Then({error, absent});
        {_, true} -> [read(misc_pcie_status, fun(Before) -> linked(Before, Place, Access, Then) end)]
    end.

linked(Before, {Bus, Device, Function}, Access, Then) ->
    case link_up(Before) of
        false -> Then({error, link_down});
        true ->
            Index = ?ERX_HW_BCM2711_PCIE_EXT_CFG_INDEX_BUS_PUT(Bus)
                bor ?ERX_HW_BCM2711_PCIE_EXT_CFG_INDEX_DEVICE_PUT(Device)
                bor ?ERX_HW_BCM2711_PCIE_EXT_CFG_INDEX_FUNCTION_PUT(Function),
            [write(ext_cfg_index, Index),
             window_access(Access, ?EXT_CFG_DATA,
                           fun(Answer) ->
                                   [read(misc_pcie_status,
                                         fun(After) ->
                                                 case link_up(After) of
                                                     true -> Then(Answer);
                                                     false -> Then({error, link_down})
                                                 end
                                         end)]
                           end)]
    end.

%% The access itself at Base in the window; a read's value as the bridge seam
%% answers it.
window_access({read, _Place, Offset, Width}, Base, Then) when Offset rem Width =:= 0 ->
    op({cfg_read, Base + Offset, Width},
       fun(Value) -> Then(erx_pcie_bridge:read_answer(Offset, Width, Value)) end);
window_access({write, _Place, Offset, Width, Value}, Base, Then) when Offset rem Width =:= 0 ->
    op({cfg_write, Base + Offset, Width, Value}, fun(ok) -> Then(ok) end).

%% Register words

replace(Word, Mask, Field) -> (Word band bnot Mask) bor Field.

bridge_reset(Word, Value) ->
    replace(Word, ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_INIT_MASK, ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_INIT_PUT(Value)).

perst(Word, Value) ->
    replace(Word, ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_PERST_MASK, ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_PERST_PUT(Value)).

serdes_iddq(Word, Value) ->
    replace(Word, ?ERX_HW_BCM2711_PCIE_HARD_DEBUG_SERDES_IDDQ_MASK, ?ERX_HW_BCM2711_PCIE_HARD_DEBUG_SERDES_IDDQ_PUT(Value)).

l23_request(Word, Value) ->
    replace(Word, ?ERX_HW_BCM2711_PCIE_MISC_PCIE_CTRL_L23_REQUEST_MASK,
            ?ERX_HW_BCM2711_PCIE_MISC_PCIE_CTRL_L23_REQUEST_PUT(Value)).

%% "Safe" mode: no CLKREQ# clock power management and no L1 substates
%% (record, section 1; docs/design-usb.md, "Bring-up", step 6).
clock_power_management_off(Word) ->
    Word band bnot (?ERX_HW_BCM2711_PCIE_HARD_DEBUG_CLKREQ_DEBUG_ENABLE_MASK
                    bor ?ERX_HW_BCM2711_PCIE_HARD_DEBUG_L1SS_ENABLE_MASK).

%% The vendor's MISC_CTRL for the BCM2711 (record, section 1, step 3f): system
%% bus access, unsupported-request reads answered, 128-byte bursts and both
%% read-completion modes.
misc_ctrl(Word) ->
    Set = ?ERX_HW_BCM2711_PCIE_MISC_CTRL_SCB_ACCESS_EN_MASK
        bor ?ERX_HW_BCM2711_PCIE_MISC_CTRL_CFG_READ_UR_MODE_MASK
        bor ?ERX_HW_BCM2711_PCIE_MISC_CTRL_RCB_MPS_MODE_MASK
        bor ?ERX_HW_BCM2711_PCIE_MISC_CTRL_RCB_64B_MODE_MASK,
    Burst = ?ERX_HW_BCM2711_PCIE_MISC_CTRL_MAX_BURST_SIZE_PUT(?ERX_HW_BCM2711_PCIE_MISC_CTRL_MAX_BURST_SIZE_BYTES_128),
    replace(Word bor Set, ?ERX_HW_BCM2711_PCIE_MISC_CTRL_MAX_BURST_SIZE_MASK, Burst).

scb0(#plan{scb0_size = Size}, Word) ->
    replace(Word, ?ERX_HW_BCM2711_PCIE_MISC_CTRL_SCB0_SIZE_MASK, ?ERX_HW_BCM2711_PCIE_MISC_CTRL_SCB0_SIZE_PUT(Size)).

class_code(Word) ->
    Bridge = ?ERX_HW_BCM2711_PCIE_RC_CFG_PRIV1_ID_VAL3_CLASS_CODE_PCI_TO_PCI_BRIDGE,
    replace(Word, ?ERX_HW_BCM2711_PCIE_RC_CFG_PRIV1_ID_VAL3_CLASS_CODE_MASK,
            ?ERX_HW_BCM2711_PCIE_RC_CFG_PRIV1_ID_VAL3_CLASS_CODE_PUT(Bridge)).

endian_little(Word) ->
    Little = ?ERX_HW_BCM2711_PCIE_RC_CFG_VENDOR_SPECIFIC_REG1_ENDIAN_MODE_BAR2_LITTLE,
    replace(Word, ?ERX_HW_BCM2711_PCIE_RC_CFG_VENDOR_SPECIFIC_REG1_ENDIAN_MODE_BAR2_MASK,
            ?ERX_HW_BCM2711_PCIE_RC_CFG_VENDOR_SPECIFIC_REG1_ENDIAN_MODE_BAR2_PUT(Little)).

%% The windows from the tree

%% The inbound window from the tree's dma-ranges (record, section 2): BAR2 maps
%% CPU address 0 at the range's PCI address, its size the range's rounded up to
%% a power of two, which must divide the PCI address, which must not lie
%% strictly between 2 and 4 GiB; BAR1, which maps the SoC's own registers on
%% this family, and BAR3 disabled. The CPU side is fixed at 0, so a range at
%% another CPU address cannot be mapped as the tree says.
%% The window's size code and SCB0_SIZE are both log2(size) - 15, the code's
%% form from 64 KiB to 64 GiB; SCB0_SIZE has no form below 64 KiB, so a
%% smaller window is refused too.
inbound(#{pci := Pci, cpu := 0, size := Size}) ->
    Log2 = ceil_log2(Size),
    Aligned = Pci rem (1 bsl Log2) =:= 0,
    Hole = 2 * ?GIB < Pci andalso Pci < 4 * ?GIB,
    case Log2 >= 16 andalso Log2 =< 36 andalso Aligned andalso not Hole of
        true ->
            Code = Log2 - 15,
            Lo = ?ERX_HW_BCM2711_PCIE_BAR2_CONFIG_LO_SIZE_PUT(Code)
                bor ?ERX_HW_BCM2711_PCIE_BAR2_CONFIG_LO_ADDRESS_PUT((Pci band 16#ffffffff) bsr 12),
            Disabled = ?ERX_HW_BCM2711_PCIE_BAR1_CONFIG_LO_SIZE_PUT(?ERX_HW_BCM2711_PCIE_BAR1_CONFIG_LO_SIZE_DISABLED),
            {ok, [{bar2_config_lo, Lo}, {bar2_config_hi, Pci bsr 32},
                  {bar1_config_lo, Disabled}, {bar3_config_lo, Disabled}],
             Code};
        false -> {error, dma_ranges}
    end;
inbound(_Window) ->
    {error, dma_ranges}.

%% The outbound windows from the tree's memory ranges (record, section 2), at
%% most four, each with its CPU base and size in whole MiB and its last MiB
%% below 2^20 MiB, the 20 bits the base, limit and their high bytes hold.
outbound(Ranges) ->
    Memory = [Range || #{flags := Flags} = Range <- Ranges, not lists:member(io, Flags)],
    case length(Memory) of
        Count when Count >= 1, Count =< 4 ->
            Windows = lists:zip(lists:seq(0, Count - 1), Memory),
            case lists:all(fun({_, Range}) -> mib_window(Range) end, Windows) of
                true -> {ok, lists:append([window_writes(Index, Range) || {Index, Range} <- Windows])};
                false -> {error, ranges}
            end;
        _ -> {error, ranges}
    end.

mib_window(#{cpu := Cpu, size := Size}) ->
    Cpu rem ?MIB =:= 0 andalso Size rem ?MIB =:= 0
        andalso (Cpu + Size - 1) div ?MIB =< 16#fffff.

window_writes(Index, #{pci := Pci, cpu := Cpu, size := Size}) ->
    Base = Cpu div ?MIB,
    Limit = (Cpu + Size - 1) div ?MIB,
    [{{win_lo, Index}, Pci band 16#ffffffff},
     {{win_hi, Index}, Pci bsr 32},
     {{win_base_limit, Index}, ?ERX_HW_BCM2711_PCIE_WIN_BASE_LIMIT_BASE_PUT(Base band 16#fff)
                                bor ?ERX_HW_BCM2711_PCIE_WIN_BASE_LIMIT_LIMIT_PUT(Limit band 16#fff)},
     {{win_base_hi, Index}, ?ERX_HW_BCM2711_PCIE_WIN_BASE_HI_BASE_PUT(Base bsr 12)},
     {{win_limit_hi, Index}, ?ERX_HW_BCM2711_PCIE_WIN_LIMIT_HI_LIMIT_PUT(Limit bsr 12)}].

%% The least L with 2^L >= N, for N >= 1.
ceil_log2(N) -> ceil_log2(N, 0).

ceil_log2(N, L) when 1 bsl L >= N -> L;
ceil_log2(N, L) -> ceil_log2(N, L + 1).
