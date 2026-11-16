# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/fuzz/erx_code_objects_facet'

# Runs test/erlang/erx_code_objects_facet_tests.erl, the EUnit cases of the code_objects
# facet (docs/design-system.md, "Creating a domain", "The code_objects facet"), compiled
# from source on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). Then
# each seeded fault, a bound removed from the decoder or a forward for a grantee not the
# facet's, is compiled in its place, and the cases must fail on it.
class ErxCodeObjectsFacetTest < Minitest::Test
  APPLICATIONS = %w[erx_domain].freeze
  TESTS = %w[test/erlang/erx_code_objects_facet_tests.erl].freeze
  CASES = 'erx_code_objects_facet_tests'
  FACET = 'erlang/apps/erx_domain/src/erx_code_objects_facet.erl'
  ROOT = File.expand_path('../..', __dir__)

  # Each fault: the text of the facet replaced and its replacement.
  Fault = Data.define(:name, :from, :to)
  FAULTS = [
    Fault.new(name: 'the size bound removed',
              from: 'when is_integer(Size), Size > 0, Size < 1 bsl 64 ->',
              to: 'when is_integer(Size), Size > 0 ->'),
    Fault.new(name: 'the number bound removed',
              from: 'when is_integer(Number), Number > 0, Number < 1 bsl 32 ->',
              to: 'when is_integer(Number) ->'),
    Fault.new(name: 'a drop forwarded for another grantee',
              from: '{ok, {drop, Number}} -> {forward, Behind, {code_drop, Grantee, Number}, State};',
              to: '{ok, {drop, Number}} -> {forward, Behind, {code_drop, Grantee + 1, Number}, State};')
  ].freeze

  def test_cases_pass_under_eunit
    Dir.mktmpdir('erx-code-objects-facet-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = eunit(work)
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_each_seeded_fault_is_caught
    text = File.read(File.join(ROOT, FACET))
    FAULTS.each do |fault|
      assert_equal 1, text.scan(fault.from).size, "#{fault.name}: its text must occur once in #{FACET}"
      Dir.mktmpdir('erx-code-objects-facet-fault') do |work|
        ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS,
                                  replaced: { FACET => text.sub(fault.from, fault.to) })
        output, status = eunit(work)
        refute status.success?, "#{fault.name} passed #{CASES}:\n#{output}"
        assert_match(/Failed: [1-9]/, output, fault.name)
      end
    end
  end

  # The fuzz target's seeded faults run only at the milestone gate; their texts are
  # checked here, so an edit of the decoder cannot leave the target unable to run.
  def test_fuzz_seeds_still_name_the_decoder
    text = File.read(File.join(ROOT, FACET))
    ErxCodeObjectsFacetFuzz::SEEDS.each do |fault|
      assert_equal 1, text.scan(fault.from).size, "fuzz seed #{fault.name}: its text must occur once in #{FACET}"
    end
  end

  private

  def eunit(work)
    Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                    '-eval', "halt(case eunit:test(#{CASES}, []) of ok -> 0; _ -> 1 end)",
                    chdir: work, stdin_data: '')
  end
end
