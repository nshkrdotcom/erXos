# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The device NIF's register layout over xHCI's table against a hostile controller. Seeds in
# tools/fuzz/device_xhci_regs_fuzz.c's format: a controller with legacy support and two
# protocols; doorbells past the window; a misaligned CAPLENGTH; a list of all ones; a list
# longer than the walk follows; nine protocols, one more than the table binds; and a
# legacy capability over USBCMD.
word = ->(value) { [value].pack('V') }
entry = ->(id, nxt, major = 0) { word.(id | (nxt << 8) | (major << 24)) }
# The window's extra bytes, then the capability registers: CAPLENGTH 0x40, four ports, the
# list at 0xc00, past the doorbells at 0x800, and the runtime registers at 0x600.
capabilities = lambda do |doorbells: 0x800, caplength: 0x40|
  [0x1000 - 0x20].pack('v') + [caplength, 0, 0x100].pack('CCv') + word.((4 << 24) | 8) + word.(0) + word.(0) +
    word.(0x300 << 16) + word.(doorbells) + word.(0x600) + word.(0)
end
list = ->(entries) { capabilities.call.ljust(2 + 0xc00, "\0") + entries }
controller = list.(entry.(1, 4) + word.(0) * 3 + entry.(2, 4, 2) + word.(0) + word.((2 << 8) | 1) + word.(0) +
                   entry.(2, 0, 3) + word.(0) + word.((2 << 8) | 3))
Erx::PackFuzz.declare_target(
  sources: ['otp/erts/emulator/nifs/erxos/erx_device_core.c'],
  includes: [*Erx::PackFuzz::INCLUDES, '.', 'build/gen', 'build/gen/include', 'otp/erts/emulator/nifs/erxos'],
  seeds: {
    'controller' => controller,
    'doorbells-past' => capabilities.(doorbells: 0xf00),
    'misaligned' => capabilities.(caplength: 0x41),
    'all-ones' => capabilities.call.ljust(2 + 0xc00, "\0") + ("\xff".b * 0x400),
    'long-list' => list.(entry.(10, 1) * 65),
    'over-usbcmd' => capabilities.call.sub(word.(0x300 << 16), word.(0x10 << 16)).ljust(2 + 0x40, "\0") + entry.(1, 0),
    'nine-protocols' => list.((entry.(2, 4, 2) + word.(0) + word.((1 << 8) | 1) + word.(0)) * 8 + entry.(2, 0, 2))
  }
)
