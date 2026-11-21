# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The TRB form's sequences applied by an effect layer onto the hosted model of a non-coherent cache
# against a model of the controller, which takes a TRB the moment its cycle bit matches and
# reports through the event ring, over long traces of transfers, failures, stops, drops and slot
# reuse (test/fixtures/erx_device_trb_form_model_harness.c), clean under the address and undefined
# sanitizers. Each seed plants one fault and is shown caught.
class ErxDeviceTrbFormModelTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  HARNESS = File.join(ROOT, 'test/fixtures/erx_device_trb_form_model_harness.c')
  SOURCES = %w[erx_device_trb_form.c erx_device_trb.c erx_device_trb_model.c erx_dma_model.c erx_device_ledger.c
               erx_device_rules.c erx_device_sequencer.c].map { |source| File.join(NIFS, source) }.freeze
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  DONE = 'erx_device_trb_form_model done'

  # A run's first TRB stored with its live cycle bit before the run's cleans, so the controller
  # may take it while the bytes it names are still dirty in the cache; Configure Endpoint's input
  # context pointing each added ring at the other's TRBs; and, in this effect layer, a run's
  # activation stored before the cleans of what it publishes.
  SEEDS = %w[ERX_DMA_SEED_FIRST_CYCLE_LIVE ERX_DMA_SEED_DEQUEUE_OTHER_RING HARNESS_SEED_PUBLISH_BEFORE_CLEAN].freeze

  def test_long_traces_over_the_cache_model
    output, status = run_harness
    assert status.success?, output
    assert_match(/^#{DONE}$/, output)
  end

  SEEDS.each do |seed|
    define_method("test_seed_#{seed.downcase}") do
      output, status = run_harness("-D#{seed}")
      refute status.success?, "#{seed} went unnoticed:\n#{output}"
      assert_match(/^FAILED /, output)
    end
  end

  private

  def run_harness(*defines)
    Dir.mktmpdir('erx-device-trb-form-model-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *defines, *Erx::Generated.include_flags(root: ROOT),
                                       '-I', NIFS, '-I', ROOT, '-o', binary, HARNESS, *SOURCES)
      return [output, status] unless status.success?

      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    end
  end
end
