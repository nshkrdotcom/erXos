# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The TRB form's event ring processing over the sequencer against a hostile controller.
# Scripts in tools/fuzz/device_trb_form_fuzz.c's format: transfers completed honestly,
# short and whole; a short data stage then its status stage; a pointer one TRB off; a raw
# event of an unknown type; a stale cycle bit; a burst of port events; and a reset after
# a broken form.
post = ->(kind) { [0, kind].pack('CC') }
events = ->(*each) { [1, each.size].pack('CC') + each.join }
honest = ->(transfer, residue: 0, short: false, before: false, stale: false) do
  [1 | (short ? 2 : 0) | (before ? 4 : 0) | (stale ? 8 : 0), transfer, residue].pack('CCC')
end
raw = ->(parameter, status, control) { [0, parameter, status, control].pack('CQ<VV') }
port = raw.(1 << 24, 1 << 24, 0x22 << 10)
Erx::PackFuzz.declare_target(
  sources: %w[erx_device_ledger.c erx_device_rules.c erx_device_sequencer.c erx_device_trb.c erx_device_trb_form.c]
    .map { |source| "otp/erts/emulator/nifs/erxos/#{source}" },
  includes: [*Erx::PackFuzz::INCLUDES, '.', 'otp/erts/emulator/nifs/erxos'],
  seeds: {
    'bulk' => post.(2) + post.(3) + events.(honest.(1), honest.(0, residue: 3, short: true)),
    'control' => post.(0) + events.(honest.(0, residue: 5, short: true, before: true), honest.(0)),
    'one-off' => post.(1) + events.(honest.(0, before: true)),
    'unknown' => post.(2) + events.(raw.(0, 0, 0x25 << 10)),
    'stale' => post.(2) + events.(honest.(0, stale: true), honest.(0)),
    'ports' => events.(*Array.new(32) { port }),
    'reset' => post.(2) + events.(honest.(0, residue: 200)) + [2].pack('C') + post.(2) + events.(honest.(0))
  }
)
