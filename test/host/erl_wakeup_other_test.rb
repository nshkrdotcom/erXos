# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'

# The run queues' wakeup-other checks (otp/erts/emulator/beam/erl_wakeup_other.h), through
# test/fixtures/erl_wakeup_other_harness.c under the address and undefined sanitizers, against a
# model in exact integers. A dirty I/O call is charged its elapsed time, up to INT_MAX reductions
# (docs/design-runtime.md, edit 68), so the checks must take any charge and any queue length
# without overflow, and the default check's count stays within [0, limit] on every queue kind: a
# normal queue's count returns to zero when it passes its limit, a dirty queue's holds at the limit.
# Seeded faults of the core must each fail the harness.
class ErlWakeupOtherTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  BEAM = File.join(ROOT, 'otp/erts/emulator/beam')
  CORE = File.join(BEAM, 'erl_wakeup_other.h')
  HARNESS = File.join(ROOT, 'test/fixtures/erl_wakeup_other_harness.c')
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-fno-omit-frame-pointer',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  INT_MAX = (2**31) - 1

  # Representative inputs: erl_process.c's five thresholds at CONTEXT_REDS 4000, as
  # [limit, dec_shift]; its increments and the legacy decrement; and charges and lengths from one
  # reduction and an empty queue to INT_MAX, and past it the sums of several dirty schedulers'
  # charges to the queue they share.
  THRESHOLDS = [[800_000, 3], [200_000, 1], [40_000, 0], [4000, -2], [400, -5]].freeze
  INC = 400
  LEGACY_DEC = 10
  REDS = [1, 400, 4000, 2**30, INT_MAX, 2 * INT_MAX, 1024 * INT_MAX].freeze
  LENS = [0, 1, 2, 3, 1000, INT_MAX].freeze
  FIELDS = { default: %w[count reds len limit inc dec_shift dirty], legacy: %w[count reds len limit inc dec] }.freeze

  # Each mutant changes one expression of the core.
  MUTANTS = {
    'a dirty count runs past its limit' => ['{ dirty ? limit : 0, true }', '{ dirty ? (int)next : 0, true }'],
    'the backlog charge in int' => ['left_len * charge', '(int)left_len * (int)charge'],
    'a summed charge not clamped' => ['return (reds > INT_MAX ? INT_MAX : reds);', 'return (reds);'],
    'no decay below a shift of zero' => ['charge >> -dec_shift', '0'],
    'a legacy count past INT_MAX' => ['next > INT_MAX ? INT_MAX : (int)next', '(int)next']
  }.freeze

  def test_every_step_matches_the_model
    cases = default_cases + legacy_cases
    Dir.mktmpdir('erl-wakeup-other-') do |directory|
      output = run_harness(directory, cases)
      steps = output.lines.grep(/\A-?\d+ [01]\n\z/).map { |line| line.split.map { Integer(_1) } }
      assert_equal cases.size, steps.size, output
      cases.zip(steps).each do |(kind, *input), step|
        assert_equal model(kind, *input), step,
                     "#{kind}: #{FIELDS.fetch(kind).zip(input).map { |field, value| "#{field} #{value}" }.join(', ')}"
      end
    end
  end

  def test_every_mutant_fails_the_harness
    MUTANTS.each do |name, (original, replacement)|
      Dir.mktmpdir('erl-wakeup-other-mutant-') do |directory|
        output, status = build_and_run(directory, mutate(directory, original, replacement),
                                       default_cases + legacy_cases)
        refute status.success? && output == expected_output, "mutant survived the harness: #{name}"
      end
    end
  end

  private

  # The default check's count is within [0, limit] on entry.
  def default_cases
    THRESHOLDS.flat_map do |limit, dec_shift|
      [0, 1, limit - 1, limit].product(REDS, LENS, [0, 1]).map do |count, reds, len, dirty|
        [:default, count, reds, len, limit, INC, dec_shift, dirty]
      end
    end
  end

  def legacy_cases
    THRESHOLDS.flat_map do |limit, _dec_shift|
      [0, limit - 1, limit, INT_MAX].product(REDS, LENS).map do |count, reds, len|
        [:legacy, count, reds, len, limit, INC, LEGACY_DEC]
      end
    end
  end

  # [count, over] of one step, in exact integers.
  # A summed charge counts as INT_MAX, which already passes every limit.
  def model(kind, count, summed_reds, len, limit, inc, last, dirty = nil)
    reds = [summed_reds, INT_MAX].min
    case kind
    in :default if len - 1 < 1
      [[count - (last >= 0 ? reds << last : reds >> -last), 0].max, 0]
    in :default
      next_count = count + ((len - 1) * reds) + inc
      next_count > limit ? [dirty == 1 ? limit : 0, 1] : [next_count, 0]
    in :legacy if len < 2
      [[count - (last * reds), 0].max, 0]
    in :legacy
      count >= limit ? [0, 1] : [[count + (len * reds) + inc, INT_MAX].min, 0]
    end
  end

  def expected_output
    (default_cases + legacy_cases).map { |kind, *input| "#{model(kind, *input).join(' ')}\n" }.join +
      "erl_wakeup_other done\n"
  end

  def mutate(directory, original, replacement)
    source = File.read(CORE)
    raise "mutation site is gone: #{original}" unless source.include?(original)

    mutant = File.join(directory, 'include')
    Dir.mkdir(mutant)
    File.write(File.join(mutant, 'erl_wakeup_other.h'), source.sub(original) { replacement })
    mutant
  end

  def build_and_run(directory, include_directory, cases)
    program = File.join(directory, 'harness')
    output, status = Open3.capture2e(COMPILER, *FLAGS, '-I', include_directory, HARNESS, '-o', program,
                                     stdin_data: '')
    assert status.success?, output
    input = cases.map { |row| "#{row.join(' ')}\n" }.join
    Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), program, stdin_data: input)
  end

  def run_harness(directory, cases)
    output, status = build_and_run(directory, BEAM, cases)
    assert status.success?, output
    assert_match(/^erl_wakeup_other done$/, output)
    output
  end
end
