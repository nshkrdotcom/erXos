# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of a TCP socket process's packet framing,
# test/erlang/erx_net_packet_tests.erl: erx_net_packet's own cases, and the socket
# process's core against stock gen_tcp on the host's loopback for the same byte
# streams. Its seeded failure is a framing that looks for a line past the buffer, as
# stock's driver never does: a line longer than the buffer is then whole, not cut.
class ErxNetPacketTest < Minitest::Test
  include ErxNetEunit

  WINDOW = 'Window = binary:part(Bytes, 0, min(byte_size(Bytes), Buffer)),'
  NO_WINDOW = 'Window = Bytes,'

  def test_framing_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_net_packet_tests)
  end

  def test_a_line_looked_for_past_the_buffer_is_caught
    output = refute_erx_net_eunit(:erx_net_packet_tests, fault: { 'erx_net_packet' => [WINDOW, NO_WINDOW] })
    assert_match(/line_window/, output)
  end
end
