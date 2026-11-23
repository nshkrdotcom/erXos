# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the Raspberry Pi 4 Ethernet driver's pure cores:
# test/erlang/erx_genet_rx_tests.erl (the receive completion decision),
# erx_genet_core_tests.erl (the transport's sequences, checked against the SVD source
# whose path it is given as ERX_GENET_SVD, and its address, bound and cuts) and
# erx_phy_c22_tests.erl (the PHY machine against erx_phy_bcm54213_model, and the
# MDIO command word), then plants each fault the cases exist to catch and
# requires them to fail.
class ErxGenetCoresTest < Minitest::Test
  include ErxNetEunit

  SOURCES = %w[erlang/apps/erx_net/erxos/erx_genet_rx.erl erlang/apps/erx_net/erxos/erx_mdio.erl
               erlang/apps/erx_net/erxos/erx_phy_c22.erl erlang/apps/erx_net/erxos/erx_genet_core.erl].freeze
  TESTS = %i[erx_genet_rx_tests erx_phy_c22_tests erx_genet_core_tests].freeze
  SVD = File.expand_path('../../hw/svd/genet/genet.svd', __dir__)
  EXTRA = %w[erx_phy_bcm54213_model].freeze

  # Each seeded fault: the module, the exact text it replaces and the faulty text.
  FAULTS = {
    'the padding not subtracted from the length' =>
      ['erx_genet_rx', 'binary:part(Bytes, ?PAD, byte_size(Bytes) - ?PAD)', 'binary:part(Bytes, ?PAD, byte_size(Bytes))'],
    'only the receive-error bit dropping a frame' =>
      ['erx_genet_rx', 'Status band ?STATUS_ERROR_MASK =/= 0', 'Status band 16#0004 =/= 0'],
    'a length past the buffer not dropped as too_long' =>
      ['erx_genet_rx', '?ERX_HW_GENET_RX_DESC_STATUS_BUFLEN_GET(Status) > byte_size(Bytes) -> {drop, too_long};', ''],
    'a status past 32 bits taken' =>
      ['erx_genet_rx', 'Status >= 0, Status =< 16#ffffffff, is_binary(Bytes)', 'Status >= 0, is_binary(Bytes)'],
    'a frame past the MTU passed up' =>
      ['erx_genet_core', '{frame, _Long} -> {[{dropped, too_long} | Drops], Frames};', '{frame, Long} -> {Drops, [Long | Frames]};'],
    'the DMA stop left out of the reset' =>
      ['erx_genet_core', '{wait_us, ?FRAME_US}, dma_stop]', '{wait_us, ?FRAME_US}]'],
    'the alignment and size control written before the receive buffer reset' =>
      ['erx_genet_core', "        ++ held_settings() ++\n", "        ++ held_settings() ++ buffer_settings() ++\n"],
    'the ring buffers longer than the largest frame' =>
      ['erx_genet_core', 'buffer() -> ?MAX_FRAME_LEN.', 'buffer() -> 2048.'],
    'a ring setting left out' =>
      ['erx_genet_core', "{write, {tx_ring_mbuf_done_thres, ?RING}, ?TX_MBUF_DONE_THRES},\n", ''],
    'a field the SVD does not name' =>
      ['erx_genet_core', '{field, ext_rgmii_oob_ctrl, rgmii_link, 1}', '{field, ext_rgmii_oob_ctrl, link, 1}'],
    'a later link-up leaving the MAC running' =>
      ['erx_genet_core', "link_up(Speed) ->\n    [{field, umac_cmd, rxen, 0}, {field, umac_cmd, txen, 0}, {wait_us, ?FRAME_US},\n     {field, umac_cmd, sw_reset, 1}, {wait_us, ?RESET_US},\n", "link_up(Speed) ->\n    ["],
    'receive enabled before the link speed' =>
      ['erx_genet_core', '{field, umac_cmd, sw_reset, 1}, {wait_us, ?RESET_US},',
       '{field, umac_cmd, sw_reset, 1}, {wait_us, ?RESET_US}, {field, umac_cmd, rxen, 1},'],
    'a full receive ring blamed on its index' =>
      ['erx_genet_core', 'Ahead when Ahead > ?ERX_GENET_RING_SIZE ->',
       'Ahead when Ahead >= ?ERX_GENET_RING_SIZE ->'],
    'the latched link bit read once' =>
      ['erx_phy_c22', 'Up = Now band ?BMSR_LINK =/= 0', 'Up = Latched band ?BMSR_LINK =/= 0']
  }.freeze

  def setup
    ENV['ERX_GENET_SVD'] = SVD
  end

  def test_genet_core_cases_pass_under_eunit
    assert_erx_net_eunit(*TESTS, extra: EXTRA, sources: SOURCES)
  end

  FAULTS.each do |name, (module_name, exact, faulty)|
    define_method("test_cases_catch_#{name.tr(' ', '_')}") do
      refute_erx_net_eunit(*TESTS, fault: { module_name => [exact, faulty] }, extra: EXTRA, sources: SOURCES)
    end
  end
end
