# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    APPS = 'docs/design-apps.md'
    PACKAGING = 'docs/design-packaging.md'
    STARTER = 'erlang/apps/erx_starter/**/*'
    # The modules that start a session; the web login joins them when it is built.
    KEEPER = 'erlang/apps/erx_starter/src/erx_starter_keeper.erl'
    # Packaging's modules, which share the start service's application but not its
    # table: AP1 bounds the table and its keepers, and design-packaging.md bounds these.
    PACKAGE_PROCESS = 'erlang/apps/erx_starter/src/erx_pkg*.erl'
    START_CALLERS = ['erlang/apps/erx/src/erx_console.erl', KEEPER].freeze
    # What erx_starter may call of erx_domain: start_session/2, start_app/2 and stop/2;
    # system_namespace/0, the wait before the first read of rc.conf, and
    # server_settled/1, the wait before a row that names a display starts,
    # neither of which changes anything; the handle's accessors id/1 and
    # pid/1, which reach nothing; and the handle's types, domain() and
    # spec(), which a -spec names.
    STARTER_REACHES = %w[start_session start_app stop system_namespace server_settled id pid domain spec].freeze
    STARTER_REACH = "#{ErlangText::ATOM.call('erx_domain')}\\s*:\\s*" \
                    "(?:#{STARTER_REACHES.map { |name| ErlangText::ATOM.call(name) }.join('|')})"
    # An atom or a variable in a function's place.
    ERLANG_FUNCTION = "(?:[A-Za-z_][A-Za-z0-9_@]*|'(?:[^'\\\\]|\\\\.)*')"

    # The start table's rules (AP1, AP2): who starts a session and who names
    # its display. They read the Erlang sources with strings blanked, since
    # erx_starter's doc strings name erx_domain.
    declare_group(
      rules: [
        # The allowed calls are tried first, so an erx_domain* atom is
        # refused only where it is not one of them. Calls
        # that take a module and a function (spawn/3, erpc:call/4) are not
        # refused: with every erx_domain* atom refused, the module they name
        # would have to come from outside the module's source.
        Chokepoints::ErlangForbidden.new(
          name: 'starter-reach', rule: 'erx_starter reaches the domain service only through erx_domain:start_session/2, ' \
                                       'erx_domain:stop/2, erx_domain:system_namespace/0 and erx_domain:server_settled/1 ' \
                                       '(reading a handle with id/1 and pid/1), ' \
                                       'and calls nothing through a variable or ' \
                                       'macro module or apply',
          design: "#{APPS}#invariants", scope: [STARTER], sites: [PACKAGE_PROCESS], strings: :blanked,
          allowed: STARTER_REACH,
          pattern: /
              (?<![A-Za-z0-9_@'])'?erx_domain[A-Za-z0-9_@]*'?#{ErlangText::NOT_NAME}
            | (?:#{ErlangText::INDIRECT})\s*:\s*#{ERLANG_FUNCTION}\s*\( | \bfun\s+(?:#{ErlangText::INDIRECT})\s*:
            | #{ErlangText::ATOM.call('apply')}\s*[(\/]
          /x,
          seed: { 'erlang/apps/erx_starter/src/seeded.erl' => "f(S) -> erx_domain:create(S).\n",
                  'erlang/apps/erx_starter/src/seeded_indirect.erl' => "f(M) -> M:start_session(a, b).\n",
                  'erlang/apps/erx_starter/src/seeded_apply.erl' => "f() -> apply(m, f, []).\n" }
        ),
        # The call in every form ErlangText.calls refuses, outside the callers
        # and erx_domain's own application, and the service's registered name.
        Chokepoints::ErlangForbidden.new(
          name: 'start-callers', rule: 'only erx_console and erx_starter_keeper call erx_domain:start_session/2, and only ' \
                                       "erx_domain's own modules name its service, erx_domain_srv; the web login " \
                                       'joins the callers when it is built',
          design: "#{APPS}#invariants", strings: :blanked,
          pattern: /#{ErlangText.calls(module_name: 'erx_domain', functions: %w[start_session])}
                   | #{ErlangText::ATOM.call('erx_domain_srv')}/x,
          sites: [*START_CALLERS, 'erlang/apps/erx_domain/**/*'],
          seed: { 'erlang/apps/erx/src/seeded.erl' => "f(S) -> erx_domain:start_session(S, \#{}).\n" }
        ),
        # A caller outside erx_starter names neither atom except as a
        # function's name: not after a colon, not before a parenthesis or a
        # slash. Any other module that starts a session fails start-callers.
        Chokepoints::ErlangForbidden.new(
          name: 'start-display', rule: 'only erx_starter passes display or default_display to erx_domain:start_session/2',
          design: "#{APPS}#verification-and-testing", strings: :blanked, scope: START_CALLERS, sites: [STARTER],
          pattern: /(?<!:)(?:#{%w[display default_display].map { |name| ErlangText::ATOM.call(name) }.join('|')})(?!\s*[(\/])/,
          seed: { START_CALLERS.first => "f(S) -> erx_domain:start_session(S, \#{display => d}).\n" }
        ),
        # PK7: the keepers alone start an app's sessions, so a package process
        # that waits for a package set without the app knows no other starter
        # runs one. The call in every form ErlangText.calls refuses, and the
        # service's registered name, which reaches start_app/2 by another
        # spelling.
        Chokepoints::ErlangForbidden.new(
          name: 'app-starters', rule: "only erx_starter_keeper calls erx_domain:start_app/2, the start of an app's session",
          design: "#{PACKAGING}#invariants", strings: :blanked,
          pattern: /#{ErlangText.calls(module_name: 'erx_domain', functions: %w[start_app])}
                   | #{ErlangText::ATOM.call('erx_domain_srv')}/x,
          sites: [KEEPER, 'erlang/apps/erx_domain/**/*'],
          seed: { START_CALLERS.first => "f(S) -> erx_domain:start_app(S, \#{}).\n" }
        )
      ]
    )
  end
end
