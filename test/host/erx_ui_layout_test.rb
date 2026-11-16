# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_ui_layout_tests.erl, the worked layouts and the properties of
# erx_ui_layout, the widget toolkit's box model (docs/design-display.md, "The box model"),
# compiled on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). Then each
# seeded fault of "Verification and testing", applied to a copy of erx_ui_layout, must fail
# the property named for it.
class ErxUiLayoutTest < Minitest::Test
  APPLICATIONS = %w[erx_ui].freeze
  MODULE_SOURCE = 'erlang/apps/erx_ui/src/erx_ui_layout.erl'
  TESTS = %w[test/erlang/erx_ui_layout_tests.erl].freeze
  DEADLINE_SECONDS = '300'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'pads wider than their node that leave a negative size',
             anchor: 'Inner = max(0, Length - 2 * Pad),',
             replacement: 'Inner = Length - 2 * Pad,',
             catching_case: 'containment_test_'),
    Seed.new(fault: 'a layout that ignores the pad',
             anchor: 'Content = content(Kind, inset(Rect, pad(Props)), Children),',
             replacement: 'Content = content(Kind, Rect, Children),',
             catching_case: 'padded_test_'),
    Seed.new(fault: 'a filling node placed inside its pads, as an outside pad would place it',
             anchor: 'span(X, Width, NeedWidth, Align, maps:is_key(width, Props)),',
             replacement: 'span(X + pad(Props), max(0, Width - 2 * pad(Props)), NeedWidth, Align, ' \
                          'maps:is_key(width, Props)),',
             catching_case: 'padded_test_'),
    Seed.new(fault: 'slots that do not advance past one another',
             anchor: '{{At, Length}, At + Length}',
             replacement: '{{At, Length}, At}',
             catching_case: 'siblings_apart_test_'),
    # Rounding the running sums of the weights hands a middle weight fewer
    # units from more room: weights 2, 1, 2 give it 1 of 2 units and 0 of 3.
    Seed.new(fault: 'a leftover shared by rounding running sums',
             anchor: 'award(Left - lists:sum(Quotas), lists:zip(Weights, Quotas))',
             replacement: '_ = Quotas, {Ends, _} = lists:mapfoldl(fun(Weight, Sum) -> ' \
                          '{Left * (Sum + Weight) div Total, Sum + Weight} end, 0, Weights), ' \
                          'element(1, lists:mapfoldl(fun(End, Start) -> {End - Start, End} end, 0, Ends))',
             catching_case: 'monotonic_test_'),
    # A line that starts on an odd window pixel loses one pixel of its room, so its
    # shares and cuts depend on where it lies, not on its slot alone.
    Seed.new(fault: "a line's lengths that depend on its distance from the window's origin",
             anchor: 'Lengths = distribute(Room, ',
             replacement: 'Lengths = distribute(max(0, Room - start(Direction, Content) rem 2), ',
             catching_case: 'contract_test_')
  ].freeze

  def test_layout_cases_pass_under_eunit
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_property
    source = File.binread(File.join(ErlangBuild::ROOT, MODULE_SOURCE))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "anchor for #{seed.fault} is not once in #{MODULE_SOURCE}"
    end
    runs = SEEDS.map do |seed|
      Thread.new { [seed, *eunit({ MODULE_SOURCE => source.sub(seed.anchor) { seed.replacement } })] }
    end
    runs.map(&:value).each do |seed, output, status|
      refute status.success?, "#{seed.fault} passed every case:\n#{output}"
      assert_match(failed_case(seed.catching_case), output, "#{seed.catching_case} did not catch #{seed.fault}")
    end
  end

  private

  # EUnit names a generator's case by the fun inside it.
  def failed_case(name) = %r{#{Regexp.escape(name)}(/0-fun-\d+-)?\.\.\.(\[[^\]]*\] )?\*failed\*}

  # The cases' output and status, over the applications with the sources of replaced in place of the tree's.
  def eunit(replaced)
    Dir.mktmpdir('erx-ui-layout-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_ui_layout_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
