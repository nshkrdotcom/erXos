# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/fuzz/erx_clock_facet'

# Runs the clock service's EUnit cases (docs/design-time.md, "Verification and
# testing", decide, restart and facet decode): test/erlang/erx_clock_core_tests.erl,
# the Steps table and the set clause, and test/erlang/erx_clock_facet_tests.erl, the
# facet's decoder, its operation/1 and the facet admitting only its grant's operations
# outliving erx_clock's restart, and a crash loop ending erx_clock_sup and not its parent,
# compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies). Then each seeded fault is compiled in place of its module, and the cases
# must fail on it, which shows they exercise what they guard.
class ErxClockTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_clock_core_tests.erl test/erlang/erx_clock_facet_tests.erl].freeze
  CASES = %w[erx_clock_core_tests erx_clock_facet_tests].freeze
  CORE = 'erlang/apps/erx/src/erx_clock_core.erl'
  FACET = 'erlang/apps/erx/src/erx_clock_facet.erl'
  SUP = 'erlang/apps/erx/src/erx_service_sup.erl'

  # Each fault: the module it is planted in, the text replaced and its replacement, or a
  # list of texts each replaced by its partner in a list of replacements.
  Fault = Data.define(:name, :module, :from, :to)
  FAULTS = [
    Fault.new(name: 'a sample-only row admits set', module: FACET,
              from: '{ok, Decoded} -> {ok, element(1, Decoded)};', to: '{ok, _Decoded} -> {ok, sample};'),
    Fault.new(name: "W's upper bound dropped", module: FACET,
              from: 'W >= 0 andalso W =< ?ERX_TIME_OFFSET_MAX)', to: 'W >= 0)'),
    Fault.new(name: 'the distance bound one past its edge', module: FACET,
              from: 'Distance < ?ERX_CLOCK_DISTANCE_MAX_NS', to: 'Distance =< ?ERX_CLOCK_DISTANCE_MAX_NS'),
    Fault.new(name: 'the two-sample rule dropped', module: CORE,
              from: "        Excess -> step;\n        Sign -> {hold, Sign}", to: "        _Sign -> step"),
    Fault.new(name: 'the floor row dropped', module: CORE,
              from: 'row(Wall, _Cold, _D, _Excess) when Wall < ?FLOOR_NS -> {refuse, floor};', to: ''),
    Fault.new(name: 'a set decided by the Steps table', module: CORE,
              from: "decide({set, W}, Source, Page, Record) ->\n    {step, step(W, Source, Page), Record\#{excess := none}};",
              to: "decide({set, W}, Source, Page, Record) ->\n    decide({sample, W, 0, 1, {0, 0, 0, 0}}, Source, Page, Record);"),
    Fault.new(name: 'a set that keeps the excess', module: CORE,
              from: '{step, step(W, Source, Page), Record#{excess := none}};', to: '{step, step(W, Source, Page), Record};'),
    Fault.new(name: 'a step to its size rather than to W', module: CORE,
              from: '#{offset => W, step_ns => W - C,', to: '#{offset => W - C, step_ns => W - C,'),
    Fault.new(name: 'a step recorded without its source', module: CORE,
              from: 'step_source := Source, steps := Steps + 1}', to: 'steps := Steps + 1}'),
    Fault.new(name: "erx_clock's pid captured at mint", module: FACET,
              from: ['{ok, #{grantee => Grantee}}.', 'whereis(erx_clock)} of'],
              to: ['{ok, #{grantee => Grantee, clock => whereis(erx_clock)}}.', 'maps:get(clock, State)} of']),
    Fault.new(name: 'erx_clock_sup restarted by its parent', module: SUP,
              from: 'restart => temporary,', to: 'restart => permanent,'),
    Fault.new(name: 'the parent named the server of clock', module: SUP,
              from: 'ok = erx_facet:serve(Interface, self()),',
              to: "ok = erx_facet:serve(Interface, hd(get('$ancestors'))),")
  ].freeze

  def test_clock_cases_pass_under_eunit
    Dir.mktmpdir('erx-clock-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = eunit(work)
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_each_seeded_fault_is_caught
    FAULTS.each do |fault|
      text = File.read(File.join(ROOT, fault.module))
      pairs = Array(fault.from).zip(Array(fault.to))
      pairs.each do |from, _to|
        assert_equal 1, text.scan(from).size, "#{fault.name}: #{from} must occur once in #{fault.module}"
      end
      planted = pairs.reduce(text) { |planting, (from, to)| planting.sub(from, to) }
      Dir.mktmpdir('erx-clock-fault') do |work|
        ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS,
                                  replaced: { fault.module => planted })
        output, status = eunit(work)
        refute status.success?, "#{fault.name}: the cases passed with it:\n#{output}"
        assert_match(/Failed: [1-9]/, output, fault.name)
      end
    end
  end

  # The fuzz target's seeded faults run only at the milestone gate; their texts are
  # checked here, at every landing, so an edit of the decoder updates them too.
  def test_fuzz_seeds_still_name_the_decoder
    text = File.read(File.join(ROOT, FACET))
    ErxClockFacetFuzz::SEEDS.each do |fault|
      assert_equal 1, text.scan(fault.from).size, "fuzz seed #{fault.name}: its text must occur once in #{FACET}"
    end
  end

  private

  def eunit(work)
    eval = "halt(case eunit:test([#{CASES.join(', ')}], [verbose]) of ok -> 0; _ -> 1 end)."
    Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                    '-eval', eval, chdir: work, stdin_data: '')
  end
end
