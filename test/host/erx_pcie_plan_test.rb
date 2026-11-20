# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_pcie_plan_tests.erl, the PCIe planner's cases against a model of
# configuration space, on erx_pcie_plan compiled from source on stock's emulator (ERX_ERL
# and ERX_ERLC, which make check supplies). Then each seeded fault of docs/design-pcie.md
# ("Host tests of the pure cores"), applied to a copy of the module, must fail the case
# named for it: the floor taken as the lower of read and target even when data differ,
# so a decoding function's BAR is written with memory space on and the quiet check
# fails; bus master raised before MSI-X's live step, so the order check fails; and the
# mastering rule removed, so a blank function's plan to mastering is accepted. A fourth
# seed lowers to quiet whenever any field differs, so a running function's master
# request turns its memory space off first and the floor's minimality check fails.
class ErxPciePlanTest < Minitest::Test
  APPLICATIONS = %w[erx_pcie].freeze
  MODULE = 'erlang/apps/erx_pcie/src/erx_pcie_plan.erl'
  MODULE_SOURCE = File.join(ErlangBuild::ROOT, MODULE)
  TESTS = %w[test/erlang/erx_pcie_cfg_tests.erl test/erlang/erx_pcie_plan_tests.erl].freeze
  DEADLINE_SECONDS = '900'
  # The case that holds every capability, so every seed has an input there that it breaks.
  CATCHING_CASE = 'endpoint msi64_mask msix true'

  Seed = Data.define(:fault, :anchor, :replacement, :property)

  SEEDS = [
    Seed.new(fault: 'the floor taken as the lower of read and target even when data differ',
             anchor: 'floor_level(true, _Read, _Target) -> 0;',
             replacement: 'floor_level(true, Read, Target) -> min(Read, Target);',
             property: 'data_while_quiet'),
    Seed.new(fault: "bus master raised before MSI-X's live step",
             anchor: '[{memory, 1}, {msix, 1}, {msi, 1}, {msix, 2}, {intx, 1}, {master, 1}]',
             replacement: '[{memory, 1}, {msix, 1}, {msi, 1}, {master, 1}, {msix, 2}, {intx, 1}]',
             property: 'master_raised_last'),
    Seed.new(fault: 'the floor quiet whenever any field differs, not only data',
             anchor: 'DataDiffers = maps:with(data_fields(Projection), As) =/= maps:with(data_fields(Projection), Projection),',
             replacement: 'DataDiffers = As =/= Projection,',
             property: 'floor_minimal'),
    Seed.new(fault: 'the mastering rule removed',
             anchor: 'check(As =:= Projection orelse As =:= Decoding, reset);',
             replacement: 'ok;',
             property: 'mastering_rule')
  ].freeze

  def test_pcie_plan_cases_pass_under_eunit
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
      assert_match(/#{Regexp.escape(CATCHING_CASE)}[^\n]*\*failed\*/, output, seed.fault)
      assert_includes output, "{#{seed.property},", seed.fault
    end
  end

  private

  # The module's text compiled in place of the application's own, then the cases.
  def run_cases(module_text)
    Dir.mktmpdir('erx-pcie-plan-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { MODULE => module_text })
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_pcie_plan_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
