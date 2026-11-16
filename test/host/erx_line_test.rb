# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_line_tests.erl, the cases of the line tree (erx_line_fs) served by a
# real erx_fs grant over its keeper, erx_line, with a model driver (docs/design-bluetooth.md,
# "The controller's line"), on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies), against the sources as they are and against each seeded fault, where the
# named case must fail.
class ErxLineTest < Minitest::Test
  APPLICATIONS = %w[erx_uart].freeze
  # The grammar is generated into OTP's preloaded sources, outside the applications, so it
  # is compiled with the cases; the stand-ins replace the erx modules the grant calls.
  TESTS = %w[
    build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl
    test/erlang/erx_line_tests.erl
    test/erlang/stand_in/erx_dist.erl
    test/erlang/stand_in/erx_connections.erl
  ].freeze
  DEADLINE_SECONDS = '120'
  LINE = 'erlang/apps/erx_uart/src/erx_line.erl'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: "the keeper's wait clause removed, so no request it is handed is answered",
             module_path: LINE,
             anchor: "event(?ERX_FS_WAIT(Wait, Request), L) ->\n    take(Wait, Request, L);\n",
             replacement: '',
             catching_case: 'a_waiting_read_blocks_no_other_request_test'),
    Seed.new(fault: 'a keeper that never answers a flush',
             module_path: LINE,
             anchor: "event(Message, #line{waits = Waits} = L) ->\n",
             replacement: "event(?ERX_FS_FLUSH(_), L) ->\n    L;\n" \
                          "event(Message, #line{waits = Waits} = L) ->\n",
             catching_case: 'a_flush_answers_a_waiting_read_eintr_test'),
    Seed.new(fault: 'a reset that waits for the write the driver holds',
             module_path: LINE,
             anchor: "        [{Reset, Done} | _] -> begin_reset(Reset, Done, L);\n",
             replacement: "        [{Reset, Done} | _] when L#line.writing =:= none -> begin_reset(Reset, Done, L);\n" \
                          "        [_ | _] -> L;\n",
             catching_case: 'a_reset_goes_ahead_of_waiting_writes_test'),
    Seed.new(fault: 'a reset that keeps the buffer',
             module_path: LINE,
             anchor: 'L#line{driver = Fresh, rx = <<>>, broken = false, reset = none}',
             replacement: 'L#line{driver = Fresh, broken = false, reset = none}',
             catching_case: 'a_reset_drops_what_the_old_driver_read_test'),
    Seed.new(fault: 'a keeper that outlives its grants, taking their end as any other message',
             module_path: LINE,
             anchor: "handle_info({'EXIT', Grants, Reason}, #line{grants = Grants} = L) ->\n" \
                     "    {stop, {grants_ended, Reason}, L};\n",
             replacement: '',
             catching_case: 'the_keeper_and_its_grants_end_together_test')
  ].freeze

  def test_the_cases_pass
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.module_path))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.module_path => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  # The cases run with the logger off, so the crashes the seeds cause keep each case's
  # verdict on its line.
  def run_cases(replaced)
    Dir.mktmpdir('erx-line-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                      '-kernel', 'logger_level', 'none', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_line_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
