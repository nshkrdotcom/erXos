# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # The liberx/backend/core source that the link lists of every backend and test guest
  # take, named once.
  module BackendCore
    # The refusing answer of every kernel call a backend does not implement (ERX_ENOTSUP).
    REFUSED = 'liberx/backend/core/refused.c'
  end
end
