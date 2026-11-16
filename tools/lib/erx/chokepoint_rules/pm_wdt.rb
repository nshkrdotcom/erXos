# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(none: 'a pure decision over a watchdog step and the words of a write, with no private header and no effect: ' \
                        'the device rules keep the watchdog\'s registers to its shim')
  end
end
