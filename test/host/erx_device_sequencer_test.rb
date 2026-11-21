# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The sequencer over virtio's split ring (docs/design-device-dma.md, Verification, The check):
# a publication's records written whole, its chain, available entry and activation, rule 1's
# zeros and the cleans; the acquisition's count and each used element releasing its chain
# (test/fixtures/erx_device_sequencer_harness.c), clean under the address and undefined
# sanitizers. The seed removes rule 1's zeros and is shown to be caught.
class ErxDeviceSequencerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  HARNESS = File.join(ROOT, 'test/fixtures/erx_device_sequencer_harness.c')
  SOURCES = %w[erx_device_ledger.c erx_device_rules.c erx_device_sequencer.c].map { |source| File.join(NIFS, source) }.freeze
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  DONE = 'erx_device_sequencer done'

  # The seeds: rule 1's zeros left out, so a stale byte reaches a buffer the device holds; and the
  # check's idle test removed, so an install zeroes the rings under a live chain.
  SEEDS = %w[NO_ZEROS NO_IDLE_TEST].freeze

  def test_publication_and_acquisition
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
    Dir.mktmpdir('erx-device-sequencer-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *defines, *Erx::Generated.include_flags(root: ROOT),
                                       '-I', NIFS, '-I', ROOT, '-o', binary, HARNESS, *SOURCES)
      return [output, status] unless status.success?

      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    end
  end
end
