# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The TRB form's core on the DMA ledger (erx_device_trb_form.h): its layout, its endpoints, and
# every sequence of posts and releases up to a fixed depth against a reference model
# (test/fixtures/erx_device_trb_form_harness.c), clean under the address and undefined
# sanitizers. Each seed plants one fault and is shown caught.
class ErxDeviceTrbFormTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  HARNESS = File.join(ROOT, 'test/fixtures/erx_device_trb_form_harness.c')
  SOURCES = %w[erx_device_trb_form.c erx_device_trb.c erx_device_ledger.c erx_device_rules.c
               erx_device_sequencer.c].map { |source| File.join(NIFS, source) }.freeze
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  DONE = 'erx_device_trb_form done'

  # The highest free buffer taken instead of the lowest; an out transfer's bytes left out of its
  # buffer; the tag kept at the TD's first TRB, which no completion names; a request the form's
  # test would refuse let through to the ledger, which knows no direction or kind; a buffer of
  # another endpoint's pool named.
  SEEDS = %w[HIGHEST_BUFFER NO_OUT_FILL TAG_AT_FIRST NO_REQUEST_CHECK OTHER_POOL].freeze

  def test_layout_endpoints_posts_and_releases
    output, status = run_harness
    assert status.success?, output
    assert_match(/^#{DONE} /, output)
  end

  SEEDS.each do |seed|
    define_method("test_seed_#{seed.downcase}") do
      output, status = run_harness("-DERX_TRB_FORM_SEED_#{seed}")
      refute status.success?, "#{seed} went unnoticed:\n#{output}"
      assert_match(/^FAILED /, output)
    end
  end

  private

  def run_harness(*defines)
    Dir.mktmpdir('erx-device-trb-form-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *defines, *Erx::Generated.include_flags(root: ROOT),
                                       '-I', NIFS, '-I', ROOT, '-o', binary, HARNESS, *SOURCES)
      return [output, status] unless status.success?

      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    end
  end
end
