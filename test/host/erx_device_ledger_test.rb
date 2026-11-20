# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The ledger of a queue's DMA memory and the check's rules over descriptions
# (docs/design-device-dma.md, Verification, The check): the install's check of a layout, each
# rule refusing the publication it exists for, and the ledger's hold and release against a
# reference model on every sequence of events up to a fixed depth
# (test/fixtures/erx_device_ledger_harness.c), clean under the address and undefined
# sanitizers. Each seed removes one test of the code and is shown to let its case through.
class ErxDeviceLedgerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  HARNESS = File.join(ROOT, 'test/fixtures/erx_device_ledger_harness.c')
  SOURCES = %w[erx_device_ledger.c erx_device_rules.c].map { |source| File.join(NIFS, source) }.freeze
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  DONE = 'erx_device_ledger done'

  # The seeds of the ledger (the layout's granule test, a holding begun over a held record or
  # buffer, a release of a holding not live, a region found by no name) and of each rule of the
  # check.
  SEEDS = %w[NO_GRANULE_TEST HOLD_WHILE_HELD RELEASE_TWICE NO_MEANING_TEST NO_WIDTH_TEST NO_RANGE_TEST
             NO_HELD_TEST NO_LENGTH_TEST NO_ROOM_TEST NO_FILLS_TEST NO_OVERLAP_TEST
             NO_ENTRY_LENGTH_TEST ANY_REGION].freeze

  def test_ledger_and_rules
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
    Dir.mktmpdir('erx-device-ledger-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *defines, *Erx::Generated.include_flags(root: ROOT),
                                       '-I', NIFS, '-I', ROOT, '-o', binary, HARNESS, *SOURCES)
      return [output, status] unless status.success?

      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    end
  end
end
