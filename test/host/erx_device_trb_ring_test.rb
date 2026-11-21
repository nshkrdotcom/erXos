# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The TRB rings on the DMA core (docs/design-device-dma.md, The ledger, Publication): every
# sequence of runs and releases on a ring up to a fixed depth against a reference model, and the
# bindings (test/fixtures/erx_device_trb_ring_harness.c), clean under the address and undefined
# sanitizers. Each seed plants one fault and is shown caught.
class ErxDeviceTrbRingTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  HARNESS = File.join(ROOT, 'test/fixtures/erx_device_trb_ring_harness.c')
  SOURCES = %w[erx_device_ledger.c erx_device_rules.c erx_device_sequencer.c].map { |source| File.join(NIFS, source) }.freeze
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  DONE = 'erx_device_trb_ring done'

  # A run ending just before the link leaves it untaken, so the position rests on it; a run's
  # first TRB written with its live cycle bit, so the device may take it before the rest; a name
  # of another ring's pool let through; the room rule not asking a ring's positions to be free; a
  # binding of an endpoint bound already, so its runs could reach either ring's buffers; a ring
  # of TRBs laid out at a stride other than a TRB's, where a link would overwrite its neighbours;
  # a run of endpoint 0 finding a transfer ring by its structure, so it reaches a ring no binding
  # gave it; a ring taking more TDs or commands than its pool has buffers, as runs of a setup
  # and a status stage name none.
  SEEDS = %w[RING_NO_LINK FIRST_CYCLE_LIVE NO_BINDING_TEST RING_REUSE_HELD BIND_BOUND_ENDPOINT NO_STRIDE_TEST
             FIND_BOUND_RING NO_RING_BOUND].freeze

  def test_rings_and_bindings
    output, status = run_harness
    assert status.success?, output
    assert_match(/^#{DONE}$/, output)
  end

  SEEDS.each do |seed|
    define_method("test_seed_#{seed.downcase}") do
      output, status = run_harness("-DERX_DMA_SEED_#{seed}")
      refute status.success?, "#{seed} went unnoticed:\n#{output}"
      assert_match(/^FAILED /, output)
    end
  end

  private

  def run_harness(*defines)
    Dir.mktmpdir('erx-device-trb-ring-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *defines, *Erx::Generated.include_flags(root: ROOT),
                                       '-I', NIFS, '-I', ROOT, '-o', binary, HARNESS, *SOURCES)
      return [output, status] unless status.success?

      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    end
  end
end
