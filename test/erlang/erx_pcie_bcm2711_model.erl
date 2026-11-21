%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A model of the BCM2711 bridge's registers and of the VL805 behind it, for the
%% cases of erx_pcie_bcm2711_core (docs/design-pcie.md, "Host tests of the pure
%% cores"; docs/research-brcmstb-pcie.md, sections 1, 3 and 6). It is a map,
%% advanced one operation at a time by run/2, which drives a core machine to its
%% result. For the driver's cases the map is kept in an ets table, reached as the
%% driver reaches its device, in erx_device's shape (read/2, write/3, config_read/4,
%% config_write/5), with the seam's sleep and firmware notification from effects/1.
%%
%% The link trains once PERST# and the bridge reset are released and the SerDes is
%% powered, `train_us` microseconds after PERST#'s release, unless the model is made
%% with `trains => false`. It can fall before any operation, the `fall_at`-th of the
%% model's life, and stays down until the next PERST# cycle. The VL805 loses its
%% firmware at every PERST# assertion and loads it at a notification made with the
%% link up. A configuration access below the root port with the link down completes
%% with a plausible value, the firmware version the VL805 last held, as a read the
%% abort did not stop would, and is recorded as a violation; so is any access that
%% selects bus 0 through the index register, which locks up the memory controller,
%% and any access below the root port less than 100 ms after PERST#'s release.
%%
%% A bridge in reset answers only at its reset register, RGR1_SW_INIT_1, and one out
%% of reset whose SerDes is powered down only there and at HARD_DEBUG, which powers
%% it: the vendor's order touches nothing else in those states (facts record, section
%% 1, steps 2, 3a to 3e; section 6). What any other access does then the record does
%% not establish; on the board, a read of MISC_PCIE_STATUS made with the bridge as
%% the boot firmware left it never completed and the watchdog reset the board. The
%% model raises such an access as {bus_hang, Op}, ending the case.
-module(erx_pcie_bcm2711_model).

-export([new/1, run/2, log/1, violations/1, firmware_register/1, link/1]).
-export([table/1, stored/1, effects/1, read/2, write/3, config_read/4, config_write/5]).

-include("generated/erx_hw_bcm2711_pcie.hrl").

-define(VERSION, 16#000138c1).
-define(SETTLE_US, 100000).

%% Options: boot (up: the boot firmware left the link up and PERST# released,
%% long ago; down: PERST# asserted; reset: the bridge turned off as section 6 leaves
%% it, PERST# asserted, the SerDes powered down and the bridge in reset; serdes_off:
%% that bridge with its reset released, as the probe's first step leaves it, section
%% 1, step 2), firmware (the VL805's version register at the
%% start, 0 for none), trains (whether the link comes up after a release), train_us,
%% endpoint (the block in endpoint mode), l23 (whether the link enters L23 when
%% asked), fall_at (the operation before which the link falls, or never), notify
%% (loads: the notification loads the firmware with the link up; {answer, A}: it
%% answers A and loads nothing).
new(Options) ->
    Boot = maps:get(boot, Options, down),
    #{regs => boot_registers(Boot),
      time => 0,
      release => case Boot of up -> -1000000; _PerstAsserted -> none end,
      fallen => false,
      firmware => maps:get(firmware, Options, 0),
      trains => maps:get(trains, Options, true),
      train_us => maps:get(train_us, Options, 20000),
      endpoint => maps:get(endpoint, Options, false),
      l23 => maps:get(l23, Options, true),
      fall_at => maps:get(fall_at, Options, never),
      notify => maps:get(notify, Options, loads),
      count => 0,
      index => none,
      log => [],
      violations => []}.

%% RGR1_SW_INIT_1 and HARD_DEBUG as the boot firmware left them.
boot_registers(up) -> #{rgr1_sw_init_1 => 0};
boot_registers(down) -> #{rgr1_sw_init_1 => ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_PERST_MASK};
boot_registers(reset) ->
    #{rgr1_sw_init_1 => ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_PERST_MASK bor ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_INIT_MASK,
      hard_debug => ?ERX_HW_BCM2711_PCIE_HARD_DEBUG_SERDES_IDDQ_MASK};
boot_registers(serdes_off) ->
    #{rgr1_sw_init_1 => ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_PERST_MASK,
      hard_debug => ?ERX_HW_BCM2711_PCIE_HARD_DEBUG_SERDES_IDDQ_MASK}.

