# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../fixtures/xhci_core_cases'

# Runs test/erlang/erx_xhci_core_tests.erl, the controller core's pipe machine,
# reset_pipe's table, a device's teardown and a control request's abort explored to a
# fixed point against a model of the NIF's queue states, the failed Address Device
# explored the same way, a device's configuration explored for each count of pipes, the
# traces of each, the bus commands and the decoders, against
# the module compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies). Seeded faults, each applied to a copy of the module, are in
# erx_xhci_core_seeds_test.rb, in a file of their own so each gets its own deadline.
class ErxXhciCoreTest < Minitest::Test
  def test_xhci_core_cases_pass_under_eunit
    output, status = XhciCoreCases.run
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end
end
