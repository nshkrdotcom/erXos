# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_virtio_console_core_tests.erl, the cases of the transmit side of the
# virtio-console line driver (docs/design-bluetooth.md, "The line on QEMU `virt`"), against
# erx_virtio_console_core compiled from source on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies). Then each seeded fault, applied to a copy of the module, must
# fail the case named for it: a write answered before its own pieces are back, or before
# every write ahead of it, so the line hears `written` while bytes are still in the device; one tag more than the queue
# has entries, so a post finds the queue full; and an entry not freed when its buffer comes
# back, so a write longer than the queue never finishes.
class ErxVirtioConsoleCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx_uart].freeze
  MODULE = 'erlang/apps/erx_uart/src/erx_virtio_console_core.erl'
  MODULE_SOURCE = File.join(ROOT, MODULE)
  TESTS = %w[test/erlang/erx_virtio_console_core_tests.erl].freeze
  DEADLINE_SECONDS = '120'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'a write answered before its own pieces are back',
             anchor: '{value, Ref} when map_get(Ref, Left) =:= 0 ->',
             replacement: '{value, Ref} when map_get(Ref, Left) >= 0 ->',
             catching_case: 'a_write_is_answered_once_every_piece_is_back_test'),
    Seed.new(fault: 'a write answered before the writes ahead of it',
             anchor: 'order = queue:in(Ref, Order)',
             replacement: 'order = queue:in_r(Ref, Order)',
             catching_case: 'writes_are_answered_in_the_order_they_came_test'),
    Seed.new(fault: 'one tag more than the queue has entries',
             anchor: 'free = lists:seq(0, Size - 1)',
             replacement: 'free = lists:seq(0, Size)',
             catching_case: 'posts_never_exceed_the_queue_size_test'),
    Seed.new(fault: 'an entry not freed when its buffer comes back',
             anchor: 'C#core{free = [Tag | Free], flight = Rest,',
             replacement: 'C#core{free = Free, flight = Rest,',
             catching_case: 'a_write_past_the_queue_waits_for_returned_entries_test')
  ].freeze

  def test_virtio_console_core_cases_pass_under_eunit
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
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  def run_cases(module_text)
    Dir.mktmpdir('erx-virtio-console-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { MODULE => module_text })
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_virtio_console_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
