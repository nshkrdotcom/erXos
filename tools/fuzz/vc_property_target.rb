# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The mailbox answer check against a hostile firmware. Seeds in tools/fuzz/vc_property_fuzz.c's
# format: NOTIFY_XHCI_RESET answered, ignored (bit 31 clear), refused with the firmware's
# parse error and answered for another tag; and for a model declaration, an answer longer
# than its window, one with the longest length the indicator holds, one below the least
# answer, and a buffer of all ones.
notify = [0, 0, 0, 0].pack('C*')
model = ->(window:, least:, request: 1) { [1, window, least, request].pack('C*') }
buffer = lambda do |indicator:, code: 0x8000_0000, tag: 0x0003_0058, value: Array.new(16, 0)|
  [4 * (6 + value.size), code, tag, 4 * value.size, indicator, *value, 0].pack('V*')
end
counting = (1..16).map { |word| 0x0101_0101 * word }
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/vc_property.c'],
  seeds: {
    'notify-answered' => notify + buffer.(indicator: 0x8000_0000, value: [0]),
    'notify-ignored' => notify + buffer.(indicator: 0, value: [0x0010_0000]),
    'notify-parse-error' => notify + buffer.(indicator: 0x8000_0000, code: 0x8000_0001, value: [0]),
    'notify-other-tag' => notify + buffer.(indicator: 0x8000_0000, tag: 0x0003_0059, value: [0]),
    'model-longer-than-window' => model.(window: 2, least: 1) + buffer.(indicator: 0x8000_0040, value: counting),
    'model-longest-length' => model.(window: 16, least: 0) + buffer.(indicator: 0xffff_ffff, value: counting),
    'model-below-least' => model.(window: 2, least: 2) + buffer.(indicator: 0x8000_0004, value: counting),
    'all-ones' => model.(window: 16, least: 16, request: 16) + ("\xff".b * 4 * 23)
  }
)
