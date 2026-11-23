# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_code_target_tests.erl, the scenarios of erx_code_target, the code
# service's pure core for one target, and the exhaustive exploration of the code protocol
# (docs/design-live.md, "The code server" and its Verification row), on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies), against the sources as they are and
# against each seeded fault the design names, where the exploration must report the
# property the fault breaks.
class ErxCodeTargetTest < Minitest::Test
  APPLICATIONS = %w[erx_code].freeze
  TESTS = %w[test/erlang/erx_code_target_tests.erl].freeze
  DEADLINE_SECONDS = '300'
  TARGET = 'erlang/apps/erx_code/src/erx_code_target.erl'
  MODEL = 'test/erlang/erx_code_target_tests.erl'
  EXPLORATION = 'explore_test_'

  # A seed fails the exploration with the property it breaks, or, for a refusal that keeps
  # the exploration out of the paths it explores, the scenario that pins the refusal.
  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :property, :scenario) do
    def initialize(property: nil, scenario: nil, **fields) = super

    def failure
      return /#{Regexp.escape(scenario)}[^\n]*\*failed\*/ if scenario

      /#{EXPLORATION}[^\n]*\*failed\*.*\{violation,#{property},/m
    end
  end

  SEEDS = [
    Seed.new(fault: 'an answer accepted from any envelope',
             module_path: TARGET,
             anchor: 'received(Origin, Message, #target{load = #load{alias = Alias, domain = Origin} = Load} = T)',
             replacement: 'received(_, Message, #target{load = #load{alias = Alias} = Load} = T)',
             property: 'published_on_ok'),
    Seed.new(fault: 'the overlay dropped at a refused start load',
             module_path: TARGET,
             anchor: '    {T#target{current = {Id, closed}}, [{log, {start_load_failed, Revision, Error}}]}.',
             replacement: '    {T#target{current = {Id, closed}, overlay = #overlay{revision = Revision + 1}},' \
                          ' [{log, {start_load_failed, Revision, Error}}]}.',
             property: 'failed_start_keeps_overlay'),
    Seed.new(fault: 'a word of publication sent for a load that ended at its deadline',
             module_path: TARGET,
             anchor: "    end_load({error, timeout}, T);\n",
             replacement: "    {Ended, Actions} = end_load({error, timeout}, T),\n" \
                          "    {Ended, Actions ++ [{send, T#target.load#load.agent,\n" \
                          "                         {erx_code_published, Alias, T#target.lifeline}}]};\n",
             property: 'published_on_ok'),
    Seed.new(fault: "the model lifeline's monitor left out",
             module_path: MODEL,
             anchor: "monitors(none, [_ | _], Lifeline) -> hd([I || I <- [0, 1], lifeline(I) =:= Lifeline]);\n",
             replacement: '',
             property: 'lifeline'),
    Seed.new(fault: 'the piece cursor removed',
             module_path: TARGET,
             anchor: "read({erx_code_get, _, Hash, Offset}, #load{} = Load) ->\n" \
                     "    next_piece(Hash, Offset, Load);\n",
             replacement: "read({erx_code_get, _, Hash, Offset}, #load{cursor = Cursor, stored = Stored}) ->\n" \
                          "    piece(Hash, maps:get(Hash, Stored), Offset, Cursor);\n",
             property: 'piece_once'),
    Seed.new(fault: "the charge's verdict ignored",
             module_path: TARGET,
             anchor: "        Charge =:= no_memory -> {error, no_memory};\n",
             replacement: '',
             scenario: 'the_verdicts_refuse_in_order_before_anything_is_sent_test')
  ].freeze

  def test_the_cases_pass
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
    assert_match(/\d+ states explored/, output)
  end

  def test_each_seeded_fault_breaks_its_property
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.module_path))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.module_path => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(seed.failure, output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    Dir.mktmpdir('erx-code-target-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                      '-kernel', 'logger_level', 'none', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_code_target_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
