# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_pcie_walk_tests.erl, the cases of the walk and the ECAM bridge
# driver over the configuration-space model test/erlang/erx_pcie_model.erl, and
# test/erlang/erx_pcie_place_tests.erl, the cases of placement, and
# test/erlang/erx_pcie_enumerator_tests.erl, the enumerator's start and its pcie
# operations over the same model, test/erlang/erx_pcie_apply_tests.erl, the planner's
# effect layer over the model with writes that do not take, and
# test/erlang/erx_pcie_facet_tests.erl, the pcie facet in front of a stand-in enumerator,
# against the erx_pcie
# application compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies). Then each seeded fault, applied to a copy of its module, must fail
# the case named for it (docs/design-pcie.md, "Host tests of the pure cores"): the pcie
# facet's setting check removed, so a setting of no mode reaches the enumerator; the
# closed bridge's place check removed, so the walk reaches function 1 of the root
# port's bus; ECAM's bus range ignored; the header type taken by parse/1 alone, so a
# CardBus header reads as malformed; a sized BAR left at all ones; the alignment
# rounding dropped, so the 64 KiB BAR lands at 4 KiB; and an unused window slot, of size
# 0, taken as placement's window, so a BAR that fits the real one is unplaced; the
# report's answer taken without being applied, so a decoding answer for a function
# the start set off never reaches it; a function whose identity
# changed reported without being lowered, so it keeps decoding; a function whose record
# differs from its layout only where the identity does not look started at its setting,
# so it keeps mastering; one readback after the
# last stage, so with a disable ignored a BAR is written while the model decodes; and
# the descent to quiet taken as done without its readback, so with the command register
# ignoring writes the answer is gone while the model is not quiet.
class ErxPcieWalkTest < Minitest::Test
  APPLICATIONS = %w[erx_pcie].freeze
  TESTS = %w[test/erlang/erx_pcie_cfg_tests.erl test/erlang/erx_pcie_model.erl
             test/erlang/erx_pcie_walk_tests.erl test/erlang/erx_pcie_place_tests.erl
             test/erlang/erx_pcie_enumerator_tests.erl test/erlang/erx_pcie_plan_tests.erl
             test/erlang/erx_pcie_apply_tests.erl test/erlang/erx_pcie_facet_tests.erl].freeze
  CASES = %w[erx_pcie_walk_tests erx_pcie_place_tests erx_pcie_enumerator_tests erx_pcie_apply_tests
             erx_pcie_facet_tests].freeze
  DEADLINE_SECONDS = '120'

  # A seed may also name the property its catching case must report broken.
  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case, :property) do
    def initialize(property: nil, **fields) = super(property: property, **fields)
  end

  SEEDS = [
    Seed.new(fault: "the pcie facet's setting check removed",
             module_path: 'erlang/apps/erx_pcie/src/erx_pcie_facet.erl',
             anchor: 'well_formed({set, Key, Setting}) -> key(Key) andalso setting(Setting);',
             replacement: 'well_formed({set, Key, Setting}) -> key(Key) andalso (setting(Setting) orelse true);',
             catching_case: 'a_request_out_of_shape_reaches_no_enumerator_test'),
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
             catching_case: 'a_fixed_set_gets_the_addresses_written_here_test'),
    Seed.new(fault: 'an unused window of size 0 taken as the window',
             module_path: 'erlang/apps/erx_pcie/src/erx_pcie.erl',
             anchor: '    [Window || #{size := Size} = Window <- Windows, Size > 0].',
             replacement: '    [Window || #{size := Size} = Window <- Windows, is_integer(Size)].',
             catching_case: 'the_window_is_the_first_low_memory_window_that_is_not_prefetchable_test'),
    Seed.new(fault: "the report's answer taken without applying it",
             module_path: 'erlang/apps/erx_pcie/src/erx_pcie_enumerator.erl',
             anchor: '    case maps:get(Key, Settings, off()) of',
             replacement: '    case Setting of',
             catching_case: 'a_later_start_applies_an_answered_setting_and_serves_set_test'),
    Seed.new(fault: 'a function with another identity left unlowered',
             module_path: 'erlang/apps/erx_pcie/src/erx_pcie_enumerator.erl',
             anchor: '            {_, Quiet} = erx_pcie_apply:quiet(place(Record), Next),',
             replacement: '            Quiet = Next,',
             catching_case: 'a_function_with_another_identity_is_reported_unplaced_and_lowered_test'),
    Seed.new(fault: 'a changed function started at its setting',
             module_path: 'erlang/apps/erx_pcie/src/erx_pcie_enumerator.erl',
             anchor: '      changed => maps:remove(state, Record) =/= maps:remove(state, Target)}.',
             replacement: '      changed => false}.',
             catching_case: 'a_changed_function_starts_off_whatever_its_setting_test'),
    Seed.new(fault: 'one readback after the last stage',
             module_path: 'erlang/apps/erx_pcie/src/erx_pcie_apply.erl',
             anchor: '    case erx_pcie_plan:differs(Read, State) of',
             replacement: '    case erx_pcie_plan:differs(Read, case Stages of [] -> State; _ -> maps:with([identity], State) end) of',
             catching_case: 'apply endpoint msi64_mask msix true', property: 'data_while_quiet'),
    Seed.new(fault: 'the descent to quiet taken as done without its readback',
             module_path: 'erlang/apps/erx_pcie/src/erx_pcie_apply.erl',
             anchor: '    {ok, Stages} = erx_pcie_plan:quiet(Read),',
             replacement: '    {ok, Stages} = {ok, [S#{state := maps:with([identity], St)} || ' \
                          '#{state := St} = S <- element(2, erx_pcie_plan:quiet(Read))]},',
             catching_case: 'apply endpoint msi64_mask msix true', property: 'answer')
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
      assert_match(/\b#{seed.property}\s*=>/, output, seed.fault) if seed.property
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
