# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_desk_window_tests.erl, the EUnit cases of a desktop program's window
# process and of erx_desk:reload/1 (docs/design-desktop-programs.md, "The construction",
# D9 and the "window: lifetime" row of "Verification and testing"), against erx_desk
# compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies), and plants each row's seeded fault to see its case fail.
class ErxDeskWindowTest < Minitest::Test
  TESTS = %w[test/erlang/erx_desk_window_tests.erl].freeze
  SOURCE = 'erlang/apps/erx_desk/src/erx_desk_window.erl'
  DEADLINE = '120'

  # Each fault replaces one passage of the window process, and the case it names must fail.
  Fault = Data.define(:name, :from, :to, :caught_by)
  FAULTS = [
    Fault.new(name: 'the window ending normal on close, which leaves the workers alive',
              from: '{ui_down, Ui, _Reason} -> exit(shutdown);', to: '{ui_down, Ui, _Reason} -> exit(normal);',
              caught_by: 'closing_a_window_ends_its_workers'),
    Fault.new(name: 'a cancel that unlinks the worker but leaves it running',
              from: 'unlink(Pid), exit(Pid, kill)', to: 'unlink(Pid)',
              caught_by: 'a_cancelled_worker_is_killed_and_sends_nothing'),
    Fault.new(name: 'a reload that starts the window again from init',
              from: '{erx_desk, reload, Core} -> loop(present(W));',
              to: '{erx_desk, reload, Core} -> loop(present(W#window{state = element(1, Core:init(#{}))}));',
              caught_by: 'reload_presents_the_new_view_of_the_kept_state')
  ].freeze

  # An EUnit run: whether it passed, EUnit's report, and both streams for messages.
  EunitRun = Data.define(:passed, :report, :text)

  def test_window_cases_pass_under_eunit
    run = eunit_run
    assert run.passed, run.text
    assert_match(/All \d+ tests passed/, run.report)
  end

  def test_the_cases_catch_each_seeded_fault
    source = File.read(File.join(ErlangBuild::ROOT, SOURCE))
    FAULTS.each do |fault|
      assert_equal 1, source.scan(fault.from).size, fault.name
      run = eunit_run(replaced: { SOURCE => source.sub(fault.from, fault.to) })
      refute run.passed, "#{fault.name} passed:\n#{run.text}"
      assert_match(/#{fault.caught_by}[^\n]*\*(failed|timed out)\*/, run.report, "#{fault.name}:\n#{run.text}")
    end
  end

  private

  def eunit_run(replaced: {})
    Dir.mktmpdir('erx-desk-window-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx_desk], tests: TESTS, replaced: replaced)
      report, errors, status = Open3.capture3('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell',
                                              '-pa', work, '-eval',
                                              'halt(case eunit:test(erx_desk_window_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                              chdir: work, stdin_data: '')
      EunitRun.new(passed: status.success?, report: report, text: "#{report}\n--- standard error ---\n#{errors}")
    end
  end
end
