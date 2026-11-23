# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_code_agent_tests.erl, the cases of a domain's code server
# (docs/design-live.md, "The code server") loading real modules on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies), against the sources as they are and
# against each seeded fault, where the named case must fail. erx_bytes is the host
# stand-in, so no hosted build is needed.
class ErxCodeAgentTest < Minitest::Test
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/host_bytes/erx_bytes.erl test/erlang/erx_code_agent_tests.erl].freeze
  DEADLINE_SECONDS = '120'
  CORE = 'erlang/apps/erx/src/erx_code_agent_core.erl'
  AGENT = 'erlang/apps/erx/src/erx_code_agent.erl'
  KEEP = 'answered(#core{supervised = true} = Core, #load{alias = Alias} = Load, ok) ->'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the keep step removed, so an unconfirmed batch runs on',
             module_path: CORE, anchor: KEEP,
             replacement: KEEP.sub('supervised = true', 'supervised = true, phase = keep_removed'),
             catching_case: 'an_unconfirmed_ok_ends_the_server_at_its_deadline'),
    Seed.new(fault: 'the keep step applied in every domain',
             module_path: CORE, anchor: KEEP, replacement: KEEP.sub('#core{supervised = true}', '#core{}'),
             catching_case: 'a_domain_no_specification_restarts_keeps_an_unconfirmed_batch'),
    Seed.new(fault: 'the monitor taken after an empty start load',
             module_path: CORE, anchor: '[{monitor, Lifeline} || Named, Core#core.lifeline =:= none]',
             replacement: '[{monitor, Lifeline} || Named orelse true, Core#core.lifeline =:= none]',
             catching_case: 'a_confirmed_empty_start_load_takes_no_monitor'),
    Seed.new(fault: 'a link to the lifeline in place of the monitor',
             module_path: AGENT, anchor: 'erlang:monitor(process, Lifeline)',
             replacement: '(link(Lifeline) andalso make_ref())',
             catching_case: 'the_lifelines_end_ends_a_server_that_runs_a_published_module'),
    Seed.new(fault: 'the hash check removed, so a bad blob loads',
             module_path: CORE, anchor: 'byte_size(Bytes) =:= Size andalso erx_bytes:sha256(Bytes) =:= Hash',
             replacement: 'byte_size(Bytes) =:= Size orelse erx_bytes:sha256(Bytes) =:= Hash',
             catching_case: 'a_blob_one_bit_off_its_hash_loads_nothing'),
    Seed.new(fault: "a frame of the server's own code left below gen_statem's loop",
             module_path: AGENT, anchor: 'gen_statem:enter_loop(?MODULE, [], idle, Data, Actions).',
             replacement: 'try gen_statem:enter_loop(?MODULE, [], idle, Data, Actions) after ok end.',
             catching_case: 'replacing_its_own_module_twice_leaves_it_running'),
    Seed.new(fault: 'a load that arrives during another taken as dropped, not postponed',
             module_path: AGENT, anchor: '{keep_state_and_data, [postpone]};', replacement: 'keep_state_and_data;',
             catching_case: 'a_load_that_arrives_during_another_waits_for_it'),
    Seed.new(fault: 'a message handled past the deadline before the deadline ends the load',
             module_path: AGENT,
             anchor: 'erlang:monotonic_time(millisecond) >= erx_code_agent_core:deadline(Core)',
             replacement: 'Core =:= past_deadline_check_removed',
             catching_case: 'a_piece_queued_before_the_deadline_is_not_taken_after_it'),
    Seed.new(fault: 'the floor check removed',
             module_path: CORE, anchor: 'maps:get(Limit, Limits) < Floor]',
             replacement: 'maps:get(Limit, Limits) < 0]',
             catching_case: 'a_runtime_below_a_floor_fails_its_start')
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
    Dir.mktmpdir('erx-code-agent-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                      '-kernel', 'logger_level', 'none', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_code_agent_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
