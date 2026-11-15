# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_wm_tests.erl, erx_wm_rio_tests.erl, erx_wctl_tests.erl and erx_winctl_tests.erl, the EUnit cases
# of the window policies and of the wctl and ctl text (docs/design-display.md, "Verification and
# testing", the window system), against the erx_display application compiled from source
# with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies). Each property is then run against a copy of a policy with one rule broken,
# which must fail it under the property's name.
class ErxWmTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE_DIRECTORY = 'erlang/apps/erx_display/src'
  TESTS = %w[erx_wm_tests erx_wm_rio_tests erx_wctl_tests erx_winctl_tests].freeze
  DEADLINE = '300'
  # A broken rule: the file, its text, what replaces it, and the property that must fail,
  # by the name the cases raise.
  Mutant = Data.define(:file, :text, :broken, :property)
  MUTANTS = {
    every_window_shown: Mutant.new(file: 'erx_wm_single.erl',
                                   text: 'state := case WindowId of ShownId -> shown; _ -> hidden end}',
                                   broken: 'state := shown}',
                                   property: /more_than_one_shown/),
    every_window_hidden: Mutant.new(file: 'erx_wm_single.erl',
                                    text: 'state := case WindowId of ShownId -> shown; _ -> hidden end}',
                                    broken: 'state := hidden}',
                                    property: /app_window_not_shown/),
    newest_window_shown: Mutant.new(file: 'erx_wm_single.erl',
                                    text: 'Ids -> lists:min(Ids)',
                                    broken: 'Ids -> lists:max(Ids)',
                                    property: /app_window_not_shown/),
    keys_dropped: Mutant.new(file: 'erx_wm_single.erl',
                             text: 'Id -> {{to, Id, Input}, State}',
                             broken: '_Id -> {drop, State}',
                             property: /key_not_delivered/),
    # The overlapping policy's keyboard goes only to the user's pick: a client that gains it
    # by its own wctl top, a window that takes it by being made, and a current window that
    # falls back to the topmost shown one when the pick is hidden or ended each fail the
    # exhaustive run, as does a click on another window delivered to it.
    top_picks: Mutant.new(file: 'erx_wm_rio.erl',
                          text: "request(top, Window, Windows, _Screen, State) ->\n    {ok, raise(Window, Windows), State};",
                          broken: 'request(top, #{id := Id} = Window, Windows, _Screen, State) ->' \
                                  "\n    " '{ok, raise(Window, Windows), State#{pick := Id}};',
                          property: /key_not_to_the_pick/),
    new_picks: Mutant.new(file: 'erx_wm_rio.erl',
                          text: 'State#{cascade := (Index + 1) rem ?CASCADE_LENGTH}};',
                          broken: 'State#{cascade := (Index + 1) rem ?CASCADE_LENGTH, pick := maps:get(id, Window)}};',
                          property: /key_not_to_the_pick/),
    topmost_fallback: Mutant.new(file: 'erx_wm_rio.erl',
                                 text: '        {ok, #{state := shown}} -> Pick;' "\n" '        _ -> none',
                                 broken: '        {ok, #{state := shown}} -> Pick;' "\n" \
                                         '        _ -> case erx_wm:shown(Windows) of [#{id := Top} | _] -> Top; ' \
                                         '[] -> none end',
                                 property: /key_not_to_the_pick/),
    click_delivered: Mutant.new(file: 'erx_wm_rio.erl',
                                text: '_Other -> {{windows, raised(Id, Windows)}, State#{pick := Id}}',
                                broken: '_Other -> {{to, Id, Input}, State#{pick := Id}}',
                                property: /click_reached_a_client/)
  }.freeze

  def test_policy_and_wctl_cases_pass_under_eunit
    output, status = eunit(nil)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_showing_every_application_window_fails_the_single_property = assert_mutant_fails(:every_window_shown)

  def test_hiding_every_window_fails_the_single_property = assert_mutant_fails(:every_window_hidden)

  def test_showing_the_newest_window_fails_the_single_property = assert_mutant_fails(:newest_window_shown)

  def test_dropped_keys_fail_the_delivery_property = assert_mutant_fails(:keys_dropped)

  def test_a_pick_by_wctl_top_fails_the_overlapping_keyboard_run = assert_mutant_fails(:top_picks)

  def test_a_pick_of_each_new_window_fails_the_overlapping_keyboard_run = assert_mutant_fails(:new_picks)

  def test_the_topmost_shown_window_as_fallback_fails_the_overlapping_keyboard_run =
    assert_mutant_fails(:topmost_fallback)

  def test_a_selecting_click_delivered_fails_the_overlapping_keyboard_run = assert_mutant_fails(:click_delivered)

  private

  def assert_mutant_fails(name)
    mutant = MUTANTS.fetch(name)
    output, status = eunit(mutant)
    refute status.success?, output
    assert_match mutant.property, output
  end

  # Compiles the application, with the mutant's file edited when there is one, and the
  # cases into a directory of its own, and runs the cases.
  def eunit(mutant)
    Dir.mktmpdir('erx-wm-test') do |work|
      replaced = mutant ? { "#{SOURCE_DIRECTORY}/#{mutant.file}" => edited(mutant) } : {}
      ErlangBuild.compile(work, applications: %w[erx_display], tests: TESTS.map { |name| "test/erlang/#{name}.erl" },
                          replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "halt(case eunit:test([#{TESTS.join(', ')}], [verbose]) of ok -> 0; _ -> 1 end).",
                      chdir: work, stdin_data: '')
    end
  end

  def edited(mutant)
    path = File.join(ROOT, SOURCE_DIRECTORY, mutant.file)
    source = File.binread(path)
    raise "#{path} no longer holds #{mutant.text.inspect}" unless source.include?(mutant.text)

    source.sub(mutant.text, mutant.broken)
  end
end
