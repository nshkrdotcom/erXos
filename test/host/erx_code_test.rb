# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs the EUnit cases of the code service on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies): test/erlang/erx_code_store_tests.erl against its pure core, and
# test/erlang/erx_code_tests.erl against the service loading real modules there and
# sending start loads to stub code servers. The application is compiled whole
# (ErlangBuild). erx_bytes is the host stand-in, test/erlang/host_bytes/erx_bytes.erl, so no
# hosted build is needed. Each seeded fault the design names for the effect layer of start
# loads (docs/design-live.md, Verification) must fail the case it names.
class ErxCodeTest < Minitest::Test
  APPLICATIONS = %w[erx_code].freeze
  TESTS = %w[test/erlang/host_bytes/erx_bytes.erl test/erlang/erx_code_store_tests.erl
             test/erlang/erx_code_tests.erl test/erlang/erx_code_facet_tests.erl].freeze
  SERVICE = 'erlang/apps/erx_code/src/erx_code.erl'

  Seed = Data.define(:fault, :anchor, :replacement, :scenario) do
    # The failure block names the case's function; its progress line is not matched, since
    # the emulator's reports of earlier cases may land inside it.
    def failure = /in function erx_code_tests:#{Regexp.escape(scenario)} /
  end

  SEEDS = [
    Seed.new(fault: 'the target keyed by domain id',
             anchor: "handle_info({erx_code_started, Id, {configured, _} = Target, DomainPid, Agent}, State0) ->\n",
             replacement: "handle_info({erx_code_started, Id, {configured, _}, DomainPid, Agent}, State0) ->\n" \
                          "    Target = {configured, Id},\n",
             scenario: 'the_next_domain_ends_the_first_domains_start_load/0'),
    Seed.new(fault: "the domain pid's monitor left out",
             anchor: '    Monitor = erlang:monitor(process, DomainPid, [{tag, {erx_code_down, Alias}}]),',
             replacement: '    Monitor = make_ref(),',
             scenario: 'a_domain_pid_end_ends_the_start_load_without_a_log_record/0'),
    Seed.new(fault: 'the deadline check left out',
             anchor: '            Late = erlang:monotonic_time(millisecond) >= Deadline,',
             replacement: '            Late = Deadline =:= never,',
             scenario: 'an_ok_held_past_the_deadline_publishes_nothing/0'),
    Seed.new(fault: 'the lifeline without trapping exits',
             anchor: "                                  process_flag(trap_exit, true),\n",
             replacement: '',
             scenario: 'lifeline_ends/1')
  ].freeze

  def test_the_store_and_the_service_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, SERVICE))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ SERVICE => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(seed.failure, output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    Dir.mktmpdir('erx-code-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test([erx_code_store_tests, erx_code_tests, erx_code_facet_tests], ' \
                               '[verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
