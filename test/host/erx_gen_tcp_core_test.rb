# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the socket protocol's pure parts,
# test/erlang/erx_gen_tcp_core_tests.erl, and three seeded failures: of the credit rule,
# a socket process that grants again only once all it granted is pushed, so the
# connection idles while each grant travels; and of the end in passive mode, a socket
# process that drops what it holds and the error once the connection is gone, so an
# owner whose `{active, once}` ran out never sees them when it re-arms; and of the
# credit for a packet, a socket process that grants at once only for a recv of a
# length, so a passive line mode waits forever on a partial line it holds; and of a
# partial line not framed again, one that never looks for the newline a push brings.
class ErxGenTcpCoreTest < Minitest::Test
  include ErxNetEunit

  HALF_TARGET = 'Short >= Target div 2 orelse Waits'
  WHOLE_TARGET = 'Short >= Target orelse Waits'
  PACKET_WAITS = 'Waits = Need > Held + Out orelse (Recv =/= none andalso Held + Out =:= 0),'
  RECV_WAITS = 'Waits = Recv =/= none andalso (RecvLength > Held + Out orelse Held + Out =:= 0),'
  NEWLINE_LOOKED_FOR = 'arrived(Wait, Pieces) -> erx_net_packet:arrived(Wait, Pieces).'
  NEWLINE_MISSED = 'arrived(Wait, _Pieces) -> Wait.'
  END_WAITS = "%% Passive after an error: the connection is gone, and the end waits for the owner.\n    close_out(C, Acts)."
  END_DROPPED = "%% Passive after an error: the connection is gone, and the end waits for the owner.\n    close_out(discard(C#core{ended = none}), Acts)."

  def test_socket_protocol_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_gen_tcp_core_tests)
  end

  def test_an_end_dropped_in_passive_mode_is_caught
    output = refute_erx_net_eunit(:erx_gen_tcp_core_tests, fault: { 'erx_gen_tcp_core' => [END_WAITS, END_DROPPED] })
    assert_match(/once_spent_error/, output)
  end

  def test_a_grant_only_at_the_whole_target_is_caught
    output = refute_erx_net_eunit(:erx_gen_tcp_core_tests, fault: { 'erx_gen_tcp_core' => [HALF_TARGET, WHOLE_TARGET] })
    assert_match(/credit_at_half_target/, output)
  end

  def test_credit_only_for_a_recv_of_a_length_is_caught
    output = refute_erx_net_eunit(:erx_gen_tcp_core_tests, fault: { 'erx_gen_tcp_core' => [PACKET_WAITS, RECV_WAITS] })
    assert_match(/partial_line_credit/, output)
  end

  def test_a_partial_line_missing_a_pushed_newline_is_caught
    output = refute_erx_net_eunit(:erx_gen_tcp_core_tests,
                                  fault: { 'erx_gen_tcp_core' => [NEWLINE_LOOKED_FOR, NEWLINE_MISSED] })
    assert_match(/line_byte_by_byte/, output)
  end
end
