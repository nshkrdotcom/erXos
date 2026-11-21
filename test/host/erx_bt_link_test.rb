# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_link_tests.erl, the cases of the link's core, erx_bt_link_core:
# its channels, its one key and the controller's encryption, its deadlines and queue, a
# pairing through it and its exploration, compiled from source on stock's emulator
# (ERX_ERL and ERX_ERLC). Then each seeded fault of docs/design-bluetooth.md, "Host tests
# of the cores", applied to a copy of the module, must fail the case named for it.
class ErxBtLinkTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_bt_link_tests.erl].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '300'
  CORE = 'erlang/apps/erx_bt/src/erx_bt_link_core.erl'
  EXPLORED = 'erx_bt_link_tests: explore...'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'a frame on an unknown channel dropped without being counted',
             anchor: '    {[], Core#core{dropped = Dropped + 1}}.',
             replacement: '    {[], Core}.',
             catching_case: 'unknown_channel_counted_test'),
    Seed.new(fault: "a link with a key pairing again, so its pairing would give it a second key",
             anchor: 'input({admission, Tag, {open, _Mode, _Fresh}}, Now, #core{key = {_, _}} = Core) ->',
             replacement: 'input({admission, Tag, {open, _Mode, _Fresh}}, Now, #core{key = never} = Core) ->',
             catching_case: 'bonded_link_never_pairs_test'),
    Seed.new(fault: 'the gate shown a keyed link as encrypted before the controller reports it',
             anchor: 'security => #{key => gate_key(Key), encrypted => Encrypted}}.',
             replacement: 'security => #{key => gate_key(Key), encrypted => Key =/= none}}.',
             catching_case: 'write_waits_for_encryption_test'),
    Seed.new(fault: 'an Encryption Change accepted after a Negative Reply',
             anchor: "?ENCRYPTION_ON_LE}, Now,\n      #core{ltk_answer = replied} = Core) ->",
             replacement: "?ENCRYPTION_ON_LE}, Now,\n      #core{} = Core) ->",
             catching_case: 'negative_reply_then_change_ends_link_test'),
    Seed.new(fault: 'encryption accepted only for kept bonds',
             anchor: 'input({le_long_term_key_request, _Handle, <<0:64>>, 0}, _Now, #core{key = {Ltk, _}} = Core) ->',
             replacement: 'input({le_long_term_key_request, _Handle, <<0:64>>, 0}, _Now, ' \
                          '#core{key = {Ltk, _}, kept = true} = Core) ->',
             catching_case: 'first_pairing_reaches_level_before_store_test'),
    Seed.new(fault: 'the notification queue unbounded',
             anchor: 'full(Queue) -> queue:len(Queue) >= ?ERX_BT_NOTIFY_QUEUE.',
             replacement: 'full(_Queue) -> false.',
             catching_case: 'notification_queue_bound_test'),
    Seed.new(fault: "the hand-over past the link's share of the controller's buffers",
             anchor: 'when Outstanding >= Share ->',
             replacement: 'when Outstanding >= Share + 1 ->',
             catching_case: EXPLORED),
    Seed.new(fault: "the handler's deadline a millisecond late",
             anchor: 'Core#core{write = {Ref, Now + ?HANDLER_TIMEOUT_MS}}',
             replacement: 'Core#core{write = {Ref, Now + ?HANDLER_TIMEOUT_MS + 1}}',
             catching_case: 'handler_deadline_test'),
    Seed.new(fault: "ATT's responses queued without bound for a phone that does not wait",
             anchor: 'case queue:len(Queue) >= ?ERX_BT_NOTIFY_QUEUE + 2 of',
             replacement: 'case false of',
             catching_case: 'att_request_flood_ends_link_test'),
    Seed.new(fault: "signaling's answers queued whatever the queue holds",
             anchor: '{reply, Reply} -> queue(?ERX_L2CAP_CID_LE_SIGNALING, Reply, droppable, Core);',
             replacement: '{reply, Reply} -> queue(?ERX_L2CAP_CID_LE_SIGNALING, Reply, always, Core);',
             catching_case: 'signaling_answers_dropped_at_full_queue_test'),
    Seed.new(fault: "the refusal after the bond told to the window as the pairing's outcome",
             anchor: 'smp_action({failed, Reason}, _Now, #core{awaiting = Tag, keeping = none} = Core) when Tag =/= none ->',
             replacement: 'smp_action({failed, Reason}, _Now, #core{awaiting = Tag} = Core) ->',
             catching_case: 'done_refusal_not_an_outcome_test'),
    Seed.new(fault: 'a Reply the controller failed still taken as a Reply',
             anchor: 'input({ltk_reply_complete, {failed, _Status}}, _Now, #core{ltk_answer = replied} = Core) ->',
             replacement: 'input({ltk_reply_complete, {failed, _Status}}, _Now, #core{ltk_answer = never} = Core) ->',
             catching_case: 'failed_reply_counts_as_none_test')
  ].freeze

  def test_link_core_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, CORE))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ CORE => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  # The modules, erx_bytes's stand-in and the replaced ones in place of the applications'
  # own, then the cases.
  def run_cases(replaced)
    stand_ins = HOST_BYTES.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-bt-link-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test([erx_bt_link_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
