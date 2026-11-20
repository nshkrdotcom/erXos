# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# xHCI's TRB ring form (docs/design-usb.md, "The TRB ring form" and Verification): the form's
# pure core, erx_device_trb, explored over the design's small model
# (test/fixtures/erx_device_trb_harness.c), then driven through the sequencer over the hosted
# model of a non-coherent cache against a model controller that takes a TRB the moment its
# cycle bit matches, for traces of 100,000 transfers and 1,000 slot reuses
# (test/fixtures/erx_device_trb_model_harness.c), each clean under the address and undefined
# sanitizers. Each seeded fault is planted and shown to fail the check that guards it.
class ErxDeviceTrbTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  Harness = Data.define(:fixture, :sources, :done)
  EXPLORER = Harness.new(fixture: 'test/fixtures/erx_device_trb_harness.c',
                         sources: %w[erx_device_trb.c], done: 'erx_device_trb done')
  MODEL = Harness.new(fixture: 'test/fixtures/erx_device_trb_model_harness.c',
                      sources: %w[erx_device_trb.c erx_device_trb_model.c erx_device_dma.c erx_dma_model.c],
                      done: 'erx_device_trb_model done')

  # Each seeded fault the design names for this core, the harness that must catch it and the
  # check that does: the enqueue position left on the link after a post that ends before it;
  # Disable Slot accepted with a queue running; the stop span narrowed to the oldest transfer's
  # first TRB and the enqueue position, so the TRB a completion retired, which a stop's forced
  # event names, falls outside it; and the first TRB's cycle word written with the other TRBs,
  # which the model controller takes before its bytes are clean.
  SEEDS = {
    'ERX_DEVICE_TRB_SEED_LINK_REST' => [EXPLORER, /^FAILED .*block->ring\.enqueue < RING_TRBS - 1u$/],
    'ERX_DEVICE_TRB_SEED_DISABLE_RUNNING' => [EXPLORER, /^FAILED .*disable_allowed\(&before/],
    'ERX_DEVICE_TRB_SEED_NARROW_SPAN' => [EXPLORER, /^FAILED .*in_stop_span\(&layout, block, block->span_start\)$/],
    'ERX_DEVICE_TRB_SEED_CYCLE_WITH_WRITES' => [MODEL, /^FAILED .*(h->read|bytes)\[index\] == erx_device_trb_model_pattern/]
  }.freeze

  def test_bookkeeping_explored
    output, status = run_harness(EXPLORER)
    assert status.success?, output
    assert_match(/^erx_device_trb explored \d+ states to depth \d+/, output)
    assert_match(/^#{EXPLORER.done}$/, output)
  end

  def test_publication_and_traces_over_a_non_coherent_cache
    output, status = run_harness(MODEL)
    assert status.success?, output
    assert_match(/^#{MODEL.done}$/, output)
  end

  SEEDS.each do |seed, (harness, caught_by)|
    define_method("test_seed_#{seed.downcase}") do
      output, status = run_harness(harness, "-D#{seed}")
      refute status.success?, "#{seed} went unnoticed:\n#{output}"
      assert_match(caught_by, output)
    end
  end

  private

  def run_harness(harness, *defines)
    Dir.mktmpdir('erx-device-trb-') do |directory|
      binary = File.join(directory, 'harness')
      sources = [File.join(ROOT, harness.fixture), *harness.sources.map { |source| File.join(NIFS, source) }]
      output, status = Open3.capture2e(COMPILER, *FLAGS, *defines, *Erx::Generated.include_flags(root: ROOT),
                                       '-I', NIFS, '-I', ROOT, '-o', binary, *sources)
      return [output, status] unless status.success?

      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    end
  end
end
