# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/abi'

# Runs test/erlang/erx_pcie_cfg_tests.erl, the cases of the PCIe configuration-space
# parser and BAR sizing, against erx_pcie_cfg compiled from source on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies). Then each seeded fault, applied to a
# copy of the module, must fail the case named for it (docs/design-pcie.md, "Host tests
# of the pure cores"): the capability list's step bound removed, so the looping list
# never ends within eunit's deadline; the MSI-X table's BAR indicator left unbounded, so
# indicator 6 is looked up past the six BARs; a second MSI capability kept; a pointer's
# low two bits kept; a 64-bit BAR in the last register taken as a 32-bit one; a PCI
# Express capability whose structure runs past offset 255 accepted; and a sizing mask
# with holes taken.
#
# The module takes its offsets and bounds from abi/formats/pcie.txt while the cases
# write each number out, so one more seeded fault edits a copy of the table instead,
# with erx_abi.hrl generated again from it: the least capability pointer lowered to 0x3c
# must fail the pointer case.
class ErxPcieCfgTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx_pcie].freeze
  MODULE = 'erlang/apps/erx_pcie/src/erx_pcie_cfg.erl'
  MODULE_SOURCE = File.join(ROOT, MODULE)
  TESTS = %w[test/erlang/erx_pcie_cfg_tests.erl].freeze
  DEADLINE_SECONDS = '120'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: "the capability list's step bound removed",
             anchor: 'when Steps >= ?ERX_PCIE_CAPS_MAX ->',
             replacement: 'when Steps < 0 ->',
             catching_case: 'a_looping_list_is_refused_test'),
    Seed.new(fault: "the MSI-X table's BAR indicator left unbounded",
             anchor: 'check(Indicator < ?ERX_PCIE_NORMAL_BARS',
             replacement: 'check(Indicator >= 0',
             catching_case: 'an_msix_table_bar_indicator_above_5_is_refused_test'),
    Seed.new(fault: 'a second MSI, MSI-X or PCI Express capability kept',
             anchor: 'check(not is_map_key(Name, Found), {duplicate, Name}),',
             replacement: 'check(is_atom(Name), {duplicate, Name}),',
             catching_case: 'a_second_msi_msix_or_express_is_refused_test'),
    Seed.new(fault: "a pointer's low two bits kept",
             anchor: 'pointer(Byte) -> Byte band ?ERX_PCIE_CAP_POINTER_MASK.',
             replacement: 'pointer(Byte) -> Byte.',
             catching_case: 'a_root_port_decodes_its_bridge_registers_test'),
    Seed.new(fault: 'a 64-bit BAR in the last register taken as 32-bit',
             anchor: 'refuse({bar, Index});',
             replacement: '[memory(Index, Word, false)];',
             catching_case: 'a_64_bit_bar_in_the_last_register_is_refused_test'),
    Seed.new(fault: "a PCI Express capability's structure left unbounded",
             anchor: 'fits(At, ?ERX_PCIE_EXPRESS_DEVICE_STATUS + 2, express),',
             replacement: 'ok,',
             catching_case: 'a_capability_past_offset_255_is_refused_test'),
    Seed.new(fault: 'a sizing mask with holes taken',
             anchor: 'Bits + Lowest =/= 1 bsl Width -> {error, {bar_mask, Index}};',
             replacement: 'false -> {error, {bar_mask, Index}};',
             catching_case: 'sizing_refuses_a_noncontiguous_mask_test')
  ].freeze

  TABLE_SEED = Seed.new(fault: 'the least capability pointer lowered to 0x3c',
                        anchor: 'limit pcie_cap_first u8 0x40',
                        replacement: 'limit pcie_cap_first u8 0x3c',
                        catching_case: 'a_pointer_below_0x40_is_refused_test')

  def test_pcie_cfg_cases_pass_under_eunit
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
    Dir.mktmpdir('erx-pcie-cfg-abi') do |root|
      output, status = run_cases(File.binread(MODULE_SOURCE), includes: [seeded_header(root, TABLE_SEED)])
      refute status.success?, "#{TABLE_SEED.fault}: the cases passed"
      assert_case_failed(output, TABLE_SEED)
    end
  end

  private

  # eunit's verbose line for the seed's catching case reports it failed, or timed out
  # for the looping list; another case's failure further on does not count.
  def assert_case_failed(output, seed)
    assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*(?:failed|timed out)\*/, output, seed.fault)
  end

  # Copies abi/ under root, applies the seed to the copy of pcie.txt and writes the
  # erx_abi.hrl generated from it to root/include/generated/, the path the module's
  # -include("generated/erx_abi.hrl") names. Returns root/include, searched first.
  def seeded_header(root, seed)
    FileUtils.cp_r(File.join(ROOT, 'abi'), root)
    table = File.join(root, 'abi/formats/pcie.txt')
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
    Dir.mktmpdir('erx-pcie-cfg-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { MODULE => module_text },
                                includes: includes)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_pcie_cfg_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
