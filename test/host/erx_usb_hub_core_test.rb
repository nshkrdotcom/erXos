# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_usb_hub_core_tests.erl, the cases of the hub function's machine,
# explored to a fixed point, and of the hub decoders, against the module compiled from
# source on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). Then each
# seeded fault, applied to a copy of the module, must fail the case named for it: a
# change report sent with the next transfer already posted, so a hub has two bitmaps in
# flight; the bus process's answer taken without posting the next transfer, so the hub
# falls silent; and the bits above the port count kept, so a report names ports the hub
# does not have; and a report shorter than the port count taken as naming nothing, so
# the ports it should have named are never read.
class ErxUsbHubCoreTest < Minitest::Test
  APPLICATIONS = %w[erx_usb].freeze
  CORE = 'erlang/apps/erx_usb/src/erx_usb_hub_core.erl'
  TESTS = %w[test/erlang/erx_usb_hub_core_tests.erl].freeze
  DEADLINE_SECONDS = '120'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'a change report sent with the next transfer posted',
             anchor: 'Set -> {State#{phase := reporting}, [{changed, Set}]}',
             replacement: 'Set -> {State#{phase := posted}, [{changed, Set}, {post, transfer_length(Ports)}]}',
             catching_case: 'the_machine_keeps_one_bitmap_in_flight_test'),
    Seed.new(fault: "the bus process's answer taken without posting the next transfer",
             anchor: "step(handled, State = \#{phase := reporting}) ->\n    post(State);",
             replacement: "step(handled, State = \#{phase := reporting}) ->\n    {State\#{phase := posted}, []};",
             catching_case: 'the_machine_keeps_one_bitmap_in_flight_test'),
    Seed.new(fault: 'the bits above the port count kept',
             anchor: '[Port || Port <- lists:seq(1, Ports), Bits band (1 bsl Port) =/= 0]',
             replacement: '[Port || Port <- lists:seq(1, 8 * Length - 1), Bits band (1 bsl Port) =/= 0]',
             catching_case: 'the_bitmap_names_bit_n_as_port_n_test'),
    Seed.new(fault: 'a report shorter than the port count taken as naming nothing',
             anchor: '_Short ->
            lists:seq(1, Ports) ++ [hub]',
             replacement: '_Short ->
            []',
             catching_case: 'the_bitmap_names_bit_n_as_port_n_test')
  ].freeze

  def test_hub_core_cases_pass_under_eunit
    output, status = run_cases
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, CORE))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases(replaced: { CORE => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  def run_cases(replaced: {})
    Dir.mktmpdir('erx-usb-hub-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_usb_hub_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