%% Every operation the model executed, oldest first, as {Time, Op}.
log(#{log := Log}) -> lists:reverse(Log).

violations(#{violations := Violations}) -> lists:reverse(Violations).

firmware_register(#{firmware := Firmware}) -> Firmware.

link(Model) -> link_up(Model).

%% A model made with Options and kept in a new ets table, the device's handle.
table(Options) ->
    Table = ets:new(bcm2711, [public]),
    true = ets:insert(Table, {model, new(Options)}),
    Table.

%% The model the table holds now.
stored(Table) -> ets:lookup_element(Table, model, 2).

%% The seam's effects over the table: a sleep advances the model's clock and is logged
%% as a wait of that many milliseconds in microseconds; the notification is the model's.
effects(Table) ->
    #{sleep => fun(Milliseconds) -> through(Table, {wait, Milliseconds * 1000}) end,
      firmware => fun() -> through(Table, notify_firmware) end}.

read(Table, Register) -> through(Table, {read, Register}).
write(Table, Register, Word) -> through(Table, {write, Register, Word}).
config_read(Table, Space, Offset, Width) -> through(Table, {cfg_read, Space, Offset, Width}).
config_write(Table, Space, Offset, Width, Value) -> through(Table, {cfg_write, Space, Offset, Width, Value}).

%% One operation on the table's model, and its answer.
through(Table, Op) ->
    {Answer, Next} = op(Op, stored(Table)),
    true = ets:insert(Table, {model, Next}),
    Answer.

%% Drives a core from its first action to its result.
run(Model, {Core, {done, Result}}) ->
    {Result, Core, Model};
run(Model, {Core, Op}) ->
    {Answer, Next} = op(Op, Model),
    run(Next, erx_pcie_bcm2711_core:step(Answer, Core)).

%% One operation executed, counted and logged: its answer and the model after it.
op(Op, Model) ->
    true = in_space(Op),
    true = reachable(Op, Model),
    Counted = fall(Model#{count := maps:get(count, Model) + 1}),
    {Answer, Next} = apply_op(Op, Counted),
    {Answer, Next#{log := [{maps:get(time, Counted), Op} | maps:get(log, Next)]}}.

%% A configuration access stays aligned inside its space's 256 bytes, as the device
%% NIF refuses any other with badarg (erx_device_space_offset).
in_space({cfg_read, _Space, Offset, Width}) -> in_block(Offset, Width);
in_space({cfg_write, _Space, Offset, Width, _Value}) -> in_block(Offset, Width);
in_space(_Op) -> true.

in_block(Offset, Width) when Offset >= 0, Offset rem Width =:= 0, Offset + Width =< 256 -> true;
in_block(_Offset, _Width) -> error(badarg).

%% The bridge's reset and SerDes power decide which registers answer; any other access
%% hangs the bus (the module's comment).
reachable(Op, #{regs := Regs}) ->
    InReset = ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_INIT_GET(maps:get(rgr1_sw_init_1, Regs, 0)) =:= 1,
    PoweredDown = ?ERX_HW_BCM2711_PCIE_HARD_DEBUG_SERDES_IDDQ_GET(maps:get(hard_debug, Regs, 0)) =:= 1,
    case {target(Op), InReset, PoweredDown} of
        {none, _, _} -> true;
        {rgr1_sw_init_1, _, _} -> true;
        {hard_debug, false, _} -> true;
        {_, false, false} -> true;
        _ -> error({bus_hang, Op})
    end.

%% The register or configuration space an operation reaches; none for a wait or the
%% firmware notification, which reach no register.
target({read, Register}) -> Register;
target({write, Register, _Word}) -> Register;
target({cfg_read, Space, _Offset, _Width}) -> Space;
target({cfg_write, Space, _Offset, _Width, _Value}) -> Space;
target(_Op) -> none.

fall(#{count := Count, fall_at := Count} = Model) -> Model#{fallen := true};
fall(Model) -> Model.

apply_op({read, Register}, Model) ->
    {read_register(Register, Model), Model};
apply_op({write, Register, Word}, Model) ->
    {ok, write_register(Register, Word, Model)};
apply_op({wait, Microseconds}, #{time := Time} = Model) ->
    {ok, Model#{time := Time + Microseconds}};
apply_op({cfg_read, root_port, Offset, Width}, Model) ->
    {0, root_port(Offset, Width, Model)};
apply_op({cfg_read, ext_cfg_data, Offset, Width}, Model) ->
    endpoint_read(Offset, Width, Model);
apply_op({cfg_write, root_port, Offset, Width, _Value}, Model) ->
    {ok, root_port(Offset, Width, Model)};
apply_op({cfg_write, ext_cfg_data, Offset, _Width, _Value}, Model) ->
    {ok, endpoint_checked(Offset, Model)};
apply_op(notify_firmware, #{notify := {answer, Answer}} = Model) ->
    {Answer, Model};
apply_op(notify_firmware, Model) ->
    case link_up(Model) of
        true -> {ok, Model#{firmware := ?VERSION}};
        false -> {ok, Model}
    end.

root_port(Offset, Width, Model) when Offset rem Width =:= 0 -> Model.

endpoint_read(Offset, Width, Model) ->
    Checked = endpoint_checked(Offset, Model),
    Value = case {link_up(Model), Offset} of
                {false, _} -> stale(Model);
                {true, 16#50} -> maps:get(firmware, Model);
                {true, 0} -> 16#34831106;
                {true, _} -> 0
            end,
    {Value band (1 bsl (8 * Width) - 1), Checked}.

%% The VL805's last firmware version, or a version it never held: what a read
%% whose abort was lost may return.
stale(#{firmware := 0}) -> ?VERSION;
stale(#{firmware := Firmware}) -> Firmware.

endpoint_checked(Offset, #{index := Index, time := Time, release := Release} = Model) ->
    Violations = [{lockup, Index} || element(1, Index) =:= 0]
        ++ [{abort, Offset} || not link_up(Model)]
        ++ [{early_config, Time - Release} || is_integer(Release), Time - Release < ?SETTLE_US],
    violate(Violations, Model).

violate(New, #{violations := Old} = Model) -> Model#{violations := lists:reverse(New) ++ Old}.

read_register(misc_pcie_status, Model) ->
    Up = case link_up(Model) of true -> 1; false -> 0 end,
    L23 = case Up =:= 1 andalso maps:get(l23, Model) andalso l23_requested(Model) of true -> 1; false -> 0 end,
    Port = case maps:get(endpoint, Model) of
               true -> ?ERX_HW_BCM2711_PCIE_MISC_PCIE_STATUS_PORT_ENDPOINT;
               false -> ?ERX_HW_BCM2711_PCIE_MISC_PCIE_STATUS_PORT_ROOT_COMPLEX
           end,
    ?ERX_HW_BCM2711_PCIE_MISC_PCIE_STATUS_PHYLINKUP_PUT(Up) bor ?ERX_HW_BCM2711_PCIE_MISC_PCIE_STATUS_DL_ACTIVE_PUT(Up)
        bor ?ERX_HW_BCM2711_PCIE_MISC_PCIE_STATUS_LINK_IN_L23_PUT(L23)
        bor ?ERX_HW_BCM2711_PCIE_MISC_PCIE_STATUS_PORT_PUT(Port);
read_register(Register, #{regs := Regs}) ->
    maps:get(Register, Regs, 0).

write_register(ext_cfg_index, Word, Model) ->
    Index = {?ERX_HW_BCM2711_PCIE_EXT_CFG_INDEX_BUS_GET(Word), ?ERX_HW_BCM2711_PCIE_EXT_CFG_INDEX_DEVICE_GET(Word),
             ?ERX_HW_BCM2711_PCIE_EXT_CFG_INDEX_FUNCTION_GET(Word)},
    violate([{lockup, Index} || element(1, Index) =:= 0], Model#{index := Index});
write_register(rgr1_sw_init_1, Word, #{regs := Regs, time := Time} = Model) ->
    Was = ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_PERST_GET(maps:get(rgr1_sw_init_1, Regs, 0)),
    Now = ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_PERST_GET(Word),
    Stored = Model#{regs := Regs#{rgr1_sw_init_1 => Word}},
    case {Was, Now} of
        {_, 1} -> Stored#{firmware := 0, fallen := false, release := none};
        {1, 0} -> Stored#{release := Time};
        {0, 0} -> Stored
    end;
write_register(Register, Word, #{regs := Regs} = Model) ->
    Model#{regs := Regs#{Register => Word}}.

l23_requested(#{regs := Regs}) ->
    ?ERX_HW_BCM2711_PCIE_MISC_PCIE_CTRL_L23_REQUEST_GET(maps:get(misc_pcie_ctrl, Regs, 0)) =:= 1.

link_up(#{fallen := true}) -> false;
link_up(#{release := none}) -> false;
link_up(#{trains := false, release := Release}) -> Release < 0;
link_up(#{regs := Regs, time := Time, release := Release, train_us := Train}) ->
    Rgr1 = maps:get(rgr1_sw_init_1, Regs, 0),
    ?ERX_HW_BCM2711_PCIE_RGR1_SW_INIT_1_INIT_GET(Rgr1) =:= 0
        andalso ?ERX_HW_BCM2711_PCIE_HARD_DEBUG_SERDES_IDDQ_GET(maps:get(hard_debug, Regs, 0)) =:= 0
        andalso Time - Release >= Train.
