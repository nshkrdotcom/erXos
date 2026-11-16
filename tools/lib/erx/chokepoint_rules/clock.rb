# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The clock service, the one caller of the time page's setter, and the NIF module
    # that defines it (docs/design-time.md, "The NIF and the liberx calls").
    CLOCK_SETTER_SITES = %w[erlang/apps/erx/src/erx_clock.erl erlang/apps/erx/src/erx_clock_nif.erl].freeze
    SET_OFFSET = ErlangText::ATOM.call('set_offset')

    declare_group(
      rules: [
        # The call in every form a module can write it: a remote call or fun naming
        # erx_clock_nif, an apply naming set_offset, a call through a variable or macro
        # module, an import from erx_clock_nif and a macro whose body is erx_clock_nif.
        Chokepoints::ErlangForbidden.new(
          name: 'clock-setter', rule: 'only erx_clock calls erx_clock_nif:set_offset/1, the wall clock\'s setter',
          design: 'docs/design-time.md#the-nif-and-the-liberx-calls', strings: :blanked,
          pattern: /
              #{ErlangText::ATOM.call('erx_clock_nif')}\s*[:,]\s*#{SET_OFFSET}
            | (?:#{ErlangText::INDIRECT})\s*:\s*#{SET_OFFSET}
            | #{ErlangText::ATOM.call('apply')}\s*\(\s*[^,()]+,\s*#{SET_OFFSET}
            | -\s*import\s*\(\s*#{ErlangText::ATOM.call('erx_clock_nif')}
            | -\s*define\s*\(\s*[^,()]+(?:\([^()]*\))?\s*,\s*#{ErlangText::ATOM.call('erx_clock_nif')}\s*\)
          /x,
          sites: CLOCK_SETTER_SITES,
          seed: { 'erlang/apps/erx_shell/src/erx_cmd_date.erl' => "f(W) -> erx_clock_nif:set_offset(W).\n" }
        )
      ]
    )
  end
end
