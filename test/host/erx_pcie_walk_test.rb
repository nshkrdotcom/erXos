# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_pcie_walk_tests.erl, the cases of the walk and the ECAM bridge
# driver over the configuration-space model test/erlang/erx_pcie_model.erl, and
# test/erlang/erx_pcie_place_tests.erl, the cases of placement, against the erx_pcie
# application compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies). Then each seeded fault, applied to a copy of its module, must fail
# the case named for it (docs/design-pcie.md, "Host tests of the pure cores"): the
# closed bridge's place check removed, so the walk reaches function 1 of the root
# port's bus; ECAM's bus range ignored; the header type taken by parse/1 alone, so a
# CardBus header reads as malformed; a sized BAR left at all ones; and the alignment
# rounding dropped, so the 64 KiB BAR lands at 4 KiB.
class ErxPcieWalkTest < Minitest::Test
  APPLICATIONS = %w[erx_pcie].freeze
  TESTS = %w[test/erlang/erx_pcie_cfg_tests.erl test/erlang/erx_pcie_model.erl
             test/erlang/erx_pcie_walk_tests.erl test/erlang/erx_pcie_place_tests.erl].freeze
  CASES = %w[erx_pcie_walk_tests erx_pcie_place_tests].freeze
  DEADLINE_SECONDS = '120'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: "the closed bridge's place check removed",
             module_path: 'erlang/apps/erx_pcie/src/erx_pcie_bridge.erl',
             anchor: '    Device =:= 0 andalso Function =:= 0;',
             replacement: '    is_integer(Device + Function);',
             catching_case: 'a_closed_bridge_reaches_only_its_root_port_and_listed_places_test'),
    Seed.new(fault: "ECAM's bus range ignored",
             module_path: 'erlang/apps/erx_pcie/src/erx_pcie_bridge.erl',
             anchor: '    First =< Bus andalso Bus =< Last;',
             replacement: '    First =< Bus andalso is_integer(Last);',
             catching_case: 'ecam_answers_absent_outside_its_bus_range_without_touching_the_window_test'),
    Seed.new(fault: 'the header type taken by parse/1 alone',
             module_path: 'erlang/apps/erx_pcie/src/erx_pcie_walk.erl',
             anchor: '    case lists:keymember(Type, 2, ?ERX_PCIE_HEADER_MEMBERS) of',
             replacement: '    case is_integer(Type) of',
             catching_case: 'a_header_type_above_1_is_unsupported_without_a_parse_test'),
    Seed.new(fault: 'a sized BAR left at all ones',
             module_path: 'erlang/apps/erx_pcie/src/erx_pcie_walk.erl',
             anchor: '     write(Place, Register, 4, Original)].',
             replacement: '     write(Place, Register, 4, Original bor 16#ffffffff)].',
             catching_case: 'a_placing_walk_sizes_memory_bars_and_restores_them_test'),
    Seed.new(fault: 'the alignment rounding dropped',
             module_path: 'erlang/apps/erx_pcie/src/erx_pcie_place.erl',
             anchor: '    #{order => {Place, Index}, span => Span, alignment => Span,',
             replacement: '    #{order => {Place, Index}, span => Span, alignment => ?ERX_PAGE_SIZE,',
             catching_case: 'a_fixed_set_gets_the_addresses_written_here_test')
  ].freeze

  def test_walk_place_and_ecam_cases_pass_under_eunit
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

  # The modules' text, any replaced, compiled with the cases, then the cases run.
  def run_cases(replaced)
    Dir.mktmpdir('erx-pcie-walk-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      modules = CASES.join(', ')
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', "halt(case eunit:test([#{modules}], [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
