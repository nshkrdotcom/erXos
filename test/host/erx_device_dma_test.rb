# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The pure core of DMA by devices that are not cache-coherent (docs/design-device-dma.md,
# Verification): the plan sequencer and the whole-plan check over every transition of a small
# queue (test/fixtures/erx_device_dma_order_harness.c), and the split ring's core and its
# sequencer applied over the hosted model of a non-coherent cache
# (test/fixtures/erx_device_dma_model_harness.c), clean under the address and undefined
# sanitizers. Each seeded fault the design names is planted and shown to fail its assertion:
# the order harness's in erx_device_dma.c, the model harness's in the split ring's sequencer
# and in the harness's own effect layer.
class ErxDeviceDmaTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  ORDER = { harness: 'test/fixtures/erx_device_dma_order_harness.c',
            sources: %w[erx_device_dma.c], done: 'erx_device_dma_order done' }.freeze
  MODEL = { harness: 'test/fixtures/erx_device_dma_model_harness.c',
            sources: %w[erx_device_ledger.c erx_device_rules.c erx_device_sequencer.c
                        erx_device_virtio_core.c erx_dma_model.c],
            done: 'erx_device_dma_model done' }.freeze
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  # Each seed of erx_device_dma.c's sequencer or check that the order harness catches.
  ORDER_SEEDS = %w[PUBLISH_BEFORE_CLEAN NO_REPORT_BARRIER REPORT_BARRIER_LOADS STEP_BY_GRANULE
                   NO_GRANULE_CHECK].freeze
  # What the model harness catches over a non-coherent cache. The split ring's sequencer: the
  # install leaving the used ring's former bytes, its zeroing left in the cache, rule 1's zeros
  # left out. The harness's own effect layer (its header comment): a post's cleans skipped, its
  # available index published before them, a written range read back without its invalidate.
  MODEL_SEEDS = %w[ERX_DMA_SEED_INSTALL_NOT_ZEROED ERX_DMA_SEED_INSTALL_UNCLEANED ERX_DMA_SEED_NO_ZEROS
                   HARNESS_SEED_NO_POST_CLEANS HARNESS_SEED_PUBLISH_BEFORE_CLEAN
                   HARNESS_SEED_NO_WRITTEN_INVALIDATE].freeze

  def test_order_and_check
    output, status = run_harness(ORDER)
    assert status.success?, output
    assert_match(/^#{ORDER[:done]}$/, output)
  end

  def test_split_ring_over_a_non_coherent_cache
    output, status = run_harness(MODEL)
    assert status.success?, output
    assert_match(/^#{MODEL[:done]}$/, output)
  end

  ORDER_SEEDS.each do |seed|
    define_method("test_order_seed_#{seed.downcase}") { assert_seed_caught(ORDER, "-DERX_DMA_SEED_#{seed}") }
  end

  MODEL_SEEDS.each do |seed|
    define_method("test_model_seed_#{seed.downcase}") { assert_seed_caught(MODEL, "-D#{seed}") }
  end

  private

  def assert_seed_caught(harness, define)
    output, status = run_harness(harness, define)
    refute status.success?, "#{define} went unnoticed:\n#{output}"
    assert_match(/^FAILED /, output)
  end

  def run_harness(harness, *defines)
    Dir.mktmpdir('erx-device-dma-') do |directory|
      binary = File.join(directory, 'harness')
      sources = [File.join(ROOT, harness[:harness]), *harness[:sources].map { |source| File.join(NIFS, source) }]
      output, status = Open3.capture2e(COMPILER, *FLAGS, *defines, *Erx::Generated.include_flags(root: ROOT), '-I', NIFS, '-I', ROOT, '-o', binary, *sources)
      return [output, status] unless status.success?

      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: "")
    end
  end
end
