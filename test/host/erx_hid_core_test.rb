# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/abi'

# Runs test/erlang/erx_hid_core_tests.erl, the cases of the HID function's fold, against
# erx_hid_core compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies), over layouts erx_hid_desc parses from the descriptor cases' encoders.
# Then each seeded fault, applied to a copy of the module, must fail the case named for it
# (docs/design-usb.md, "Host tests of the cores"): the ErrorRollOver check removed, so a
# phantom report releases the keys held; the state reduced to one previous report, so a
# report of id 2 releases id 1's keys; the transfer sized without the report-id byte, so
# the longest numbered report is cut short; the interrupt length taken as one 64-byte
# packet, so a report two packets long is cut short (the design's named fault); and a
# position normalized over one step too many, so an axis's maximum falls short of 65535.
#
# The module maps usages through abi/formats/hid.txt while the cases write each code
# out, so one more seeded fault edits a copy of the table instead, with the generated
# sources made again from it: usage 04h mapped to KEY_B must fail the held-set case.
class ErxHidCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx_usb].freeze
  MODULE = 'erlang/apps/erx_usb/src/erx_hid_core.erl'
  MODULE_SOURCE = File.join(ROOT, MODULE)
  TRANSLATIONS = 'build/gen/erlang/apps/erx/src/generated/erx_abi_translations.erl'
  # The descriptor's cases hold the item encoders and fixture descriptors these cases use.
  TESTS = %w[test/erlang/erx_hid_desc_tests.erl test/erlang/erx_hid_core_tests.erl].freeze
  DEADLINE_SECONDS = '120'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the ErrorRollOver check removed',
             anchor: 'Rollover =/= [] andalso lists:all(fun(Held) -> Held end, Rollover).',
             replacement: 'Rollover =:= [] andalso false.',
             catching_case: 'a_rollover_report_changes_nothing_test'),
    Seed.new(fault: 'the state reduced to one previous report',
             anchor: 'Edges = edges(held(Entries), held(Next)),',
             replacement: 'Edges = edges(held(Entries), lists:usort(R#report.held)),',
             catching_case: 'a_report_of_id_2_leaves_id_1s_keys_held_test'),
    Seed.new(fault: 'the transfer sized without the report-id byte',
             anchor: 'transfer_length(#{largest := Largest, numbered := true}) -> Largest + 1;',
             replacement: 'transfer_length(#{largest := Largest, numbered := true}) -> Largest;',
             catching_case: 'the_transfer_carries_the_report_id_byte_test'),
    Seed.new(fault: 'the interrupt length taken as one packet',
             anchor: 'transfer_length(#{largest := Largest, numbered := false}) -> Largest.',
             replacement: 'transfer_length(#{largest := Largest, numbered := false}) -> min(64, Largest).',
             catching_case: 'a_report_two_packets_long_folds_whole_test'),
    Seed.new(fault: 'a position normalized over one step too many',
             anchor: '* ?ERX_INPUT_AXIS_MAX div (Max - Min).',
             replacement: '* ?ERX_INPUT_AXIS_MAX div (Max - Min + 1).',
             catching_case: 'an_absolute_position_normalizes_to_0_and_65535_at_its_ends_test')
  ].freeze

  TABLE_SEED = Seed.new(fault: 'usage 04h mapped to KEY_B',
                        anchor: 'map 0x04 key_a',
                        replacement: 'map 0x04 key_b',
                        catching_case: 'the_held_set_gives_ups_then_downs_in_code_order_test')

  def test_hid_core_cases_pass_under_eunit
    output, status = run_cases(File.binread(MODULE_SOURCE))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(MODULE_SOURCE)
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases(source.sub(seed.anchor) { seed.replacement })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_case_failed(output, seed)
    end
  end

  def test_a_map_entry_changed_in_the_table_fails_its_case
    Dir.mktmpdir('erx-hid-core-abi') do |root|
      output, status = run_cases(File.binread(MODULE_SOURCE), translations: seeded_translations(root, TABLE_SEED))
      refute status.success?, "#{TABLE_SEED.fault}: the cases passed"
      assert_case_failed(output, TABLE_SEED)
    end
  end

  private

  # eunit's verbose line for the seed's catching case reports it failed; another case's
  # failure further on does not count.
  def assert_case_failed(output, seed)
    assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
  end

  # Copies abi/ under root, applies the seed to the copy of hid.txt and answers the text
  # of erx_abi_translations generated from it, which the build's own is replaced by.
  def seeded_translations(root, seed)
    FileUtils.cp_r(File.join(ROOT, 'abi'), root)
    table = File.join(root, 'abi/formats/hid.txt')
    text = File.binread(table)
    assert_equal 1, text.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
    File.binwrite(table, text.sub(seed.anchor) { seed.replacement })
    Erx::ABI::ErlangEmitter.translations(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root)))
  end

  # The module's text compiled in place of the application's own, then the cases, with the
  # translations module's text in place of the build's own when one is given.
  def run_cases(module_text, translations: nil)
    Dir.mktmpdir('erx-hid-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { MODULE => module_text, TRANSLATIONS => translations }.compact)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_hid_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
