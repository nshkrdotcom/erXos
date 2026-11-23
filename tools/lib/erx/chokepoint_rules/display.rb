# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    DISPLAY_DESIGN = 'docs/design-display.md'

    # The display's Erlang rules.
    declare_group(
      rules: [
        # erx_screen is the one sender of frames, so the driver reads the
        # screen image only while erx_screen, which writes nothing during a
        # frame, holds one out. Both requests are functions of the behaviour
        # module, which build the one term a driver's handle_call/3 answers.
        # Refused outside erx_screen in every form ErlangText.calls refuses,
        # through a variable or macro module too, since erx_display alone
        # defines them. Strings are blanked, since a doc string
        # may name either. erx_display's own definitions name no module and
        # pass; a message built by hand and sent to the driver is the
        # driver's review's to catch.
        Chokepoints::ErlangForbidden.new(
          name: 'display-driver-callers', rule: 'only erx_screen calls erx_display:flush_request/3 and ' \
                                                'erx_display:power_request/2, the display driver\'s flush and power requests',
          design: "#{DISPLAY_DESIGN}#chokepoints", strings: :blanked,
          pattern: ErlangText.calls(module_name: 'erx_display', functions: %w[flush_request power_request]),
          sites: ['erlang/apps/erx_display/src/erx_screen.erl'],
          seed: { 'erlang/apps/erx_display/src/seeded.erl' => "f(D) -> gen_server:call(D, erx_display:power_request(D, on)).\n",
                  'erlang/apps/erx_win/src/seeded.erl' => "f(M, D) -> M:flush_request(D, a, b).\n" }
        ),
        # A widget renderer shows each text it reads unchanged, so a record
        # reaches one only through erx_ui_wire:encode/2, which writes every
        # text through the line escape (G5). encode_raw/2 writes texts as they
        # are, for a reader that escapes them itself, the browser, whose web
        # line is to be its one caller beside the codec.
        # Refused outside the codec, in every form ErlangText.calls refuses.
        Chokepoints::ErlangForbidden.new(
          name: 'ui-raw-texts', rule: 'nothing calls erx_ui_wire:encode_raw/2, the widget records\' writer that skips ' \
                                      'the line escape, outside the codec',
          design: "#{DISPLAY_DESIGN}#chokepoints", strings: :blanked,
          pattern: ErlangText.calls(module_name: 'erx_ui_wire', functions: %w[encode_raw]),
          sites: ['erlang/apps/erx_ui/src/erx_ui_wire.erl'],
          seed: { 'erlang/apps/erx_ui/src/seeded.erl' => "f(R) -> erx_ui_wire:encode_raw(R, fun(_, _) -> <<>> end).\n",
                  'erlang/apps/erx_ui/src/seeded_indirect.erl' => "f(M, R) -> M:encode_raw(R, p).\n" }
        )
      ]
    )
  end
end
