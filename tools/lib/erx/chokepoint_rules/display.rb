# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    DISPLAY_DESIGN = 'docs/design-display.md'
    DISPLAY_REQUESTS = "(?:#{%w[flush_request power_request].map { |name| ErlangText::ATOM.call(name) }.join('|')})"
    ERX_DISPLAY = ErlangText::ATOM.call('erx_display')
    ERX_UI_WIRE = ErlangText::ATOM.call('erx_ui_wire')
    ENCODE_RAW = ErlangText::ATOM.call('encode_raw')

    # The display's Erlang rules.
    declare_group(
      rules: [
        # erx_screen is the one sender of frames, so the driver reads the
        # screen image only while erx_screen, which writes nothing during a
        # frame, holds one out. Both requests are functions of the behaviour
        # module, which build the one term a driver's handle_call/3 answers.
        # Refused outside erx_screen: either name after erx_display and a
        # colon or a comma (a remote call, a fun, an apply, a {Module,
        # Function} pair); either called through a variable or macro module,
        # since erx_display alone defines them; an apply whose function is
        # either; an import from erx_display; and a macro defined as
        # erx_display or either name. Strings are blanked, since a doc string
        # may name either. erx_display's own definitions name no module and
        # pass; a message built by hand and sent to the driver is the
        # driver's review's to catch.
        Chokepoints::ErlangForbidden.new(
          name: 'display-driver-callers', rule: 'only erx_screen calls erx_display:flush_request/3 and ' \
                                                'erx_display:power_request/2, the display driver\'s flush and power requests',
          design: "#{DISPLAY_DESIGN}#chokepoints", strings: :blanked,
          pattern: /
              #{ERX_DISPLAY}\s*[:,]\s*#{DISPLAY_REQUESTS}
            | (?:#{ErlangText::INDIRECT})\s*:\s*#{DISPLAY_REQUESTS}
            | #{ErlangText::ATOM.call('apply')}\s*\(\s*[^,()]+,\s*#{DISPLAY_REQUESTS}
            | -\s*import\s*\(\s*#{ERX_DISPLAY}
            | -\s*define\s*\(\s*[^,()]+(?:\([^()]*\))?\s*,\s*(?:#{ERX_DISPLAY}|#{DISPLAY_REQUESTS})\s*\)
          /x,
          sites: ['erlang/apps/erx_display/src/erx_screen.erl'],
          seed: { 'erlang/apps/erx_display/src/seeded.erl' => "f(D) -> gen_server:call(D, erx_display:power_request(D, on)).\n",
                  'erlang/apps/erx_win/src/seeded.erl' => "f(M, D) -> M:flush_request(D, a, b).\n" }
        ),
        # A widget renderer shows each text it reads unchanged, so a record
        # reaches one only through erx_ui_wire:encode/2, which writes every
        # text through the line escape (G5). encode_raw/2 writes texts as they
        # are, for a reader that escapes them itself, the browser, whose web
        # line is to be its one caller beside the codec.
        # Refused outside the codec, in the forms of the rule above: the name
        # after erx_ui_wire and a colon or a comma, through a variable or
        # macro module, in an apply, an import from erx_ui_wire, and a macro
        # defined as either name.
        Chokepoints::ErlangForbidden.new(
          name: 'ui-raw-texts', rule: 'nothing calls erx_ui_wire:encode_raw/2, the widget records\' writer that skips ' \
                                      'the line escape, outside the codec',
          design: "#{DISPLAY_DESIGN}#chokepoints", strings: :blanked,
          pattern: /
              #{ERX_UI_WIRE}\s*[:,]\s*#{ENCODE_RAW}
            | (?:#{ErlangText::INDIRECT})\s*:\s*#{ENCODE_RAW}
            | #{ErlangText::ATOM.call('apply')}\s*\(\s*[^,()]+,\s*#{ENCODE_RAW}
            | -\s*import\s*\(\s*#{ERX_UI_WIRE}
            | -\s*define\s*\(\s*[^,()]+(?:\([^()]*\))?\s*,\s*(?:#{ERX_UI_WIRE}|#{ENCODE_RAW})\s*\)
          /x,
          sites: ['erlang/apps/erx_ui/src/erx_ui_wire.erl'],
          seed: { 'erlang/apps/erx_ui/src/seeded.erl' => "f(R) -> erx_ui_wire:encode_raw(R, fun(_, _) -> <<>> end).\n",
                  'erlang/apps/erx_ui/src/seeded_indirect.erl' => "f(M, R) -> M:encode_raw(R, p).\n" }
        )
      ]
    )
  end
end
