# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The session's command server (docs/design-programs.md, "The command server"):
# its pure core, erx_command_core, explored exhaustively by
# test/erlang/erx_command_core_tests.erl, and its effect process, erx_command_srv,
# by test/erlang/erx_command_srv_tests.erl. Each seeded fault must fail the EUnit
# case named beside it.
class ErxCommandSrvTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_command_core_tests.erl test/erlang/erx_command_srv_tests.erl].freeze
  SUITES = %w[erx_command_core_tests erx_command_srv_tests].freeze
  CORE = 'erlang/apps/erx/src/erx_command_core.erl'
  HANDLER = 'erlang/apps/erx/src/erx_prog_handler.erl'

  def test_the_command_server_assigns_ids_and_keeps_the_table
    text, ok = run_eunit({})
    assert ok, text
    assert_match(/All \d+ tests passed/, text)
  end

  # A seeded fault: the file it edits, the text it replaces and its replacement,
  # and the EUnit case that must catch it.
  Mutant = Data.define(:file, :original, :replacement, :caught_by)
  MUTANTS = {
    'a core that gives a dropped row\'s id again' =>
      Mutant.new(file: CORE, original: 'T#table{rows = maps:remove(Id, Rows)}.',
                 replacement: 'T#table{rows = maps:remove(Id, Rows), next = Id}.', caught_by: 'exploration_test_'),
    'a core that gives each program a group of its own' =>
      Mutant.new(file: CORE, original: '[Pgid | _] -> Pgid;', replacement: '[_ | _] -> Id;',
                 caught_by: 'exploration_test_'),
    'a core that gives an id past the protocol\'s bound' =>
      Mutant.new(file: CORE, original: 'when Next > ?ERX_PROG_PID_MAX ->', replacement: 'when Next > ?ERX_PROG_PID_MAX + 1 ->',
                 caught_by: 'ids_run_out_at_the_protocol_bound_test'),
    'a handler that takes a start without its key' =>
      Mutant.new(file: HANDLER, original: '{start, Key, Spec} when is_map(Spec) ->',
                 replacement: '{start, _, Spec} when is_map(Spec) ->', caught_by: 'a_handler_takes_no_start_without_its_key'),
    'a kill that reaches a row outside its scope' =>
      Mutant.new(file: CORE, original: 'when Scope =:= session; Scope =:= {job, Job} -> [Row];',
                 replacement: 'when is_atom(Scope); is_tuple(Scope) -> [Row];',
                 caught_by: 'kill_reaches_a_row_only_within_its_scope_test'),
    'a handler that waits on after its starter ended before the start' =>
      Mutant.new(file: HANDLER, original: "        {'DOWN', Watch, process, Starter, _} ->\n            ok\n    end.",
                 replacement: "        {'DOWN', Watch, process, Starter, _} ->\n            receive never -> ok end\n    end.",
                 caught_by: 'a_handler_ends_with_its_starter_before_the_start')
  }.freeze

  def test_seeded_faults_are_caught
    MUTANTS.each do |name, mutant|
      source = File.read(File.join(ROOT, mutant.file))
      assert_equal 1, source.scan(mutant.original).size, "mutant #{name} must edit exactly one place"
      text, ok = run_eunit({ mutant.file => source.sub(mutant.original) { mutant.replacement } })
      refute ok, "seeded fault not caught: #{name}"
      # Verbose EUnit names every case, so only the named case's failure line counts.
      assert_match(/#{mutant.caught_by}.*\*failed\*/, text, "seeded fault not caught by its case: #{name}")
    end
  end

  private

  # The suites' text and whether they passed, with replaced's sources in place of the tree's.
  def run_eunit(replaced)
    Dir.mktmpdir('erx-command-srv-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      eval_text = "halt(case eunit:test([#{SUITES.join(', ')}], [verbose]) of ok -> 0; _ -> 1 end)."
      text, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell',
                                     '-pa', work, '-eval', eval_text, chdir: work, stdin_data: '')
      [text, status.success?]
    end
  end
end
