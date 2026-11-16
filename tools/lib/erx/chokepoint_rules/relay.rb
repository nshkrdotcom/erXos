# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    RELAY_DESIGN = 'docs/design-shell.md#the-terminal-relays-protocol'
    ERX_SESSION_RELAY = ErlangText::ATOM.call('erx_session_relay')
    OPEN_READER = ErlangText::ATOM.call('open_reader')
    # The relay's registered name, through which a session's processes reach it.
    TTY_OWNER = ErlangText::ATOM.call('erx_tty_owner')

    # The terminal relay's two rules. Each catches a slip, not a determined
    # bypass: a module that makes the name or the function at run time
    # (list_to_atom/1, a computed apply/3) passes, and what keeps a
    # write-only open from reading is the open's mode, which the relay checks
    # on every read. The readers' rule blanks strings, since a doc string
    # may name the function; the name's rule keeps them, since a string can
    # become the atom, so a doc string names the relay's name in words;
    # the tests' modules lie outside otp/ and erlang/, so the relay's own
    # cases, which open for reading from the test process, are not sites.
    declare_group(
      rules: [
        # Every reader of a job passes a scheduler pick between its ready
        # report and its read, which erx_cmd does, and the console belongs to
        # no job; a program's handler and a command domain's stream relay
        # open write-only. Refused outside erx_cmd and erx_console, in the
        # forms of the display rules: the name after erx_session_relay and a
        # colon or a comma (a remote call, a fun, an apply, a {Module,
        # Function} pair), through a variable or macro module, in an apply,
        # an import from erx_session_relay, and a macro defined as either.
        Chokepoints::ErlangForbidden.new(
          name: 'relay-readers', rule: 'only erx_cmd and erx_console call erx_session_relay:open_reader/1, ' \
                                       'the one way to an open of the terminal made for reading',
          design: RELAY_DESIGN, strings: :blanked,
          pattern: /
              #{ERX_SESSION_RELAY}\s*[:,]\s*#{OPEN_READER}
            | (?:#{ErlangText::INDIRECT})\s*:\s*#{OPEN_READER}
            | #{ErlangText::ATOM.call('apply')}\s*\(\s*[^,()]+,\s*#{OPEN_READER}
            | -\s*import\s*\(\s*#{ERX_SESSION_RELAY}
            | -\s*define\s*\(\s*[^,()]+(?:\([^()]*\))?\s*,\s*(?:#{ERX_SESSION_RELAY}|#{OPEN_READER})\s*\)
          /x,
          sites: %w[erlang/apps/erx_shell/src/erx_cmd.erl erlang/apps/erx/src/erx_console.erl],
          seed: { 'erlang/apps/erx_shell/src/seeded.erl' => "f(Job) -> erx_session_relay:open_reader(Job).\n" }
        ),
        # erx_session_relay's client functions make every request to the
        # relay, so no request, an open for reading included, is built by
        # hand. The name's other holders: erx_output, the runtime's writers'
        # one sender of tty_write and tty_drain, which every owner serves,
        # and the modules that hold the name in other domains, erx_console
        # in the system domain and erx_log_h's proxy in a domain with no
        # terminal (docs/design-runtime.md, "A process waits on its tty's
        # owner").
        Chokepoints::ErlangForbidden.new(
          name: 'relay-name', rule: 'only erx_session_relay, erx_output and the name\'s holders in other ' \
                                    'domains name erx_tty_owner, the terminal relay\'s registered name',
          design: RELAY_DESIGN, pattern: /#{TTY_OWNER}/,
          sites: %w[erlang/apps/erx_session/src/erx_session_relay.erl otp/lib/kernel/src/erx_output.erl
                    erlang/apps/erx/src/erx_console.erl erlang/apps/erx/src/erx_log_h.erl],
          seed: { 'erlang/apps/erx_shell/src/seeded.erl' =>
                    "f(Job) -> gen_server:call(erx_tty_owner, {open, Job, read}, infinity).\n" }
        )
      ]
    )
  end
end
