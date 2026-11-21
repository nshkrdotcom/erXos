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
# every sequence of posts and of releases through the event ring up to a fixed depth against a
# reference model (test/fixtures/erx_device_trb_form_harness.c), clean under the address and undefined
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
  # another endpoint's pool named; an event of another endpoint releasing this one's holding; the
  # dequeue pointer left before the consumed events; a ring taking more TDs than its pool has
  # buffers; the event ring's cycle state compared inverted; a device address mapped to the record
  # after the one it names; any transfer event taken, not only its ring's oldest; an error halting
  # the newest transfer; no reach rule; no endpoint closed by the command in flight; a Set TR
  # Dequeue Pointer retiring nothing; a drop of a halted endpoint let through; a stop's event
  # taken with no Stop Endpoint in flight; a second command let in while one is in flight; a
  # failed Address Device ending EP0's binding; a post let through on a stopped endpoint; a retired
  # transfer an error answered answered again; an input context's dequeue pointer from another
  # binding's ring; a drop's flag left out; A1 set on Configure Endpoint; a burst past 15 accepted;
  # an Evaluate Context let through on a busy EP0; a Configure Endpoint on an unaddressed slot; a
  # Stop Endpoint, Reset Endpoint or Set TR Dequeue Pointer let through in any state but disabled;
  # an Address Device on a slot no Enable Slot enabled; the controller's HCRST written before it
  # halts; the install written while the controller is not ready; the start answered while the
  # controller is still halted; a begun negotiation resuming the step its record keeps; USBCMD
  # written while HCRST or CNR reads set; and the install made straight after the reset, before
  # the driver could master its function.
  SEEDS = %w[DMA_SEED_DEQUEUE_OTHER_RING DMA_SEED_DROP_MISSING DMA_SEED_CONFIGURE_ADDS_EP0
             DEVICE_TRB_SEED_BURST_UNCHECKED TRB_FORM_SEED_HIGHEST_BUFFER TRB_FORM_SEED_NO_OUT_FILL TRB_FORM_SEED_TAG_AT_FIRST
             TRB_FORM_SEED_NO_REQUEST_CHECK TRB_FORM_SEED_OTHER_POOL TRB_FORM_SEED_ANY_ENDPOINT
             TRB_FORM_SEED_DEQUEUE_STALE DMA_SEED_NO_RING_BOUND DMA_SEED_CYCLE_INVERTED
             DMA_SEED_PLACE_ONE_OFF TRB_FORM_SEED_ANY_TRANSFER TRB_FORM_SEED_HALT_HEAD_OF_NEWEST
             DMA_SEED_NO_REACH_TEST DMA_SEED_NO_CLOSURE DMA_SEED_RETIRE_NOTHING DMA_SEED_DROP_HALTED
             TRB_FORM_SEED_ANY_STOP DMA_SEED_TWO_COMMANDS DMA_SEED_FAILED_ADDRESS_UNBINDS
             DMA_SEED_POST_ON_STOPPED TRB_FORM_SEED_ANSWER_HALTED TRB_FORM_SEED_CONFIGURE_SPEED_ZEROED
             DMA_SEED_NO_REACH_HOLDS TRB_FORM_SEED_CONFIGURE_UNADDRESSED DMA_SEED_STOP_ANY_STATE
             DMA_SEED_RESET_ANY_STATE DMA_SEED_RESTART_ANY_STATE TRB_FORM_SEED_ADDRESS_UNENABLED
             TRB_FORM_SEED_RESET_RUNNING TRB_FORM_SEED_INSTALL_NOT_READY TRB_FORM_SEED_STARTED_HALTED
             TRB_FORM_SEED_BEGIN_RESUMES TRB_FORM_SEED_BEGIN_WRITES_RESETTING
             TRB_FORM_SEED_INSTALL_UNMASTERED].freeze

  def test_layout_endpoints_posts_and_releases
    output, status = run_harness
    assert status.success?, output
    assert_match(/^#{DONE} /, output)
  end

  SEEDS.each do |seed|
    define_method("test_seed_#{seed.downcase}") do
      output, status = run_harness("-DERX_#{seed}")
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
