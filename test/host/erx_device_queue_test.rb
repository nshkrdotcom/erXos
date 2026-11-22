# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../../tools/lib/erx/device_nif'
require_relative '../fixtures/generated_tree'

# The effects that put a device's queues on a virtio-mmio device the harness plays
# (test/fixtures/erx_device_dma_harness.c) and on GENET's register ring
# (test/fixtures/erx_device_genet_harness.c), clean under the address and undefined sanitizers.
class ErxDeviceQueueTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  # erx_device.c's cores from their one list (tools/lib/erx/device_nif.rb), over a host DMA
  # architecture layer that counts its maintenance.
  DEVICE = File.join(NIFS, 'erx_device.c')
  CORES = Erx::DeviceNif.core_sources(root: ROOT).map { |path| File.join(ROOT, path) }.freeze
  COUNTING = File.join(ROOT, 'test/fixtures/erx_dma_arch_counting.c')
  FLAGS = ['-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  def test_queues_on_a_device
    output = run_harness(File.join(ROOT, 'test/fixtures/erx_device_dma_harness.c'), *device_sources,
                         includes: [File.join(ROOT, 'test/fixtures/device_model')])
    assert_match(/^erx_device_dma done$/, output)
  end

  # The TRB ring form on an xHCI controller the harness plays: the record its first negotiation
  # makes, the reset and start one step a call, the install's registers from the table's fields.
  def test_the_trb_ring_on_an_xhci_controller
    assert_match(/^erx_device_xhci done$/, xhci_output)
  end

  # A PCIe function's MSI-X table, a run of its own: the call that ends the reset writes it and
  # answers reset before the install, and an open refuses a table that is misaligned, too long,
  # past the window or over the controller's registers.
  def test_the_msix_table_on_an_xhci_controller
    assert_match(/^erx_device_xhci msix done$/, xhci_output(args: ['msix']))
  end

  # The open that does not keep the controller's registers off the MSI-X table fails the MSI-X run.
  def test_an_msix_table_over_the_registers_fails_the_harness
    xhci_output(['msix->offset, table_end - msix->offset,', 'msix->offset, 0,'], args: ['msix'])
  end

  # The install writing IMAN with its pending bit as read, which clears an interrupt the reset
  # left pending, fails the xHCI harness.
  def test_a_register_word_keeping_a_one_to_clear_bit_fails_the_harness
    xhci_output(["out->word = r.reg->preserve == 0 ? 0 : load(device, r.reg, r.offset) & r.reg->preserve;",
                 "out->word = load(device, r.reg, r.offset);"])
  end

  # The seeds of the TRB form's posts and completions, each of which fails the xHCI harness: the
  # doorbell rung before the activation, so a controller fetching on the doorbell finds the TRB not
  # yet its own; a transfer's doorbell on slot 0's, the command ring's; ERDP written with its busy
  # bit 0, which leaves the interrupter's handler busy; ERDP skipped after a completion that broke
  # the form; and a broken form's post let through to the core, which does not judge breakage.
  XHCI_SEEDS = {
    doorbell_first: ["\tapply_activation(record, &ring_sequence.activation);\n" \
                     "\tstore(record->device, doorbell.r.reg, doorbell.r.offset, doorbell.word);\n",
                     "\tstore(record->device, doorbell.r.reg, doorbell.r.offset, doorbell.word);\n" \
                     "\tapply_activation(record, &ring_sequence.activation);\n"],
    doorbell_slot: ['if (!doorbell_word(record, slot, dci, &doorbell))', 'if (!doorbell_word(record, 0, dci, &doorbell))'],
    busy_bit_kept: ['!with_field(regs->ehb, 1, &words[0].word)', '!with_field(regs->ehb, 0, &words[0].word)'],
    dequeue_only_whole: ["\tif (trb_ring_dequeue(record, dequeue) != ERX_OK)\n\t\treturn (ERX_EINVAL);\n" \
                         "\tif (status != ERX_OK)\n\t\treturn (status);\n",
                         "\tif (status != ERX_OK)\n\t\treturn (status);\n" \
                         "\tif (trb_ring_dequeue(record, dequeue) != ERX_OK)\n\t\treturn (ERX_EINVAL);\n"],
    broken_posts: ['if (!record->ready || erx_trb_form_broken(&record->trb.form))', 'if (!record->ready)']
  }.freeze

  XHCI_SEEDS.each do |name, seed|
    define_method(:"test_a_trb_ring_seeded_with_#{name}_fails_the_harness") { xhci_output(seed) }
  end

  def test_the_register_ring_on_a_device
    assert_match(/^erx_device_genet done$/, genet_output)
  end

  # The seeds of the register ring's effect layer, each of which fails the GENET harness: the
  # idle test reading only the receive direction (docs/design-device-dma.md, Verification,
  # "GENET's stop"), so the receive ring is installed while the transmit engine runs; the
  # register lookup narrowed to owned registers, so the idle report of DMA status, which the
  # NIF does not own, reaches no register and the negotiation is refused; and the stop without
  # the install (erx_device_stop_dma) seeded to install and start the rings once both engines show
  # the stop, which the harness sees as a ring installed and an engine started after it.
  GENET_SEEDS = {
    idle_rx_only: ["\t\tidle = idle && shown == ERX_OK;\n",
                   "\t\tidle = side == 1 ? idle : shown == ERX_OK;\n"],
    owned_lookup: ["\t\tif (offset < reg->offset)\n\t\t\tcontinue;\n",
                   "\t\tif (offset < reg->offset || !reg->owned_by_nif)\n\t\t\tcontinue;\n"],
    stop_installs: ["\treturn (register_ring_stop(device, rings, status));\n",
                    "\treturn (register_ring_stop(device, rings, status) == ERX_OK ? " \
                    "register_ring_negotiate(device, &(uint64_t){ 0 }) : ERX_EBUSY);\n"]
  }.freeze

  GENET_SEEDS.each do |name, seed|
    define_method(:"test_a_register_ring_seeded_with_#{name}_fails_the_harness") do
      assert_match(/FAILED .*erx_device_genet_harness\.c/, genet_output(seed))
    end
  end

  # The seeded faults of docs/design-runtime.md, "Regions": a region that leaves its pages to
  # the next queue, so the two overlap; every device sharing the first device's region table, so a
  # post takes another device's region; and a region
  # made on a device that is not coherent. Each fails the regions scenario.
  REGION_SEEDS = {
    overlap: ["\tbzero(record->mapping, carve.length);\n\t*taken = carve.end;\n",
              "\tbzero(record->mapping, carve.length);\n"],
    foreign: ['return (&device_regions[device - devices]);', 'return (&device_regions[device - devices - (device - devices)]);'],
    coherent: ['device->form == ERX_DEVICE_FORM_PHYSICAL || !device->coherent)',
               'device->form == ERX_DEVICE_FORM_PHYSICAL)']
  }.freeze

  # One test for each seed above, named after it.
  REGION_SEEDS.each do |name, seed|
    define_method(:"test_a_region_seeded_with_#{name}_fails_the_harness") do
      output = seeded_dma_output(seed)
      assert_match(/FAILED .*erx_device_dma_harness\.c/, output)
      refute_match(/^regions ok$/, output)
    end
  end

  # The split ring's effect layer seeded to skip the invalidate of what the device wrote before
  # copying it out, so on a device that is not coherent the copy could read stale cache lines;
  # the counting layer's kept ranges show the completion maintained no such range.
  def test_a_completion_seeded_without_its_invalidate_fails_the_harness
    output = seeded_dma_output(["\t\tmaintained |= maintain(record, ring_answers[at].written, true);\n",
                                "\t\tmaintained |= false;\n"])
    assert_match(/FAILED .*erx_device_dma_harness\.c/, output)
    refute_match(/^non-coherent maintenance ok$/, output)
  end

  # The effect layer keeps each register ring's last accepted state as the next plan's `before`;
  # seeded to keep none, a later post or completion is refused by the check and the harness fails.
  def test_a_queue_that_keeps_no_state_fails_the_harness
    output = genet_output(["\tif (after != &record->state)\n\t\trecord->state = *after;\n", "\t(void)after;\n"])
    assert_match(/FAILED .*erx_device_genet_harness\.c/, output)
  end

  private

  GENET_HARNESS = File.join(ROOT, 'test/fixtures/erx_device_genet_harness.c')

  # The GENET harness's output over erx_device.c, with `seed` applied when one is given.
  def genet_output(seed = nil)
    Dir.mktmpdir('erx-device-genet-') do |directory|
      source = File.join(NIFS, 'erx_device.c')
      if seed
        text = File.read(source)
        assert_includes text, seed.first
        source = File.join(directory, 'erx_device.c')
        File.write(source, text.sub(*seed))
      end
      output, status = harness_output(GENET_HARNESS, *device_sources(source),
                                      includes: [File.join(ROOT, 'test/fixtures/device_model')])
      assert_equal seed.nil?, status.success?, output
      output
    end
  end

  XHCI_HARNESS = File.join(ROOT, 'test/fixtures/erx_device_xhci_harness.c')

  # The xHCI harness's output over erx_device.c, run with `args`, with `seed` applied, which must fail it.
  def xhci_output(seed = nil, args: [])
    Dir.mktmpdir('erx-device-xhci-') do |directory|
      source = File.join(NIFS, 'erx_device.c')
      if seed
        text = File.read(source)
        assert_includes text, seed.first
        source = File.join(directory, 'erx_device.c')
        File.write(source, text.sub(*seed))
      end
      output, status = harness_output(XHCI_HARNESS, *device_sources(source),
                                      includes: [File.join(ROOT, 'test/fixtures/device_model')], args: args)
      assert_equal seed.nil?, status.success?, output
      output
    end
  end

  # The DMA harness's output over erx_device.c with `seed` applied.
  def seeded_dma_output(seed)
    source = File.read(File.join(NIFS, 'erx_device.c'))
    assert_includes source, seed.first
    Dir.mktmpdir('erx-device-region-seed-') do |directory|
      seeded = File.join(directory, 'erx_device.c')
      File.write(seeded, source.sub(*seed))
      output, = harness_output(File.join(ROOT, 'test/fixtures/erx_device_dma_harness.c'), *device_sources(seeded),
                               includes: [File.join(ROOT, 'test/fixtures/device_model')])
      output
    end
  end

  # The cores with `device` in erx_device.c's place, and the counting architecture layer.
  def device_sources(device = DEVICE) = [*CORES.map { |path| path == DEVICE ? device : path }, COUNTING]

  def run_harness(*sources, includes: [])
    output, status = harness_output(*sources, includes: includes)
    assert status.success?, output
    output
  end

  # The harness built from `sources` and run, with its output and exit status. Directories in
  # includes come first, so the DMA harness's device model replaces the generated register
  # accesses. A build failure fails the test.
  def harness_output(*sources, includes: [], args: [])
    Dir.mktmpdir('erx-device-queue-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *includes.flat_map { |dir| ['-I', dir] },
                                       *Erx::Generated.include_flags(root: ROOT), '-I', ROOT,
                                       '-I', File.join(ROOT, 'include'), '-I', NIFS,
                                       *sources, '-o', binary, stdin_data: '')
      assert status.success?, output
      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, *args, stdin_data: '')
    end
  end
end
