# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The split ring's form core over the sequencer (docs/design-device-dma.md, The descriptor
# forms, Releases): every sequence of five operations on rings of two and four entries checked
# against a model and a device that walks each chain from memory, past a u16's wrap, clean
# under the address and undefined sanitizers (test/fixtures/erx_device_virtio_core_harness.c).
# Each seed removes one of virtio's rules the check does not judge and is shown to be caught.
class ErxDeviceVirtioCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  HARNESS = File.join(ROOT, 'test/fixtures/erx_device_virtio_core_harness.c')
  SOURCES = %w[erx_device_ledger.c erx_device_rules.c erx_device_sequencer.c erx_device_virtio_core.c]
            .map { |source| File.join(NIFS, source) }.freeze
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  DONE = 'erx_device_virtio_core done'

  # The seeds of the core, each a rule of virtio's left out: an empty piece posted; a piece the
  # device reads after one it writes; pieces laid over each other instead of end to end; a used
  # len past what the chain let the device write answered. Each with the expectation of the
  # harness that catches it.
  SEEDS = {
    'EMPTY_PIECE' => 'a post answers as the model says',
    'READ_AFTER_WRITE' => 'a post answers as the model says',
    'NOT_PACKED' => 'the pieces lie end to end',
    'LEN_UNCHECKED' => "a len past the chain's writable bytes is ECORRUPT"
  }.freeze

  def test_state_machine
    output, status = run_harness
    assert status.success?, output
    assert_match(/^#{DONE}$/, output)
  end

  SEEDS.each do |seed, caught_by|
    define_method("test_seed_#{seed.downcase}") do
      output, status = run_harness("-DERX_DMA_SEED_#{seed}")
      refute status.success?, "#{seed} went unnoticed:\n#{output}"
      assert_match(/^FAILED .*: #{Regexp.escape(caught_by)}$/, output)
    end
  end

  private

  def run_harness(*defines)
    Dir.mktmpdir('erx-device-virtio-core-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *defines, *Erx::Generated.include_flags(root: ROOT),
                                       '-I', NIFS, '-I', ROOT, '-o', binary, HARNESS, *SOURCES)
      return [output, status] unless status.success?

      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    end
  end
end
