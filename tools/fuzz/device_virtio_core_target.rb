# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The split ring's form core over the sequencer against a hostile device and any
# post's pieces. Scripts in tools/fuzz/device_virtio_core_fuzz.c's format: a block
# request's chain of a header, data and a status byte, completed whole and short; a
# used index, a used id and a used len each beyond what was posted; pieces empty, out
# of order and past a buffer; a ring too small for the chain; two completions where
# bytes_max takes one; a memory at the top of the address space; and a reset after a
# broken ring.
piece = ->(length, writes) { [length, writes].pack('vC') }
request = [0, 3].pack('CC') + piece.(16, 0) + piece.(512, 1) + piece.(1, 1)
whole = [0, 1].pack('CC') + piece.(1024, 1)
index = [2, 1, 32].pack('CCC')
honest = ->(length, bytes_max: 65_536) { [3, 1, 1, 0].pack('CCCC') + [length, bytes_max].pack('VV') }
# A ring of 4 entries with buffers of 1024 bytes and a granule of 64, low in the address space.
setup = [2, 1023, 0].pack('CvC')
Erx::PackFuzz.declare_target(
  sources: %w[erx_device_ledger.c erx_device_rules.c erx_device_sequencer.c erx_device_virtio_core.c]
    .map { |source| "otp/erts/emulator/nifs/erxos/#{source}" },
  includes: [*Erx::PackFuzz::INCLUDES, '.', 'otp/erts/emulator/nifs/erxos'],
  seeds: {
    'request' => setup + request + index + honest.(513),
    'short' => setup + request + index + honest.(100),
    'liar-index' => setup + request + [1, 0xffff, 32].pack('CvC') + request,
    'liar-id' => setup + request + index + [3, 1, 0, 9, 1, 65_536].pack('CCCVVV') + request,
    'liar-length' => setup + request + index + honest.(0x80000258),
    'pieces' => setup + [0, 2].pack('CC') + piece.(4, 1) + piece.(4, 0) + [0, 2].pack('CC') + piece.(8, 0) +
                piece.(0, 1) + [0, 2].pack('CC') + piece.(1000, 1) + piece.(1000, 1) + [0, 5].pack('CC'),
    'full' => [0, 1023, 0].pack('CvC') + request + [0, 1].pack('CC') + piece.(8, 1) + [0, 1].pack('CC') +
              piece.(8, 1),
    'limits' => setup + whole + whole + [2, 2, 32].pack('CCC') + [3, 2, 1, 0, 1024, 1, 1, 1024, 1].pack('CCCCVCCVV'),
    'top' => [2, 63, 3].pack('CvC') + [0, 1].pack('CC') + piece.(64, 1) + index + honest.(64),
    'reset' => setup + request + [1, 7, 32].pack('CvC') + [4].pack('C') + request + index + honest.(513)
  }
)
