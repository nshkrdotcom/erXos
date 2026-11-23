%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the Raspberry Pi 4 Ethernet transport's pure decisions,
%% erx_genet_core. Every step of every sequence is checked against the controller's
%% SVD source, hw/svd/genet/genet.svd, whose path test/host/erx_genet_cores_test.rb
%% passes as ERX_GENET_SVD: the register and field exist, the NIF does not own the
%% register, the register is writable and the value fits the field. Then the address
%% choice, the negotiate bound, the receive cut and the transmit pieces at their
%% boundaries.

-module(erx_genet_core_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("xmerl/include/xmerl.hrl").
-include("generated/erx_abi.hrl").
-include("generated/erx_hw_genet.hrl").

-define(SOP, (1 bsl 13)).
-define(EOP, (1 bsl 14)).
-define(WHOLE, (?SOP bor ?EOP)).

%% --- The sequences against the SVD source ----------------------------------------------

%% #{Register => {Owned, Access, #{Field => Width}, Dim}}, names lower-cased as the NIF
%% takes them, an array's without its "[%s]" and Dim its element count, 1 for a register
%% that is not an array.
svd() ->
    {Doc, _} = xmerl_scan:file(os:getenv("ERX_GENET_SVD"), [{quiet, true}]),
    maps:from_list([register(R) || R <- xmerl_xpath:string("//register", Doc)]).

register(R) ->
    Fields = maps:from_list([{name(F), list_to_integer(text("bitWidth", F))}
                             || F <- xmerl_xpath:string("fields/field", R)]),
    Dim = case xmerl_xpath:string("dim/text()", R) of
              [] -> 1;
              [#xmlText{value = D}] -> list_to_integer(D)
          end,
    {name(R), {text("ownedByNif", R) =:= "true", text("access", R), Fields, Dim}}.

name(E) ->
    Lower = string:lowercase(text("name", E)),
    list_to_atom(lists:flatten(string:replace(Lower, "[%s]", "", all))).

text(Tag, E) ->
    [#xmlText{value = V}] = xmerl_xpath:string(Tag ++ "/text()", E),
    V.

sequences() ->
    erx_genet_core:reset() ++ erx_genet_core:configure(<<2, 0, 0, 0, 0, 1>>) ++ erx_genet_core:start()
        ++ lists:append([erx_genet_core:link_up(S) || S <- [10, 100, 1000]]).

every_step_names_a_writable_register_and_field_of_the_svd_test() ->
    Svd = svd(),
    [check_step(Step, Svd) || Step <- sequences()].

check_step(dma_stop, _Svd) ->
    ok;
check_step({wait_us, Us}, _Svd) ->
    ?assert(is_integer(Us) andalso Us > 0);
check_step({write, Reg, Value} = Step, Svd) ->
    {Owned, Access, _Fields} = lookup(Reg, Svd),
    ?assertEqual({Step, false, true, true},
                 {Step, Owned, Access =/= "read-only", Value >= 0 andalso Value =< 16#ffffffff});
check_step({field, Reg, Field, Value} = Step, Svd) ->
    {Owned, Access, Fields} = lookup(Reg, Svd),
    Width = maps:get(Field, Fields),
    ?assertEqual({Step, false, true, true},
                 {Step, Owned, Access =/= "read-only", Value >= 0 andalso Value < (1 bsl Width)}).

%% A plain name is a register that is not an array; {Name, Element} an element of one.
lookup({Reg, Element}, Svd) ->
    {Owned, Access, Fields, Dim} = maps:get(Reg, Svd),
    ?assert(Dim > 1 andalso is_integer(Element) andalso Element >= 0 andalso Element < Dim),
    {Owned, Access, Fields};
lookup(Reg, Svd) ->
    {Owned, Access, Fields, Dim} = maps:get(Reg, Svd),
    ?assertEqual({Reg, 1}, {Reg, Dim}),
    {Owned, Access, Fields}.

%% The ring settings FreeBSD writes in gen_init_txring and gen_init_rxring that are the
%% driver's, not the NIF's (if_genet.c:738, 752-753, 784, 798-799), with FreeBSD's
%% values, for the ring the NIF drives, the ABI's ERX_GENET_RING, and the receive
%% XON/XOFF high threshold FreeBSD derives from its descriptor count, RX_DESC_COUNT >> 4.
configure_writes_freebsds_ring_settings_for_the_nifs_ring_test() ->
    Steps = erx_genet_core:configure(<<2, 0, 0, 0, 0, 1>>),
    Ring = ?ERX_GENET_RING,
    [?assertEqual({S, true}, {S, lists:member(S, Steps)})
     || S <- [{write, tx_scb_burst_size, 8},
              {write, {tx_ring_mbuf_done_thres, Ring}, 1},
              {write, {tx_ring_flow_period, Ring}, 0},
              {write, rx_scb_burst_size, 8},
              {field, {rx_ring_xon_xoff_thres, Ring}, lo, 5},
              {field, {rx_ring_xon_xoff_thres, Ring}, hi, ?ERX_GENET_RING_SIZE bsr 4}]].

%% A restart finds the controller as a predecessor that ended left it, receiving: the MAC's
%% receive and transmit are turned off, a full frame's time passes, and both DMA engines are stopped and
%% the stop confirmed, all before the receive buffer's reset or the MAC's, so neither lands
%% while the MAC hands a frame to the receive engine or an engine runs (the GENET facts
%% record, "Stopping the DMA and confirming it stopped"). The stop is made once, there, so
%% configure/1's ring settings, which follow the reset, are written to stopped engines.
reset_stops_the_mac_and_both_dma_engines_before_any_reset_test() ->
    {Quiesce, _Reset} = lists:split(4, erx_genet_core:reset()),
    ?assertMatch([{field, umac_cmd, rxen, 0}, {field, umac_cmd, txen, 0}, {wait_us, Us}, dma_stop]
                     when Us >= 2000, Quiesce),
    ?assertEqual([dma_stop], [S || dma_stop = S <- sequences()]).

%% After the stop, reset/0 turns both status blocks and the receive checksum check off, the
%% values the UEFI firmware's driver runs with after the Pi 4's boot loader, which leaves
%% all three 0 and which that driver never writes; then it is that driver's GenetReset,
%% write for write (edk2-platforms 4db2845d1442,
%% Silicon/Broadcom/Drivers/Net/BcmGenetDxe/GenetUtil.c:300-335): the receive buffer's
%% reset pulsed, 10 us each side, and its flush control written 0; the MAC's command
%% register written 0, then software reset with local loopback in one write for 10 us,
%% then 0, which releases it with CRC forward clear, so no FCS is counted in a receive
%% length; the MIB counters cleared in one write; the largest frame; the 2-byte alignment;
%% and the size control 1, the very last write.
reset_after_the_stop_is_edk2s_genet_reset_test() ->
    {_Quiesce, Reset} = lists:split(4, erx_genet_core:reset()),
    ?assertEqual(held_settings() ++
                 [{field, sys_rbuf_flush_ctrl, reset, 1}, {wait_us, 10},
                  {field, sys_rbuf_flush_ctrl, reset, 0}, {wait_us, 10},
                  {write, sys_rbuf_flush_ctrl, 0}, {wait_us, 10},
                  {write, umac_cmd, 0},
                  {write, umac_cmd, ?ERX_HW_GENET_UMAC_CMD_LCL_LOOP_EN_MASK bor
                                    ?ERX_HW_GENET_UMAC_CMD_SW_RESET_MASK},
                  {wait_us, 10},
                  {write, umac_cmd, 0},
                  {write, umac_mib_ctrl, ?ERX_HW_GENET_UMAC_MIB_CTRL_RESET_RUNT_MASK bor
                                         ?ERX_HW_GENET_UMAC_MIB_CTRL_RESET_RX_MASK bor
                                         ?ERX_HW_GENET_UMAC_MIB_CTRL_RESET_TX_MASK},
                  {write, umac_mib_ctrl, 0},
                  {field, umac_max_frame_len, length, 1536},
                  {field, rbuf_ctrl, align_2b, 1},
                  {field, rbuf_tbuf_size_ctrl, size, 1}], Reset),
    ?assertEqual([], [S || {field, _, crc_fwd, _} = S <- sequences()]).

%% Neither the UEFI firmware's driver's initialization nor FreeBSD's flushes the transmit
%% path or the receive buffer (GenetUtil.c:300-335 and SimpleNetwork.c:147-167;
%% if_genet.c:488-514, 900-942), so no sequence of erx_genet_core does: no write of the
%% UniMAC's transmit flush, and no write that sets the receive buffer's flush bit.
no_sequence_flushes_a_buffer_test() ->
    ?assertEqual([], [S || S <- sequences(), flushes(S)]).

flushes({write, umac_tx_flush, _}) -> true;
flushes({field, sys_rbuf_flush_ctrl, flush, _}) -> true;
flushes({write, sys_rbuf_flush_ctrl, Word}) ->
    Word band ?ERX_HW_GENET_SYS_RBUF_FLUSH_CTRL_FLUSH_MASK =/= 0;
flushes(_Step) -> false.

%% Nothing after reset/0, in configure/1, start/0 or link_up/1, writes a buffer setting
%% again: the size control, above all, changes from what a boot stage left only where the
%% UEFI firmware's driver changes it.
no_buffer_setting_follows_the_reset_test() ->
    Buffers = [Register || {field, Register, _, _} <- held_settings() ++ edk2_settings()],
    After = erx_genet_core:configure(<<2, 0, 0, 0, 0, 1>>) ++ erx_genet_core:start()
        ++ lists:append([erx_genet_core:link_up(S) || S <- [10, 100, 1000]]),
    ?assertEqual([], [S || S <- After, is_tuple(S), lists:member(element(2, S), Buffers)]).

%% Both rings' buffers are as long as the largest frame, 1,536 bytes, the UEFI firmware's
%% driver's one GENET_MAX_PACKET_SIZE (BcmGenetDxe.h:55), which it writes as the largest
%% frame and as both rings' buffer length (GenetUtil.c:328, 560-562, 582-584). A frame of
%% the MTU, its Ethernet header, a VLAN tag and the 2-byte pad fits one buffer.
the_rings_buffers_are_the_largest_frame_long_test() ->
    Buffer = erx_genet_core:buffer(),
    ?assertEqual(1536, Buffer),
    ?assert(lists:member({field, umac_max_frame_len, length, Buffer}, erx_genet_core:reset())),
    ?assert(2 + 14 + 4 + 1500 =< Buffer).

%% The settings reset/0 writes before that driver's reset, the values it runs with.
held_settings() ->
    [{field, rbuf_ctrl, status_64b, 0}, {field, rbuf_check_ctrl, en, 0},
     {field, tbuf_ctrl, status_64b, 0}].

%% That driver's own two buffer settings (GenetUtil.c:330-334).
edk2_settings() ->
    [{field, rbuf_ctrl, align_2b, 1}, {field, rbuf_tbuf_size_ctrl, size, 1}].

%% What the driver reads back after reset/0 is every buffer setting it wrote, field and
%% value, so a reset that restores a register is caught before a frame is misread.
the_buffer_check_reads_back_every_buffer_setting_test() ->
    ?assertEqual(lists:sort([{R, F, V} || {field, R, F, V} <- held_settings() ++ edk2_settings()]),
                 lists:sort(erx_genet_core:buffer_check())).

%% The bits the Pi 4's boot loader leaves set (RBUF_CTRL 0xc040, EXT_RGMII_OOB_CTRL
%% 0xf00000, both read on the board before any write) that FreeBSD's header does not name
%% lie in writable fields of the SVD, so a field write keeps them as it read them, as
%% FreeBSD's read-modify-write does, rather than writing them back as zero.
the_bits_the_boot_loader_leaves_set_survive_a_field_write_test() ->
    [?assertEqual({Reg, Set}, {Reg, Set band field_bits(Reg)})
     || {Reg, Set} <- [{rbuf_ctrl, 16#c040}, {ext_rgmii_oob_ctrl, 16#f00000}]].

%% The bits the writable fields of register `Reg` cover.
field_bits(Reg) ->
    {Doc, _} = xmerl_scan:file(os:getenv("ERX_GENET_SVD"), [{quiet, true}]),
    [R] = [R || R <- xmerl_xpath:string("//register", Doc), name(R) =:= Reg],
    lists:foldl(fun(F, Mask) ->
                        Offset = list_to_integer(text("bitOffset", F)),
                        Width = list_to_integer(text("bitWidth", F)),
                        Mask bor (((1 bsl Width) - 1) bsl Offset)
                end, 0, [F || F <- xmerl_xpath:string("fields/field", R),
                             xmerl_xpath:string("access[text()='read-only']", F) =:= []]).

start_enables_both_directions_and_only_the_dma_interrupts_test() ->
    Start = erx_genet_core:start(),
    [?assert(lists:member(S, Start))
     || S <- [{field, umac_cmd, txen, 1}, {field, umac_cmd, rxen, 1},
              {field, intrl2_cpu_clear_mask, rxdma_done, 1},
              {field, intrl2_cpu_clear_mask, txdma_done, 1}]],
    %% Everything is masked before the two are unmasked.
    {Before, _} = lists:splitwith(fun(S) -> S =/= {field, intrl2_cpu_clear_mask, rxdma_done, 1} end, Start),
    ?assert(lists:member({write, intrl2_cpu_set_mask, 16#ffffffff}, Before)).

configure_writes_the_address_in_freebsds_order_test() ->
    Steps = erx_genet_core:configure(<<16#dc, 16#a6, 16#32, 16#01, 16#02, 16#03>>),
    ?assert(lists:member({field, umac_mac0, addr, 16#dca63201}, Steps)),
    ?assert(lists:member({field, umac_mac1, addr, 16#0203}, Steps)),
    ?assert(lists:member({field, umac_cmd, promisc, 1}, Steps)).

link_up_sets_the_speed_code_test() ->
    [?assertEqual({field, umac_cmd, speed, Code}, lists:last(erx_genet_core:link_up(Speed)))
     || {Speed, Code} <- [{10, 0}, {100, 1}, {1000, 2}]].

%% --- Identification and the address -------------------------------------------------------

identify_takes_only_v5_test() ->
    ?assertEqual(ok, erx_genet_core:identify(6)),
    ?assertEqual({error, {revision, 5}}, erx_genet_core:identify(5)),
    ?assertEqual({error, {revision, 15}}, erx_genet_core:identify(15)).

-define(ENTROPY, <<16#ff, 1, 2, 3, 4, 5>>).
-define(RANDOM, <<16#fe, 1, 2, 3, 4, 5>>).  % local bit set, group bit clear

%% The fields the address reads (#{Register => Value}) as the firmware leaves them: the
%% receive buffer's reset clear and its address in MAC0 and MAC1, with Changes over them.
firmware(Changes) ->
    maps:merge(#{sys_rbuf_flush_ctrl => 0, umac_mac0 => 16#dca63201, umac_mac1 => 16#0203}, Changes).

%% Runs lladdr/1's steps over the controller's fields and ?ENTROPY, checking each read
%% against the SVD source, and returns the address and what was read or drawn, in order.
address(Record, Controller) ->
    address(erx_genet_core:lladdr(Record), Controller, svd(), []).

address({done, Address}, _Controller, _Svd, Taken) ->
    {Address, lists:reverse(Taken)};
address({read, Register, Field, Next}, Controller, Svd, Taken) ->
    {_Owned, Access, Fields} = lookup(Register, Svd),
    ?assertEqual({Register, Field, true, true},
                 {Register, Field, Access =/= "write-only", maps:is_key(Field, Fields)}),
    address(Next(maps:get(Register, Controller)), Controller, Svd, [Register | Taken]);
address({entropy, Next}, Controller, Svd, Taken) ->
    address(Next(?ENTROPY), Controller, Svd, [entropy | Taken]).

the_address_comes_from_the_record_then_the_controller_then_entropy_test() ->
    Words = [sys_rbuf_flush_ctrl, umac_mac0, umac_mac1],
    Firmware = firmware(#{}),
    Cases = [%% A usable record reads no register and draws nothing.
             {16#dca6320a0b0c, Firmware, {<<16#dc, 16#a6, 16#32, 16#0a, 16#0b, 16#0c>>, []}},
             {none, Firmware, {<<16#dc, 16#a6, 16#32, 16#01, 16#02, 16#03>>, Words}},
             %% While the receive buffer's reset holds the UniMAC, its address registers
             %% are not read at all (if_genet.c:465-469).
             {none, firmware(#{sys_rbuf_flush_ctrl => 1}), {?RANDOM, [sys_rbuf_flush_ctrl, entropy]}},
             {none, firmware(#{umac_mac0 => 0, umac_mac1 => 0}), {?RANDOM, Words ++ [entropy]}},
             %% A group address from the record or the controller is not used.
             {16#010000000001, Firmware, {<<16#dc, 16#a6, 16#32, 16#01, 16#02, 16#03>>, Words}},
             {none, firmware(#{umac_mac0 => 16#01000000, umac_mac1 => 1}), {?RANDOM, Words ++ [entropy]}}],
    [?assertEqual({Record, Controller, Want}, {Record, Controller, address(Record, Controller)})
     || {Record, Controller, Want} <- Cases].

%% --- the stop's bound ------------------------------------------------------------------------

the_stop_is_retried_within_its_bound_test() ->
    Answers = [erx_genet_core:stop_retry(N) || N <- lists:seq(1, 25)],
    {Retries, Failures} = lists:splitwith(fun(A) -> A =:= {retry, 1} end, Answers),
    ?assertEqual(19, length(Retries)),
    ?assertEqual(lists:duplicate(6, {error, stop_timeout}), Failures).

%% --- What a broken queue and a failed stop show -----------------------------------------------

%% Each register the evidence names is one the driver may read: in the SVD source, not
%% write-only, an array's element within its dimension.
the_evidence_names_readable_registers_of_the_svd_test() ->
    Svd = svd(),
    [begin
         {_Owned, Access, _Fields} = lookup(Reg, Svd),
         ?assertNotEqual({Reg, "write-only"}, {Reg, Access})
     end || Reg <- erx_genet_core:evidence()],
    %% Both directions' DMA control and status, and both rings' two indexes.
    ?assertEqual(8, length(lists:usort(erx_genet_core:evidence()))).

%% The evidence's words with the receive ring's producer and consumer index words.
rx_fault(ProdWord, Cons) ->
    erx_genet_core:rx_fault([{rx_dma_status, 1}, {{rx_ring_prod_index, ?ERX_GENET_RING}, ProdWord},
                             {{rx_ring_cons_index, ?ERX_GENET_RING}, Cons}]).

a_producer_index_past_the_ring_is_the_index_fault_test() ->
    Ring = ?ERX_GENET_RING_SIZE,
    Cases = [%% A full ring is no fault of the index.
             {5, 5 + Ring, unexplained},
             {5, 5 + Ring + 1, {index, Ring + 1}},
             %% The 16-bit indexes wrap.
             {16#fff0, (16#fff0 + Ring + 1) band 16#ffff, {index, Ring + 1}},
             {16#fff0, (16#fff0 + 3) band 16#ffff, unexplained},
             %% A producer behind the consumer is far ahead modulo 2^16.
             {7, 6, {index, 16#ffff}},
             %% The producer word's upper half counts discarded frames, not the index.
             {5, (16#0007 bsl 16) bor (5 + Ring), unexplained}],
    [?assertEqual({Cons, Prod, Want}, {Cons, Prod, rx_fault(Prod, Cons)})
     || {Cons, Prod, Want} <- Cases].

%% --- Receiving -----------------------------------------------------------------------------

frame_bytes(Size) -> list_to_binary([I rem 251 || I <- lists:seq(0, Size - 1)]).

%% A completion as the device NIF hands it up: a status of Flags and Size bytes, and
%% those bytes, none when Size passes the 2 KiB buffer.
completion(Flags, Size) when Size > 2048 -> {(Size bsl 16) bor Flags, <<>>};
completion(Flags, Size) -> {(Size bsl 16) bor Flags, frame_bytes(Size)}.

receive_completions_are_cut_at_their_boundaries_test() ->
    Max = 2 + 1514,
    Cases = [{completion(?WHOLE, Max), {[], [binary:part(frame_bytes(Max), 2, 1514)]}},
             {completion(?WHOLE, Max + 1), {[{dropped, too_long}], []}},
             {completion(?WHOLE, 16), {[], [binary:part(frame_bytes(16), 2, 14)]}},
             {completion(?WHOLE, 15), {[{dropped, runt}], []}},
             {completion(?WHOLE bor 2, 64), {[{dropped, crc_error}], []}},
             {completion(?SOP, 64), {[{dropped, fragment}], []}},
             %% Past the buffer, as far as a 16-bit length can say, and a status the board showed.
             {completion(?WHOLE, 2049), {[{dropped, too_long}], []}},
             {completion(?WHOLE, 16#ffff), {[{dropped, too_long}], []}},
             {{16#2d764800, <<>>}, {[{dropped, too_long}], []}}],
    [?assertEqual({C, Want}, {C, erx_genet_core:frames([C], 1500)}) || {C, Want} <- Cases],
    %% A status past 32 bits only if the NIF broke its contract: refused.
    ?assertError(function_clause, erx_genet_core:frames([{1 bsl 32, frame_bytes(64)}], 1500)).

a_batch_keeps_frames_and_drops_in_order_test() ->
    A = frame_bytes(80), B = frame_bytes(90),
    ?assertEqual({[{dropped, overflow}, {dropped, fragment}],
                  [binary:part(A, 2, 78), binary:part(B, 2, 88)]},
                 erx_genet_core:frames([completion(?WHOLE, 80), completion(?WHOLE bor 1, 80),
                                        completion(?EOP, 90), completion(?WHOLE, 90)], 1500)).

%% --- Transmitting ----------------------------------------------------------------------------

pieces_are_at_most_four_and_keep_the_bytes_test() ->
    Frames = [<<1, 2, 3>>, [<<1>>, <<>>, <<2, 3>>], [<<"a">>, [<<"b">>, $c], <<"d">>, <<"e">>, <<"f">>],
              [<<"h">>, <<"i">>, <<"j">>, <<"k">>]],
    [begin
         Pieces = erx_genet_core:pieces(F),
         ?assert(length(Pieces) =< 4),
         ?assertEqual([], [P || {out, P} <- Pieces, P =:= <<>>]),
         Bytes = iolist_to_binary(F),
         ?assertEqual(<<Bytes/binary, 0:((max(60, byte_size(Bytes)) - byte_size(Bytes)) * 8)>>,
                      iolist_to_binary([P || {out, P} <- Pieces]))
     end || F <- Frames],
    Long = [<<0:(60 * 8)>>, <<"a">>, [<<"b">>, $c], <<"d">>, <<"e">>],
    ?assertEqual([{out, <<0:(60 * 8), "ab">>}, {out, <<"c">>}, {out, <<"d">>}, {out, <<"e">>}],
                 erx_genet_core:pieces(Long)).

a_short_frame_is_padded_with_zeros_to_60_bytes_test() ->
    [?assertEqual({Size, <<(frame_bytes(Size))/binary, 0:((max(60, Size) - Size) * 8)>>},
                  {Size, iolist_to_binary([P || {out, P} <- erx_genet_core:pieces(frame_bytes(Size))])})
     || Size <- [14, 59, 60, 61]],
    ?assertEqual([{out, frame_bytes(60)}], erx_genet_core:pieces(frame_bytes(60))).
