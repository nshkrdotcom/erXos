# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/abi'

# Runs test/erlang/erx_hid_desc_tests.erl, the cases of the HID report descriptor's
# parser, against erx_hid_desc compiled from source on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies). Then each seeded fault, applied to a copy of the
# module, must fail the case named for it (docs/design-usb.md, "Host tests of the
# cores"): the push-depth bound removed, so a descriptor of four nested pushes is
# accepted; an input report's length bounded without its report-id byte, so a report one
# byte over the interrupt buffer is accepted; a usage range kept with its minimum above
# its maximum, which hid.c drops; Pop leaving the pushed report id behind; and
# Report Count and a usage read signed, so one-byte values from 80h, as Appendix B.1
# writes them, go wrong.
#
# The module takes its bounds from abi/formats/hid.txt while the cases write each number
# out, so one more seeded fault edits a copy of the table instead, with erx_abi.hrl
# generated again from it: the push stack given a fifth level must fail the push case.
class ErxHidDescTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx_usb].freeze
  MODULE = 'erlang/apps/erx_usb/src/erx_hid_desc.erl'
  MODULE_SOURCE = File.join(ROOT, MODULE)
  TESTS = %w[test/erlang/erx_hid_desc_tests.erl].freeze
  DEADLINE_SECONDS = '120'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the push-depth bound removed',
             anchor: 'when length(Stack) + 1 >= ?ERX_HID_PUSH_LEVELS_MAX ->',
             replacement: 'when length(Stack) < 0 ->',
             catching_case: 'three_pushes_are_accepted_and_a_fourth_is_refused_test'),
    Seed.new(fault: "an input report bounded without its report-id byte",
             anchor: 'IdByte = case Numbered of true -> 1; false -> 0 end,',
             replacement: 'IdByte = case Numbered of true -> 0; false -> 0 end,',
             catching_case: 'the_report_bound_counts_the_id_byte_test'),
    Seed.new(fault: 'a usage range kept with its minimum above its maximum',
             anchor: 'maximum = Maximum}) when Minimum =< Maximum ->',
             replacement: 'maximum = Maximum}) when is_integer(Minimum) ->',
             catching_case: 'usage_ranges_follow_hid_c_test'),
    Seed.new(fault: 'Report Count read signed',
             anchor: 'value(?ERX_HID_GLOBAL_TAG_REPORT_COUNT, {_, Unsigned, _}, G) ->',
             replacement: 'value(?ERX_HID_GLOBAL_TAG_REPORT_COUNT, {_, _, Unsigned}, G) ->',
             catching_case: 'one_byte_values_from_0x80_are_unsigned_where_hid_c_reads_them_so_test'),
    Seed.new(fault: 'a usage read signed',
             anchor: 'usage_item(Tag, {Bits, Unsigned, _}, G, L) ->',
             replacement: 'usage_item(Tag, {Bits, _, Unsigned}, G, L) ->',
             catching_case: 'one_byte_values_from_0x80_are_unsigned_where_hid_c_reads_them_so_test'),
    Seed.new(fault: 'Pop leaving the pushed report id behind',
             anchor: 'P#parse{globals = Saved, stack = Stack};',
             replacement: 'P#parse{globals = Saved#globals{id = (P#parse.globals)#globals.id}, stack = Stack};',
             catching_case: 'pop_restores_the_report_id_and_its_position_test')
  ].freeze

  TABLE_SEED = Seed.new(fault: 'the push stack given a fifth level',
                        anchor: 'limit hid_push_levels_max u32 4',
                        replacement: 'limit hid_push_levels_max u32 5',
                        catching_case: 'three_pushes_are_accepted_and_a_fourth_is_refused_test')

  def test_hid_desc_cases_pass_under_eunit
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

  def test_a_bound_changed_in_the_table_fails_its_case
    Dir.mktmpdir('erx-hid-desc-abi') do |root|
      output, status = run_cases(File.binread(MODULE_SOURCE), includes: [seeded_header(root, TABLE_SEED)])
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

  # Copies abi/ under root, applies the seed to the copy of hid.txt and writes the
  # erx_abi.hrl generated from it to root/include/generated/, the path the module's
  # -include("generated/erx_abi.hrl") names. Returns root/include, searched first.
  def seeded_header(root, seed)
    FileUtils.cp_r(File.join(ROOT, 'abi'), root)
    table = File.join(root, 'abi/formats/hid.txt')
    text = File.binread(table)
    assert_equal 1, text.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
    File.binwrite(table, text.sub(seed.anchor) { seed.replacement })
    schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
    File.join(root, 'include').tap do |directory|
      FileUtils.mkdir_p(File.join(directory, 'generated'))
      File.write(File.join(directory, 'generated', 'erx_abi.hrl'), Erx::ABI::ErlangEmitter.header(schema))
    end
  end

  # The module's text compiled in place of the application's own, then the cases; includes
  # are searched for its headers before the build's own.
  def run_cases(module_text, includes: [])
    Dir.mktmpdir('erx-hid-desc-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { MODULE => module_text },
                                includes: includes)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_hid_desc_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
