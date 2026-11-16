# frozen_string_literal: true

# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

# The join machine, erx_wifi_join (docs/design-wifi.md, "Joining", "The supplicant",
# "Verification"): its EUnit cases explore every sequence of events up to a bound
# against a fake access point, chip and key holder, and run the design's scenarios;
# each seeded fault of the design's list for these parts fails its case. erx_sae is
# replaced by the scripted stand-in test/erlang/erx_sae_fake.erl, so the SAE cells of
# the table are reached.

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

class ErxWifiJoinTest < Minitest::Test
  JOIN = 'erlang/apps/erx_wifi/src/erx_wifi_join.erl'
  SAE = 'erlang/apps/erx_wifi/src/erx_sae.erl'
  FAKE_SAE = 'test/erlang/erx_sae_fake.erl'
  TESTS = %w[test/erlang/erx_wifi_join_tests.erl].freeze
  ROOT = File.expand_path('../..', __dir__)

  # A fault planted by replacing each anchor, which must occur once, with its text.
  Seed = Data.define(:fault, :edits, :failure)

  def self.failed(name) = /#{name}[^\n]*\*failed\*/

  EXPLORATION = failed('exploration_keeps_every_property')

  SEEDS = [
    Seed.new(fault: 'message 3 accepted without the RSN element comparison',
             edits: { 'when Rsn =/= ScanRsn; Rsnxe =/= ScanRsnxe ->' => 'when false ->' },
             failure: EXPLORATION),
    Seed.new(fault: 'every accepted message 3 installing its keys',
             edits: { 'slot_key(Slot, Slots) =/= Key]' => 'true]' },
             failure: failed('krack_retransmissions_install_once')),
    Seed.new(fault: "a slot filled only at the chip's confirmation",
             edits: { 'Acc#{Slot => #{key => Key, id => Id, confirmed => false}}' =>
                        'Acc#{Slot => (maps:get(Slot, Acc, #{key => none}))#{id => Id, confirmed => false, next => Key}}',
                      'Held#{confirmed := true}' => 'Held#{confirmed := true, key => maps:get(next, Held)}' },
             failure: failed('krack_retransmissions_install_once')),
    Seed.new(fault: 'a confirmation that confirms every unconfirmed slot',
             edits: { 'Slot := #{id := Filled, confirmed := false} <- Slots, Filled =:= Id]' =>
                        'Slot := #{id := Filled, confirmed := false} <- Slots, Filled =:= Id orelse true]' },
             failure: failed('newer_install_waits_for_its_own_confirmation')),
    Seed.new(fault: 'the watermark raised at message 1',
             edits: { 'Begun#{asked :=' => 'Begun#{watermark := Counter, asked :=' },
             failure: EXPLORATION),
    Seed.new(fault: 'group messages taken without the watermark',
             edits: { 'case above(Counter, Watermark) of' => 'case above(Counter, Watermark) orelse message_kind(Key) =:= group_1 of' },
             failure: failed('replayed_group_and_message_3_install_nothing')),
    Seed.new(fault: 'the replay counter ignored',
             edits: { 'above(Counter, Watermark) -> Counter > Watermark.' => 'above(_Counter, _Watermark) -> true.' },
             failure: failed('replayed_group_and_message_3_install_nothing')),
    Seed.new(fault: 'the GTK slots indexed so that key id 0 is the pairwise slot',
             edits: { 'gtk_slot(Id) -> {gtk, Id}.' => 'gtk_slot(0) -> pairwise; gtk_slot(Id) -> {gtk, Id}.' },
             failure: EXPLORATION),
    Seed.new(fault: "group message 1 checked by message 3's rule",
             edits: { '{ok, Data} -> group_1(State, Key, Data, Join)' => '{ok, Data} -> message_3(State, Key, Data, Join, Ctx)' },
             failure: EXPLORATION),
    Seed.new(fault: 'the cell of eapol in open removed from the table',
             edits: { 'open => [open, rekey, idle], rekey => [rekey, idle]}}' => 'rekey => [rekey, idle]}}' },
             failure: EXPLORATION),
    Seed.new(fault: 'the deadline cell of rekey removed',
             edits: { 'keys => [idle], rekey => [open]}}}.' => 'keys => [idle]}}}.' },
             failure: failed('forged_message_1_spoils_nothing')),
    Seed.new(fault: 'message 2 built from the elements the station asked for',
             edits: { 'sent := #{rsn := Rsn, rsnxe := Rsnxe}, proof := Proof} = Join,' =>
                        'own := #{rsn := Rsn, rsnxe := Rsnxe}, proof := Proof} = Join,' },
             failure: EXPLORATION),
    Seed.new(fault: 'a handler that opens the port at message 3',
             edits: { 'Installed#{watermark := Counter, ptk := Ptk,' => 'Installed#{state := open, watermark := Counter, ptk := Ptk,' },
             failure: EXPLORATION),
    Seed.new(fault: 'SAE silence classed bss',
             edits: { 'Tested = case erx_sae:tested(Sae) of true -> tested; false -> Proof end,' => 'Tested = Proof,' },
             failure: EXPLORATION),
    Seed.new(fault: 'an accepted SAE exchange whose connect never comes waits for ever',
             edits: { "due(sae, {deadline, _}, \#{sae := accepted} = Join, Ctx) ->\n    finish(Join, {deadline, sae}, Ctx);\n" => '' },
             failure: EXPLORATION),
    Seed.new(fault: "an event of another join's reference accepted",
             edits: { 'belongs(Event, #{ref := Ref}) -> Ref =/= none andalso element(2, Event) =:= Ref.' =>
                        'belongs(_Event, #{ref := _Ref}) -> true.' },
             failure: EXPLORATION)
  ].freeze

  def test_eunit_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    pristine = File.read(File.join(ROOT, JOIN))
    SEEDS.each do |seed|
      seeded = seed.edits.reduce(pristine) do |text, (anchor, replacement)|
        assert_equal 1, text.scan(anchor).size, "the seed no longer applies: #{seed.fault}"
        text.sub(anchor) { replacement }
      end
      output, status = eunit({ JOIN => seeded })
      refute status.success?, "#{seed.fault} passed:\n#{output}"
      assert_match seed.failure, output, seed.fault
    end
  end

  private

  def eunit(replaced)
    modules = TESTS.map { |path| File.basename(path, '.erl') }.join(', ')
    stand_in = { SAE => File.read(File.join(ROOT, FAKE_SAE)) }
    Dir.mktmpdir('erx-wifi-join-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_wifi], tests: TESTS, replaced: stand_in.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', '900', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "halt(case eunit:test([#{modules}], [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
