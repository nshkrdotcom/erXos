# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_tty_tests.erl, the EUnit cases and the exhaustive
# exploration of the line discipline erx_tty (docs/design-live.md, "The tty"),
# compiled with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies). Each seeded fault is a copy of erx_tty with one
# rule broken, which must fail the property that guards it.
class ErxTtyTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE = 'erlang/apps/erx_session/src/erx_tty.erl'
  CASES = %w[test/erlang/erx_tty_tests.erl].freeze
  DEADLINE = '600'
  Fault = Data.define(:text, :broken, :property)
  FAULTS = {
    vmin_ignored: Fault.new(text: '{Min, _} -> Min', broken: '{_, _} -> 1', property: /early_wakeup/),
    echo_without_echo: Fault.new(text: 'case on(echo, Tty) orelse (Char =:= $\n andalso on(echonl, Tty)) of',
                                 broken: 'case true of', property: /echo_without_echo/),
    onlcr_without_opost: Fault.new(text: 'case {Stopped, on(opost, Tty)} of', broken: 'case {Stopped, true} of',
                                   property: /opost_clear_changes_bytes/),
    vstatus_without_iexten: Fault.new(text: 'case on(icanon, Tty) andalso on(iexten, Tty) andalso',
                                      broken: 'case on(icanon, Tty) andalso', property: /vstatus/),
    vstatus_echoed: Fault.new(text: "{[info | Started], Tty1};",
                              broken: "echo(Char, [info | Started], Tty1);",
                              property: /vstatus_echoed/)
  }.freeze

  def test_the_cases_and_the_exploration_pass
    output, status = eunit(File.binread(File.join(ROOT, SOURCE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_ignoring_vmin_readies_a_read_early = assert_fault_fails(:vmin_ignored)

  def test_echo_with_echo_clear_fails = assert_fault_fails(:echo_without_echo)

  def test_onlcr_with_opost_clear_fails = assert_fault_fails(:onlcr_without_opost)

  def test_vstatus_without_iexten_fails = assert_fault_fails(:vstatus_without_iexten)

  def test_an_echoed_vstatus_fails = assert_fault_fails(:vstatus_echoed)

  private

  def assert_fault_fails(name)
    fault = FAULTS.fetch(name)
    source = File.binread(File.join(ROOT, SOURCE))
    raise "erx_tty.erl no longer holds #{fault.text.inspect}" unless source.include?(fault.text)

    output, status = eunit(source.sub(fault.text, fault.broken))
    refute status.success?, output
    assert_match fault.property, output
  end

  # Compiles erx and erx_session with erx_tty as module_text, and the cases,
  # into a directory of their own and runs the cases.
  def eunit(module_text)
    Dir.mktmpdir('erx-tty-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_session], tests: CASES,
                                replaced: { SOURCE => module_text })

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_tty_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                      chdir: work, stdin_data: '')
    end
  end
end
