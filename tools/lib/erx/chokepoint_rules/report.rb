# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # erx_net's gen_servers: erx_net runs on stock OTP outside erXos, needing
    # only kernel and stdlib, not the erx application that holds erx_report
    # (docs/design-network-stack.md, "N12. Usable without erXos"), so they
    # write their own format_status/1. Theirs passes the reason and every key
    # it does not name through whole, which is safe on erXos only because the
    # network domain runs the report filter.
    STANDALONE_STATUS = %w[erx_tcp_conn erx_tcp_listen erx_net_driver]
                        .map { |name| "erlang/apps/erx_net/src/#{name}.erl" }.freeze

    # Every format_status of erXos's Erlang is one clause that hands OTP's
    # Status to erx_report:status/2 (design-log.md, "Reports carry no term").
    # A system-domain process, where no report filter runs, holds other
    # domains' and the host's bytes, such as the Bluetooth controller's
    # traffic with its keys; a hand-written format_status passes the reason,
    # the log and every key it forgets into a crash report whole, while
    # erx_report:status/2 hides every key a module does not name and cuts the
    # reason to its leading atom. A head of any arity is refused, so a
    # hand-written format_status/2 is too. Doc strings, which name
    # format_status, are blanked.
    declare_group(
      rules: [
        Chokepoints::ErlangForbidden.new(
          name: 'format-status-through-report',
          rule: 'every format_status is one clause that hands its Status to erx_report:status/2',
          design: 'docs/design-log.md#reports-carry-no-term',
          scope: %w[erlang/apps/**/*.erl], sites: STANDALONE_STATUS, strings: :blanked,
          allowed: /^format_status\((?<status>\w+)\)\s*->\s*erx_report\s*:\s*status\(\k<status>,/,
          pattern: /^[ \t]*format_status[ \t]*\(/,
          seed: { 'erlang/apps/erx_uart/src/seeded.erl' =>
                    "format_status(Status) ->\n    maps:map(fun(_Key, Value) -> Value end, Status).\n",
                  'erlang/apps/erx_bt/src/seeded.erl' =>
                    "format_status(S) -> S.\nother(S) -> erx_report:status(S, \#{}).\n",
                  'erlang/apps/erx/src/seeded.erl' => "format_status(_Opt, [_Dict, State]) -> State.\n" }
        )
      ]
    )
  end
end
