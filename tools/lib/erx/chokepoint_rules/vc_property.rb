# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(none: 'a pure writer and checker of the firmware property buffer, with no private header and no effect: ' \
                        'it touches no mailbox register, and the buffer it fills is its caller\'s')
  end
end
