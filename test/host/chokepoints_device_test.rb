# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'
require_relative '../../tools/lib/erx/hardware'

# The device group's own cases: a runtime reaches a register window only through
# erx_device's table-driven accesses, so the per-peripheral accessors tools/gen_hw.rb
# generates from the SVD files have no caller in the runtime.
class ChokepointsDeviceTest < Minitest::Test
  include ChokepointsHelper

  RUNTIME_FILE = 'otp/erts/emulator/beam/seeded.c'
  BYPASS = "#include <erx/hw/pl011.h>\nvoid f(erx_mmio_t d) { erx_pl011_dr_write(d, 65); }\n"

  def test_a_generated_peripheral_accessor_in_the_runtime_fails
    found = evaluate(Rules::ACTIVE, { RUNTIME_FILE => BYPASS })
    assert_equal %w[device-peripheral-accessors device-peripheral-headers], found.map(&:rule).uniq.sort
  end

  # The header probe names the reads and field getters of its three peripherals, their
  # value names and the console's data write, and nothing else: a write or a field setter
  # of any register, or another peripheral's header or accessor, fails there.
  def test_the_header_probe_writes_no_register_but_the_console
    rules = [rule('device-peripheral-accessors'), rule('device-peripheral-headers')]
    probe = 'test/raspi4b/header_probe.c'
    allowed = <<~C
      #include "erx/hw/bcm2711_gpio.h"
      #include "erx/hw/cprman.h"
      #include "erx/hw/mini_uart.h"
      x = erx_bcm2711_gpio_gplev0_read(g, &v) + erx_cprman_pwmctl_src_get(v) + ERX_CPRMAN_PWMCTL_SRC_GND;
      y = erx_mini_uart_lsr_tx_empty_get(v) + erx_mini_uart_io_write(c, 65);
    C
    assert_empty evaluate(rules, { probe => allowed })
    ['erx_bcm2711_gpio_gpfsel0_write(g, 0);', 'erx_cprman_pwmctl_src_set(v, 1, &v);', 'erx_mini_uart_lcr_write(c, 3);',
     '#include "erx/hw/pl011.h"', 'erx_pl011_dr_read(d, &v);'].each do |text|
      refute_empty evaluate(rules, { probe => "#{text}\n" }), text
    end
  end

  # A peripheral header is named by its path below include/, in any case, so a header of the
  # same file name elsewhere is not one.
  def test_only_the_generated_header_path_is_a_peripheral_include
    found = ->(text) { evaluate([rule('device-peripheral-headers')], { RUNTIME_FILE => text }) }
    refute_empty found.call("#include \"erx/hw/PL011.h\"\n")
    assert_empty found.call("#include <drivers/pl011.h>\n")
    assert_empty found.call("#include \"pl011.h\"\n")
  end

  # The checked names come from the generator, so a register or device added to an SVD file
  # is covered without an edit here, and the generated headers that define them pass.
  def test_every_generated_symbol_is_caught_outside_its_generated_header
    rules = [rule('device-peripheral-accessors'), rule('device-peripheral-headers')]
    plan = Erx::Hardware.output_plan(root: ROOT)
    Erx::Hardware.devices(root: ROOT).each do |device|
      header = Erx::Hardware.device_header_path(device)
      assert_empty evaluate(rules, { header => plan.fetch(header) })
      Erx::Hardware.generated_symbols(device).each do |symbol|
        refute_empty evaluate(rules, { RUNTIME_FILE => "long x = #{symbol};\n" }), symbol
      end
    end
  end

  # Every owned register's generated name is caught outside erx_device.c, so a new mark in an
  # SVD file is covered without an edit here, and the generated header that defines them passes.
  def test_an_owned_register_named_outside_erx_device_fails
    owned = [rule('device-owned-registers')]
    plan = Erx::Hardware.output_plan(root: ROOT)
    assert_empty evaluate(owned, { 'include/erx/hw/device_owned.h' => plan.fetch('include/erx/hw/device_owned.h') })
    symbols = Erx::Hardware.devices(root: ROOT).flat_map { |device| Erx::Hardware.owned_symbols(device) }
    assert_includes symbols, 'ERX_DEVICE_OWNED_VIRTIO_MMIO_STATUS'
    symbols.each do |symbol|
      refute_empty evaluate(owned, { 'otp/erts/emulator/nifs/erxos/erx_device_bif.c' => "x = #{symbol};\n" }), symbol
      assert_empty evaluate(owned, { 'otp/erts/emulator/nifs/erxos/erx_device.c' => "x = #{symbol};\n" }), symbol
    end
  end

  # Every maintenance and barrier function is caught outside the effect layer, the device
  # NIF's other files and the harnesses included; the architecture layer's definitions and the
  # queries pass.
  def test_dma_maintenance_outside_erx_device_fails
    maintenance = [rule('device-dma-maintenance')]
    calls = %w[erx_dma_clean erx_dma_clean_inval erx_dma_publish_barrier erx_dma_report_barrier
               erx_dma_completion_barrier erx_dma_store_wait]
    calls.each do |call|
      text = "void f(void) { #{call}(); }\n"
      assert_empty evaluate(maintenance, { 'otp/erts/emulator/nifs/erxos/erx_device.c' => text }), call
      assert_empty evaluate(maintenance, { 'otp/erts/emulator/nifs/erxos/arch/aarch64/erx_dma_arch.c' => text }), call
      refute_empty evaluate(maintenance, { 'otp/erts/emulator/nifs/erxos/erx_device_core.c' => text }), call
      refute_empty evaluate(maintenance, { 'test/fixtures/erx_device_harness.c' => text }), call
    end
    assert_empty evaluate(maintenance, { 'test/fixtures/erx_device_dma_harness.c' =>
                                           "unsigned g(void) { return erx_dma_granule() + erx_dma_line(); }\n" })
  end
end
