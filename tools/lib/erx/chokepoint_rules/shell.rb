# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    SHELL = 'docs/design-shell.md'
    # The modules that run the shell's evaluator or what it calls.
    EVALUATOR_MODULES = %w[erx_shell_eval erx_shell_runner erx_shell_script erx_shell_leader]
                        .map { |name| "erlang/apps/erx_shell/src/#{name}.erl" }.freeze
    SPAWN_ATOMS = ErlangText::ATOM.call('(?:spawn(?:_link|_monitor|_opt|_request)?|proc_lib)')
    # The spawns these modules may write besides the funnel's own: the job
    # leader, which holds no variable, and the exec's process, which holds the
    # first variables (docs/todo-shell.md, "plain spawns that hold the shell's variables").
    # erx_shell_parse:next_bounded/3 starts its parse with a fixed-reason end
    # of its own and stays out of this scope, since the parser builds alone
    # for its fuzz target.
    EVALUATOR_SPAWNS = [
      'spawn_opt\(fun\(\)\s*->\s*exit\(evaluated\(Body\)\)\s*end',
      'spawn\(fun\(\)\s*->\s*forward\(',
      'proc_lib\s*:\s*spawn_link\(fun\(\)\s*->\s*exec\(Command,\s*Vars,\s*Cwd\)\s*end\)'
    ].join('|').freeze

    # The shell's one funnel for evaluator code (design-shell.md, "Failure
    # handling, diagnostics and debuggability"): a process that evaluates the shell's source or runs what it calls starts
    # through erx_shell_runner:spawn_evaluator/3, whose end never carries a
    # reason, so no crash report, $status or diagnostic names a variable. The
    # rule reads the code with strings blanked, since doc strings name spawn.
    declare_group(
      rules: [
        Chokepoints::ErlangForbidden.new(
          name: 'evaluator-spawns', rule: 'in erx_shell_eval, erx_shell_runner, erx_shell_script and erx_shell_leader ' \
                                          'only erx_shell_runner:spawn_evaluator/3 spawns a process, beside the job ' \
                                          "leader's own and the exec's",
          design: "#{SHELL}#failure-handling-diagnostics-and-debuggability",
          scope: EVALUATOR_MODULES, strings: :blanked,
          allowed: EVALUATOR_SPAWNS, pattern: /#{SPAWN_ATOMS}/,
          seed: { EVALUATOR_MODULES.fetch(1) => "f(Fun) -> spawn_monitor(Fun).\n",
                  EVALUATOR_MODULES.fetch(2) => "f(Fun) -> proc_lib:spawn(Fun).\n",
                  EVALUATOR_MODULES.fetch(0) => "f(Fun) -> erlang:spawn_opt(Fun, []).\n" }
        )
      ]
    )
  end
end
