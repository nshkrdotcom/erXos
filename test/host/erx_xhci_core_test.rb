# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_xhci_core_tests.erl, the controller core's pipe machine and
# reset_pipe's table explored to a fixed point against a model of the NIF's queue states,
# the traces of each row, the bus commands and the decoders, against the module compiled
# from source on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). Then
# each seeded fault, applied to a copy of the module, must fail the case named for it:
# Reset Endpoint issued on a stopped queue; a stopped EP0 dropped and added; the
# translator's buffer left uncleared after a halt; a reset whose Stop Endpoint still
# waits keeping it when the endpoint halts, so the stop goes to a halted queue; and a
# pipe that leaves open dropping the requests waiting on it unanswered.
class ErxXhciCoreTest < Minitest::Test
  APPLICATIONS = %w[erx_usb].freeze
  CORE = 'erlang/apps/erx_usb/src/erx_xhci_core.erl'
  TESTS = %w[test/erlang/erx_xhci_core_tests.erl].freeze
  DEADLINE_SECONDS = '600'
  EXPLORED = 'the_pipe_machine_is_explored_to_a_fixed_point_test_'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'Reset Endpoint issued on a stopped queue',
             anchor: 'replan(Pipe, Reset, stopped, Acc);',
             replacement: 'replan(Pipe, Reset, halted, Acc);',
             catching_case: EXPLORED),
    Seed.new(fault: 'a stopped EP0 dropped and added',
             anchor: "plan(stopped, \#{type := control}, _Device) ->\n    [set_tr_dequeue];",
             replacement: "plan(stopped, \#{type := control}, _Device) ->\n    [drop_add];",
             catching_case: EXPLORED),
    Seed.new(fault: "the translator's clear skipped",
             anchor: '[clear_tt || buffered_in_tt(Endpoint, Device)]',
             replacement: '[clear_tt || buffered_in_tt(Endpoint, Device) andalso false]',
             catching_case: EXPLORED),
    Seed.new(fault: 'a waiting Stop Endpoint kept when its endpoint halts',
             anchor: 'false -> replan(Pipe, Reset, halted, Acc)',
             replacement: 'false -> replan(Pipe, Reset, busy, Acc)',
             catching_case: EXPLORED),
    Seed.new(fault: 'the requests waiting on a pipe that leaves open dropped',
             anchor: 'Left, Waiting).',
             replacement: 'Left, []).',
             catching_case: 'ep0_is_reset_before_its_halted_request_is_answered_test')
  ].freeze

  def test_xhci_core_cases_pass_under_eunit
    output, status = run_cases
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, CORE))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases(replaced: { CORE => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  def run_cases(replaced: {})
    Dir.mktmpdir('erx-xhci-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_xhci_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
