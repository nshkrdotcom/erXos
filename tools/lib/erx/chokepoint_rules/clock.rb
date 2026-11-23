# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The clock service, the one caller of the time page's setter, and the NIF module
    # that defines it (docs/design-time.md, "The NIF and the liberx calls").
    CLOCK_SETTER_SITES = %w[erlang/apps/erx/src/erx_clock.erl erlang/apps/erx/src/erx_clock_nif.erl].freeze

    declare_group(
      rules: [
        # The call in every form ErlangText.calls refuses.
        Chokepoints::ErlangForbidden.new(
          name: 'clock-setter', rule: 'only erx_clock calls erx_clock_nif:set_offset/1, the wall clock\'s setter',
          design: 'docs/design-time.md#the-nif-and-the-liberx-calls', strings: :blanked,
          pattern: ErlangText.calls(module_name: 'erx_clock_nif', functions: %w[set_offset]),
          sites: CLOCK_SETTER_SITES,
          seed: { 'erlang/apps/erx_shell/src/erx_cmd_date.erl' => "f(W) -> erx_clock_nif:set_offset(W).\n" }
        )
      ]
    )
  end
end
