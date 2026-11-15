# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_hold_tests.erl, the EUnit cases of the header drivers' hold,
# against erx_hold compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies). Then each seeded fault of the erx_hold row of
# docs/design-header-io.md's Verification table, applied to a copy of the module, must
# fail every case named for it, which shows those cases run the code the fault breaks.
class ErxHoldTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx/src/erx_hold.erl')
  TESTS_SOURCE = File.join(ROOT, 'test/erlang/erx_hold_tests.erl')
  EXHAUSTIVE = 'every_sequence_of_six_events_over_two_grants_and_two_resources_test'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_cases)

  SEEDS = [
    Seed.new(fault: 'releasing at the first close instead of the last',
             anchor: '        #hold{holder = Grant, handles = [Serial]} ->',
             replacement: '        #hold{holder = Grant} ->',
             catching_cases: [EXHAUSTIVE, 'a_grant_with_two_handles_releases_at_the_last_close_test']),
    Seed.new(fault: 'the operation check removed',
             anchor: "        #hold{} -> {ok, Resource};\n        dead -> {error, eio}",
             replacement: '        _ -> {ok, Resource}',
             catching_cases: [EXHAUSTIVE, 'an_operation_after_its_grants_end_and_anothers_open_is_refused_test'])
  ].freeze

  def test_hold_cases_pass_under_eunit
    output, status = eunit(File.binread(MODULE_SOURCE), warnings_as_errors: true)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_cases
    source = File.binread(MODULE_SOURCE)
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "no single anchor for #{seed.fault} in #{MODULE_SOURCE}"
      output, status = eunit(source.sub(seed.anchor, seed.replacement), warnings_as_errors: false)
      refute status.success?, "#{seed.fault} passed every case:\n#{output}"
      seed.catching_cases.each do |name|
        assert_match(/#{name}\.\.\.(\[[^\]]*\] )?\*failed\*/, output, "#{name} did not catch #{seed.fault}")
      end
    end
  end

  private

  def eunit(module_text, warnings_as_errors:)
    Dir.mktmpdir('erx-hold-test') do |work|
      module_path = File.join(work, 'erx_hold.erl')
      File.binwrite(module_path, module_text)
      flags = warnings_as_errors ? ['-Werror'] : []
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *flags, '-o', work, module_path, TESTS_SOURCE,
                                       stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_hold_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
