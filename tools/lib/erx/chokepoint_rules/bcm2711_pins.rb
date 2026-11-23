# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(none: 'a pure plan of the on-board pins\' function-select words, with no private header and no effect: ' \
                        'the device rules keep the pin controller\'s registers to the root\'s shim')
  end
end
