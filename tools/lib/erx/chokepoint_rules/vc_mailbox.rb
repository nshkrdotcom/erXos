# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(none: 'a pure state machine of one mailbox request, with no private header and no effect: ' \
                        'it reads no register and no clock, and its caller reads and writes the mailbox')
  end
end
