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
    vmin_ignored: Fault.new(text: '{Min, _} -> min(Min, Count)', broken: '{_, _} -> 1', property: /early_wakeup/),
    count_ignored: Fault.new(text: '{Min, _} -> min(Min, Count)', broken: '{Min, _} -> Min',
                             property: /a_short_raw_read_goes_on_at_its_count/),
    # Input that goes on past a signal key reports a reader the bytes after it.
    signal_not_stopping: Fault.new(text: '{[{signal, _} | _] = Actions, Tty} -> {Actions, Rest, Tty};',
                                   broken: '', property: /a_signal_key_stops_input_and_returns_the_rest/),
    eof_as_empty: Fault.new(text: '<<>> -> eof;', broken: '<<>> -> {ok, <<>>};', property: /read_differs/),
    echo_without_echo: Fault.new(text: 'case on(echo, Tty) orelse (Char =:= $\n andalso on(echonl, Tty)) of',
                                 broken: 'case true of', property: /echo_without_echo/),
    onlcr_without_opost: Fault.new(text: 'case {Stopped, on(opost, Tty)} of', broken: 'case {Stopped, true} of',
                                   property: /opost_clear_changes_bytes/),
    vstatus_without_iexten: Fault.new(text: 'case on(icanon, Tty) andalso on(iexten, Tty) andalso',
                                      broken: 'case on(icanon, Tty) andalso', property: /vstatus/),
    vstatus_echoed: Fault.new(text: "{[info | Started], Tty1};",
                              broken: "echo(Char, [info | Started], Tty1);",
                              property: /vstatus_echoed/),
    # POSIX's reading, a restart at each byte, in place of FreeBSD's one deadline.
    interbyte_restarted: Fault.new(text: "Ready =/= <<>>, element(3, Waiter) =:= none ->\n" \
                                         "            start_timer(Open, element(2, Waiter), Tty);",
                                   broken: "Ready =/= <<>> ->\n            {Cancelled, Tty1} = unwait(Open, Tty),\n" \
                                           "            {Started, Tty2} = start_timer(Open, element(2, Waiter), Tty1),\n" \
                                           "            {Cancelled ++ Started, Tty2};",
                                   property: /interbyte_deadline/),
    # An echo that would end exactly where the room ends is dropped.
    echo_short_of_its_bound: Fault.new(text: 'Tty) when byte_size(Bytes) =< Room ->',
                                       broken: 'Tty) when byte_size(Bytes) < Room ->',
                                       property: /echo_at_its_bound/),
    # Each call starts with a fresh bound of its own, whatever room the
    # owner has, so a chunk that a signal key cuts into calls echoes more.
    echo_bound_per_call: Fault.new(text: 'keys(Bytes, [], Tty0#tty{echo_room = Room})',
                                   broken: 'keys(Bytes, [], Tty0#tty{echo_room = 4096})',
                                   property: /echo_across_calls_takes_one_room/),
    # A dropped piece of echo drops every later one in the call too.
    echo_dropped_after_a_drop: Fault.new(text: "emit(_, Actions, Tty) ->\n    {Actions, Tty}.",
                                         broken: "emit(_, Actions, Tty) ->\n    {Actions, Tty#tty{echo_room = 0}}.",
                                         property: /a_piece_that_does_not_fit_is_dropped_alone/)
  }.freeze

  def test_the_cases_and_the_exploration_pass
    output, status = eunit(File.binread(File.join(ROOT, SOURCE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_ignoring_vmin_readies_a_read_early = assert_fault_fails(:vmin_ignored)

  def test_echo_with_echo_clear_fails = assert_fault_fails(:echo_without_echo)

  def test_a_read_that_ignores_its_count_fails = assert_fault_fails(:count_ignored)

  def test_input_past_a_signal_key_fails = assert_fault_fails(:signal_not_stopping)

  def test_an_end_of_file_read_as_empty_fails = assert_fault_fails(:eof_as_empty)

  def test_onlcr_with_opost_clear_fails = assert_fault_fails(:onlcr_without_opost)

  def test_vstatus_without_iexten_fails = assert_fault_fails(:vstatus_without_iexten)

  def test_an_echoed_vstatus_fails = assert_fault_fails(:vstatus_echoed)

  def test_an_echo_short_of_its_bound_fails = assert_fault_fails(:echo_short_of_its_bound)

  def test_an_echo_bound_per_call_fails = assert_fault_fails(:echo_bound_per_call)

  def test_echo_dropped_after_a_drop_fails = assert_fault_fails(:echo_dropped_after_a_drop)

  def test_a_restarted_interbyte_timer_fails = assert_fault_fails(:interbyte_restarted)

  private

  def assert_fault_fails(name)
    fault = FAULTS.fetch(name)
    source = File.binread(File.join(ROOT, SOURCE))
    raise "erx_tty.erl no longer holds #{fault.text.inspect}" unless source.include?(fault.text)

    output, status = eunit(source.sub(fault.text, fault.broken))
    refute status.success?, output
    # A case fails as "name_test...*failed*"; an exploration property is
    # the second element of the error term, followed by a comma.
    assert_match(/#{fault.property.source}\S*(\.\.\.\*failed\*|,)/, output)
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
