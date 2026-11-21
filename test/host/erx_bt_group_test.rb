# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_group_tests.erl, the cases of the Bluetooth controller group
# (erx_bt_host_sup and its children) over the model line of test/erlang/erx_bt_line_model.erl,
# the store and the advertising data, compiled from source on stock's emulator (ERX_ERL and
# ERX_ERLC) with erx_bytes's host stand-in in place of erXos's BIFs. Then each seeded fault
# of docs/design-bluetooth.md, "Verification", the controller group's row and the link's
# backlog through the group, applied to a copy of its module, must fail the case named for it.
class ErxBtGroupTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_bt_group_tests.erl test/erlang/erx_bt_line_model.erl].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '120'
  RX = 'erlang/apps/erx_bt/src/erx_bt_line_rx.erl'
  HCI = 'erlang/apps/erx_bt/src/erx_bt_hci.erl'
  CORE = 'erlang/apps/erx_bt/src/erx_bt_hci_core.erl'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the reader reading at its start, so its read meets the reset',
             module_path: RX,
             anchor: '{ok, Data} -> {ok, Data};',
             replacement: '{ok, Data} -> self() ! {read, self()}, {ok, Data};',
             catching_case: 'group_reaches_ready_and_keeps_the_address_test'),
    Seed.new(fault: 'the controller process making the address itself, so it changes across the restart',
             module_path: HCI,
             anchor: 'address => erx_bt_store:address(),',
             replacement: 'address => erx_bytes:entropy(6),',
             catching_case: 'group_reaches_ready_and_keeps_the_address_test'),
    Seed.new(fault: "a link process's end ignored, so no Disconnect is written",
             module_path: HCI,
             anchor: 'step_noreply({request, Name, {disconnect, ?ERX_HCI_DISCONNECT_REASON_REMOTE_USER_TERMINATED}}, Ended);',
             replacement: '{noreply, Ended};',
             catching_case: 'a_killed_link_is_disconnected_test'),
    Seed.new(fault: 'the completion not passed to the link, so it never hands over its second packet',
             module_path: CORE,
             anchor: 'completed(Handle, Count, Core) -> to_link(Handle, {completed, Count}, Core).',
             replacement: 'completed(_Handle, _Count, Core) -> {[], Core}.',
             catching_case: 'completions_reach_the_link_test'),
    Seed.new(fault: "the link's backlog bound removed, so a link that has not stepped is sent all 40 packets",
             module_path: CORE,
             anchor: '#{Handle := #live{backlog = ?ERX_BT_LINK_BACKLOG} = Live} ->',
             replacement: '#{Handle := #live{backlog = unbounded} = Live} ->',
             catching_case: 'a_link_held_at_its_start_is_cut_at_its_backlog_test'),
    Seed.new(fault: "the identity address's top bits cleared",
             module_path: 'erlang/apps/erx_bt/src/erx_bt_store.erl',
             anchor: '{ok, <<2#11:2, Random:46>>}.',
             replacement: '{ok, <<0:2, Random:46>>}.',
             catching_case: 'static_addresses_test')
  ].freeze

  def test_group_cases_pass_under_eunit
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
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*(failed|timed out)\*/, output, seed.fault)
    end
  end

  private

  # The modules, erx_bytes's stand-in and the replaced ones in place of the applications'
  # own, then the cases, with the logger off so the crashes the seeds cause keep each
  # case's verdict on its line.
  def run_cases(replaced)
    stand_ins = HOST_BYTES.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-bt-group-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-kernel', 'logger_level', 'none',
                      '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_bt_group_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
