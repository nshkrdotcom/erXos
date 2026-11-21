# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'
require_relative '../../tools/lib/erx/board_tree'
require_relative '../../tools/fuzz/run_pack'

# erx-gate: sanitizers

# The device-tree reader, kernel/core/dt.c (docs/design-device-tree.md, "The
# reader" and "Verification"), over libfdt from fiasco/libfdt/lib/contrib with
# every check on, driven by test/fixtures/dt_driver.c. The platforms' trees are
# made as the build makes them: QEMU virt's dumped by QEMU, the Pi 4's card and
# model trees built by Erx::BoardTree. Fixture trees, compiled by dtc from the
# sources below, cover each status. Each seeded fault in MUTANTS must change
# the answer its fixture pins, or make the driver fail under the sanitizers.
class DtTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  READER = 'kernel/core/dt.c'
  # The reader's interrupt controller binding, the GIC's.
  BINDING = 'kernel/arch/aarch64/dt_interrupt.c'
  DRIVER = 'test/fixtures/dt_driver.c'
  LIBFDT = 'fiasco/libfdt/lib/contrib'
  # The fuzz target's sources and macros, so this harness links what it links.
  TARGET = Erx::PackFuzz.targets.find { |target| target.kind == 'dt' }
  IDENTITY = 'range 0x0 0x0 0xffffffffffffffff'
  # The most bytes of one seed the reader gives (include/erx/core/dt.h).
  SEED_MAX = Integer(File.read(File.join(ROOT, 'include/erx/core/dt.h'))[/ERX_DT_SEED_MAX\s+(\d+)/, 1])
  SEED_32 = (1..32).map { |i| format('%02x', i * 7) }.join(' ')

  # A fixture tree: the root's cells (two address, one size), one GiB of RAM at
  # 0, and body inside the root.
  def self.tree(body, memory: 'memory@0 { device_type = "memory"; reg = <0x0 0x0 0x40000000>; };')
    "/dts-v1/;\n/ {\n#address-cells = <2>;\n#size-cells = <1>;\n#{memory}\n#{body}\n};\n"
  end

  # A chain of count nested nodes, each named nN.
  def self.nested(count) = (1..count).map { |n| "n#{n} {" }.join + ('};' * count)

  # Entries of a dma-ranges, one cell each for a one-cell bus over a two-cell parent.
  def self.split_ranges(count, child_step:, parent_step:, size:)
    (0...count).map { |i| format('0x%x 0x0 0x%x 0x%x', i * child_step, i * parent_step, size) }.join(' ')
  end

  FRAMEBUFFER = lambda do |reg: '0x0 0x7e000000 0x400000', format: '"x8r8g8b8"', stride: 7680, extra: '', status: ''|
    "framebuffer@0 { compatible = \"simple-framebuffer\"; reg = <#{reg}>; width = <1920>; height = <480>; " \
      "stride = <#{stride}>; format = #{format}; #{status} #{extra} };"
  end

  # The RNG200 node of the Pi 4 trees (rng@7e104000), at reg.
  RNG_COMPATIBLE = 'brcm,bcm2711-rng200'
  RNG = lambda do |reg: '0x7e104000 0x28', status: nil|
    "rng@7e104000 { compatible = \"#{RNG_COMPATIBLE}\"; reg = <#{reg}>; #{status && "status = \"#{status}\";"} };"
  end

  # A one-cell bus; ranges nil is an empty ranges, :none no property.
  SOC = lambda do |ranges:, body:|
    property = { nil => 'ranges;', none: '' }.fetch(ranges) { "ranges = <#{ranges}>;" }
    "soc { #address-cells = <1>; #size-cells = <1>; #{property} #{body} };"
  end

  # A PCI host bridge at /pcie whose interrupt-map, entries (nil for none), routes to the
  # interrupt controller at the label gic, a GIC-400, under the mask (nil for none); bridge
  # and gic are their cells.
  INTX = lambda do |entries:, mask: '0x0 0x0 0x0 0x7', bridge: '#address-cells = <3>; #interrupt-cells = <1>;',
                    gic: '#address-cells = <0>; #interrupt-cells = <3>; interrupt-controller;'|
    map = entries && "#{mask && "interrupt-map-mask = <#{mask}>;"} interrupt-map = <#{entries}>;"
    "gic: intc { compatible = \"arm,gic-400\"; #{gic} }; pcie { device_type = \"pci\"; #{bridge} #size-cells = <2>; #{map} };"
  end
  # A PCI host bridge at /pcie with the given ranges entries (nil for none, '' for an empty
  # ranges) and bus-range cells (nil for none), its windows in the root's two address cells.
  BRIDGE = lambda do |ranges:, buses: nil, cells: '#address-cells = <3>; #size-cells = <2>;'|
    property = { nil => '', '' => 'ranges;' }.fetch(ranges) { "ranges = <#{ranges}>;" }
    "pcie { device_type = \"pci\"; #{cells} #{buses && "bus-range = <#{buses}>;"} #{property} };"
  end
  # QEMU virt's windows above the fixtures' RAM: I/O, 32-bit memory, and 64-bit prefetchable memory.
  VIRT_RANGES = '0x1000000 0x0 0x0 0x0 0x3eff0000 0x0 0x10000 0x2000000 0x0 0x40000000 0x0 0x40000000 0x0 0x2eff0000 ' \
                '0x43000000 0x80 0x0 0x80 0x0 0x80 0x0'
  # One 64 MiB window of 32-bit memory at PCI address 0xf8000000, CPU address parent.
  def self.window(parent, space: '0x2000000') = "#{space} 0x0 0xf8000000 #{parent} 0x0 0x4000000"
  # The Pi 4's bridge under a two-cell bus whose ranges, entries, map its addresses to the CPU's.
  def self.bridge_below(entries) = "scb { #address-cells = <2>; #size-cells = <1>; ranges = <#{entries}>; " \
                                   "#{BRIDGE.call(ranges: window('0x6 0x0'))} };"
  # The Pi 4's bridge with the dma-ranges entries bridge_dma (pcie_windows_max at most), under
  # a two-cell bus whose own dma-ranges, scb_dma (nil for none), maps its addresses to the CPU's.
  def self.inbound_below(bridge_dma, scb_dma: nil) =
    "scb { #address-cells = <2>; #size-cells = <1>; ranges = <0x6 0x0 0x0 0x80000000 0x10000000>; " \
    "#{scb_dma && "dma-ranges = <#{scb_dma}>;"} pcie { device_type = \"pci\"; #address-cells = <3>; " \
    "#size-cells = <2>; ranges = <#{window('0x6 0x0')}>; dma-ranges = <#{bridge_dma}>; }; };"
  # The Pi 4's one inbound entry: PCI 0 at the parent's 0, 3 GiB of 32-bit memory.
  PI_INBOUND = '0x2000000 0x0 0x0 0x0 0x0 0x0 0xc0000000'
  # Device 0's INTA to INTD on SPIs 143 to 146, level-triggered and active high.
  PIN_ENTRIES = (1..4).map { |pin| format('0x0 0x0 0x0 0x%x &gic 0x0 0x%x 0x4', pin, 142 + pin) }.join(' ')
  # The Pi 4's closed bus's one place, bus 1, device 0, function 0 (docs/design-usb.md,
  # "Interrupts"), with a pin appended.
  PI_PLACE = '1 0 0'

  FIXTURES = {
    'parent-coherent' => tree('bus { #address-cells = <2>; #size-cells = <1>; dma-coherent; dev { }; };'),
    'both-marks' => tree('dev { dma-coherent; dma-noncoherent; };'),
    'mark-with-value' => tree('dev { dma-coherent = <0>; };'),
    'own-mark' => tree('dev { dma-coherent; }; plain { };'),
    'gap-below-ranges' => tree('outer { #address-cells = <2>; #size-cells = <1>; dma-ranges = <0x0 0x0 0x0 0x0 0x40000000>; ' \
                               'gap { #address-cells = <2>; #size-cells = <1>; dev { }; }; };'),
    'two-memories' => tree('dev { };', memory: 'memory@0 { device_type = "memory"; reg = <0x0 0x0 0x1000000 0x1 0x0 0x1000000>; };'),
    # A host bridge's three-cell dma-ranges, with a device below it whose bus is the bridge.
    'pci-three-cells' => tree('pcie { device_type = "pci"; #address-cells = <3>; #size-cells = <2>; ' \
                              'dma-ranges = <0x2000000 0x0 0x0 0x0 0x0 0x0 0x40000000>; dev { }; };'),
    # A memory entry and a non-relocatable I/O entry (space code 1 under the n bit), both over RAM.
    'pci-memory-and-io' => tree('pcie { device_type = "pci"; #address-cells = <3>; #size-cells = <2>; ' \
                                'dma-ranges = <0x81000000 0x0 0x0 0x0 0x0 0x0 0x10000 0x2000000 0x0 0x0 0x0 0x0 0x0 0x40000000>; };'),
    # Three cells on a bus above a host bridge whose empty dma-ranges passes the windows up.
    'pci-three-cells-above' => tree('outer { #address-cells = <3>; #size-cells = <2>; ' \
                                    'dma-ranges = <0x2000000 0x0 0x0 0x0 0x0 0x0 0x40000000>; ' \
                                    'pcie { #address-cells = <2>; #size-cells = <1>; dma-ranges; }; };'),
    # Two windows over RAM, bus 0 and bus 0x80000000; a function that reaches below
    # 0x80000000 sees only the first.
    'pci-two-windows' => tree('pcie { device_type = "pci"; #address-cells = <3>; #size-cells = <2>; ' \
                              'dma-ranges = <0x2000000 0x0 0x0 0x0 0x0 0x0 0x20000000 ' \
                              '0x2000000 0x0 0x80000000 0x0 0x20000000 0x0 0x20000000>; };'),
    'pcie-two-cells' => tree('pcie { #address-cells = <2>; #size-cells = <1>; dma-ranges = <0x0 0x80000000 0x0 0x0 0x40000000>; };'),
    # A one-cell bus over the two-cell root, under a one-cell bus that offsets it.
    'nested' => tree('outer { #address-cells = <1>; #size-cells = <1>; dma-ranges = <0x10000000 0x0 0x0 0x40000000>; ' \
                     'inner { #address-cells = <1>; #size-cells = <1>; dma-ranges = <0x80000000 0x10000000 0x1000000>; ' \
                     'dev { }; }; };'),
    'over-no-ram' => tree('bus { #address-cells = <1>; #size-cells = <1>; dma-ranges = <0x0 0x2 0x0 0x1000000>; dev { }; };'),
    # 1,024 entries onto one parent range, under a level that splits it 1,024 ways.
    'splitting' => tree("outer { #address-cells = <1>; #size-cells = <1>; dma-ranges = <#{split_ranges(1024, child_step: 0x40, parent_step: 0x40, size: 0x40)}>; " \
                        'inner { #address-cells = <1>; #size-cells = <1>; ' \
                        "dma-ranges = <#{(0...1024).map { |i| format('0x%x 0x0 0x10000', i * 0x10000) }.join(' ')}>; dev { }; }; };"),
    'macs' => tree('local { local-mac-address = [02 11 22 33 44 55]; }; ' \
                   'placeholder { mac-address = [00 00 00 00 00 00]; local-mac-address = [02 aa bb cc dd ee]; }; ' \
                   'multicast { mac-address = [01 00 5e 00 00 01]; }; short { mac-address = [02 11 22 33 44]; };'),
    'deep-16' => tree(nested(16)),
    'deep-17' => tree(nested(17)),
    'memory-17' => tree('', memory: "memory@0 { device_type = \"memory\"; reg = <#{(1..17).map { |i| "0x#{i} 0x0 0x1000" }.join(' ')}>; };"),
    'memory-overflow' => tree('', memory: 'memory@0 { device_type = "memory"; reg = <0xffffffff 0xffffff00 0x1000>; };'),
    # QEMU virt's /chosen seeds: 32 bytes of rng-seed and a 64-bit kaslr-seed.
    'seed-32' => tree("chosen { rng-seed = [#{SEED_32}]; kaslr-seed = <0x01234567 0x89abcdef>; };"),
    # An rng-seed longer than the reader gives, whose bytes past ERX_DT_SEED_MAX differ.
    'seed-long' => tree("chosen { rng-seed = [#{Array.new(SEED_MAX + 8) { |i| format('%02x', (i % 255) + 1) }.join(' ')}]; };"),
    # An rng-seed whose only non-zero byte lies past the bytes the reader gives.
    'seed-zero-prefix' => tree("chosen { rng-seed = [#{(['00'] * SEED_MAX + ['01']).join(' ')}]; };"),
    # Seeds a kernel has used and zeroed.
    'seed-zero' => tree('chosen { rng-seed = [00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00]; kaslr-seed = <0x0 0x0>; };'),
    'fb-ok' => tree("chosen { #address-cells = <2>; #size-cells = <1>; #{FRAMEBUFFER.call} };"),
    'fb-crossing' => tree("chosen { #address-cells = <2>; #size-cells = <1>; #{FRAMEBUFFER.call(reg: '0x0 0x7e000000 0x3ff801')} };"),
    'fb-in-ram' => tree("chosen { #address-cells = <2>; #size-cells = <1>; #{FRAMEBUFFER.call(reg: '0x0 0x3ff00000 0x400000')} };"),
    'fb-none' => tree("chosen { #{FRAMEBUFFER.call(status: 'status = "disabled";')} };"),
    'fb-two' => tree("chosen { #address-cells = <2>; #size-cells = <1>; #{FRAMEBUFFER.call} " \
                     "#{FRAMEBUFFER.call.sub('framebuffer@0', 'framebuffer@1')} };"),
    'fb-region' => tree("chosen { #address-cells = <2>; #size-cells = <1>; #{FRAMEBUFFER.call(extra: 'memory-region = <1>;')} };"),
    'fb-format' => tree("chosen { #address-cells = <2>; #size-cells = <1>; #{FRAMEBUFFER.call(format: '"y8"')} };"),
    'fb-short-stride' => tree("chosen { #address-cells = <2>; #size-cells = <1>; #{FRAMEBUFFER.call(stride: 7679)} };"),
    'fb-no-stride' => tree("chosen { #address-cells = <2>; #size-cells = <1>; #{FRAMEBUFFER.call.sub('stride = <7680>; ', '')} };"),
    'fb-no-reg' => tree("chosen { #address-cells = <2>; #size-cells = <1>; #{FRAMEBUFFER.call.sub(/reg = <[^>]*>; /, '')} };"),
    # A reg one cell short of #address-cells plus #size-cells, whose size read on past the
    # property would be above 4 GiB, so only the length test refuses it.
    'fb-short-reg' => tree("chosen { #address-cells = <2>; #size-cells = <2>; #{FRAMEBUFFER.call(reg: '0x0 0x7e000000 0x1')} };"),
    # Register windows (erx_dt_registers): a node under the root, and under the Pi 4's
    # soc bus, which maps bus 0x7e000000 to CPU 0xfe000000.
    'regs-identity' => tree(RNG.call(reg: '0x0 0xfe104000 0x28')),
    'regs-translated' => tree(SOC.call(ranges: '0x7e000000 0x0 0xfe000000 0x1800000', body: RNG.call)),
    'regs-empty-ranges' => tree(SOC.call(ranges: nil, body: RNG.call(reg: '0xfe104000 0x28'))),
    'regs-no-ranges' => tree(SOC.call(ranges: :none, body: RNG.call)),
    # The window lies across two entries of the bus's ranges, or past the one entry's end or start.
    'regs-split' => tree(SOC.call(ranges: '0x7e104000 0x0 0xfe104000 0x10 0x7e104010 0x0 0xfe104010 0x18', body: RNG.call)),
    'regs-partial' => tree(SOC.call(ranges: '0x7e104000 0x0 0xfe104000 0x10', body: RNG.call)),
    'regs-tail' => tree(SOC.call(ranges: '0x7e104010 0x0 0xfe104010 0x18', body: RNG.call)),
    # Two entries that each map the whole window.
    'regs-twice' => tree(SOC.call(ranges: '0x7e000000 0x0 0xfe000000 0x1800000 0x7e000000 0x0 0xfe000000 0x1800000', body: RNG.call)),
    'regs-in-ram' => tree(SOC.call(ranges: '0x7e000000 0x0 0x0 0x1800000', body: RNG.call)),
    'regs-disabled' => tree(RNG.call(reg: '0x0 0xfe104000 0x28', status: 'disabled')),
    'regs-other-compatible' => tree(RNG.call(reg: '0x0 0xfe104000 0x28').sub(RNG_COMPATIBLE, 'brcm,bcm2835-rng')),
    'regs-empty' => tree(RNG.call(reg: '0x0 0xfe104000 0x0')),
    'regs-short' => tree(RNG.call(reg: '0x0 0xfe104000')),
    # A tree that names another device's page, the GPIO controller's, under the RNG200's
    # compatible string: at the row's path, and at a path of its own.
    'regs-other-page' => tree(SOC.call(ranges: '0x7e000000 0x0 0xfe000000 0x1800000', body: RNG.call(reg: '0x7e200000 0x28'))),
    'regs-elsewhere' => tree(SOC.call(ranges: '0x7e000000 0x0 0xfe000000 0x1800000',
                                      body: RNG.call(reg: '0x7e200000 0x28').sub('rng@7e104000', 'rng@7e200000'))),
    # A map that keeps only the pin and routes INTA to INTD to SPIs 143 to 146, as the Pi 4's does.
    'intx-pins' => tree(INTX.call(entries: PIN_ENTRIES)),
    # A map that keeps the device and the pin, with entries for device 0 only.
    'intx-by-device' => tree(INTX.call(mask: '0xf800 0x0 0x0 0x7', entries: PIN_ENTRIES)),
    'intx-no-map' => tree(INTX.call(entries: nil)),
    'intx-edge' => tree(INTX.call(entries: '0x0 0x0 0x0 0x1 &gic 0x0 0x8f 0x1')),
    'intx-ppi' => tree(INTX.call(entries: '0x0 0x0 0x0 0x1 &gic 0x1 0x9 0x4')),
    'intx-past-last-spi' => tree(INTX.call(entries: '0x0 0x0 0x0 0x1 &gic 0x0 0x3dc 0x4')),
    'intx-short-entry' => tree(INTX.call(entries: '0x0 0x0 0x0 0x1 &gic 0x0 0x8f')),
    'intx-short-mask' => tree(INTX.call(mask: '0x0 0x0 0x7', entries: PIN_ENTRIES)),
    'intx-two-cell-bridge' => tree(INTX.call(bridge: '#address-cells = <2>; #interrupt-cells = <1>;', entries: PIN_ENTRIES)),
    'intx-no-parent' => tree(INTX.call(entries: '0x0 0x0 0x0 0x1 0x99 0x0 0x8f 0x4')),
    'intx-no-mask' => tree(INTX.call(mask: nil, entries: PIN_ENTRIES.gsub('0x0 0x0 0x0 0x', '0x10000 0x0 0x0 0x'))),
    'intx-wide-parent-address' => tree(INTX.call(gic: '#address-cells = <3>; #interrupt-cells = <3>; interrupt-controller;',
                                                 entries: '0x0 0x0 0x0 0x1 &gic 0x0 0x0 0x0 0x0 0x8f 0x4')),
    'intx-other-controller' => tree(INTX.call(entries: PIN_ENTRIES).sub('arm,gic-400', 'brcm,bcm2836-l1-intc')),
    'intx-nexus-parent' => tree(INTX.call(gic: '#address-cells = <0>; #interrupt-cells = <3>;', entries: PIN_ENTRIES)),
    # The parent's unit address takes one cell in each entry.
    'intx-parent-address' => tree(INTX.call(gic: '#address-cells = <1>; #interrupt-cells = <3>; interrupt-controller;',
                                            entries: '0x0 0x0 0x0 0x1 &gic 0x0 0x0 0x8f 0x4 0x0 0x0 0x0 0x2 &gic 0x0 0x0 0x90 0x4')),
    # The second entry names another controller.
    'intx-two-parents' => tree(INTX.call(entries: '0x0 0x0 0x0 0x1 &gic 0x0 0x8f 0x4 0x0 0x0 0x0 0x2 &other 0x0 0x90 0x4') +
                               'other: intc2 { compatible = "arm,gic-400"; #address-cells = <0>; #interrupt-cells = <3>; ' \
                               'interrupt-controller; };'),
    'bridge-virt' => tree(BRIDGE.call(ranges: VIRT_RANGES, buses: '0x0 0x1f')),
    'bridge-bare' => tree(BRIDGE.call(ranges: nil)),
    'bridge-empty-ranges' => tree(BRIDGE.call(ranges: '')),
    'bridge-partial-entry' => tree(BRIDGE.call(ranges: window('0x0 0x80000000').sub(/ 0x4000000\z/, ''))),
    'bridge-two-cells' => tree(BRIDGE.call(ranges: '0x0 0x80000000 0x0 0x80000000 0x0 0x1000000',
                                           cells: '#address-cells = <2>; #size-cells = <2>;')),
    'bridge-wide-sizes' => tree(BRIDGE.call(ranges: "#{window('0x0 0x80000000')} 0x0",
                                            cells: '#address-cells = <3>; #size-cells = <3>;')),
    'bridge-configuration' => tree(BRIDGE.call(ranges: window('0x0 0x80000000', space: '0x0'))),
    # A window whose CPU range runs past 2^64 - 1, and one whose PCI range does.
    'bridge-cpu-wrap' => tree(BRIDGE.call(ranges: '0x2000000 0x0 0x0 0xffffffff 0xfffff000 0x0 0x2000')),
    'bridge-pci-wrap' => tree(BRIDGE.call(ranges: '0x2000000 0xffffffff 0xfffff000 0x0 0x80000000 0x0 0x2000')),
    'bridge-in-ram' => tree(BRIDGE.call(ranges: window('0x0 0x3c000000'))),
    'bridge-five' => tree(BRIDGE.call(ranges: (1..5).map { |i| format('0x2000000 0x%x 0x0 0x%x 0x0 0x0 0x4000000', i, i) }.join(' '))),
    'bridge-translated' => tree(bridge_below('0x6 0x0 0x0 0x80000000 0x10000000')),
    'bridge-half-translated' => tree(bridge_below('0x6 0x0 0x0 0x80000000 0x1000000')),
    # Inbound windows: through a bus without dma-ranges, through one that moves them up 4 GiB,
    # through one that covers only 2 GiB of the 3, and two entries that meet in PCI space.
    'bridge-inbound' => tree(inbound_below(PI_INBOUND)),
    'bridge-inbound-moved' => tree(inbound_below(PI_INBOUND, scb_dma: '0x0 0x0 0x1 0x0 0xfc000000')),
    'bridge-inbound-split' => tree(inbound_below(PI_INBOUND, scb_dma: '0x0 0x0 0x0 0x0 0x80000000')),
    'bridge-inbound-overlap' => tree(inbound_below("#{PI_INBOUND} 0x2000000 0x0 0x80000000 0x1 0x0 0x0 0x1000000")),
    # A dma-ranges of I/O space alone maps no memory, which no inbound window would say.
    'bridge-inbound-io' => tree(inbound_below('0x1000000 0x0 0x0 0x0 0x0 0x0 0x10000')),
    # One size cell, a 32-bit prefetchable window and an entry of size 0.
    'bridge-one-size-cell' => tree(BRIDGE.call(ranges: '0x42000000 0x0 0xf8000000 0x0 0x80000000 0x4000000 ' \
                                                       '0x2000000 0x0 0x0 0x0 0x90000000 0x0',
                                               cells: '#address-cells = <3>; #size-cells = <1>;')),
    # Two windows of one PCI range, and two of one CPU range.
    'bridge-overlap-pci' => tree(BRIDGE.call(ranges: "#{window('0x6 0x0')} #{window('0x7 0x0')}")),
    'bridge-overlap-cpu' => tree(BRIDGE.call(ranges: "#{window('0x6 0x0')} #{window('0x6 0x0').sub('0x2000000 0x0', '0x2000000 0x1')}")),
    'bridge-bus-past' => tree(BRIDGE.call(ranges: nil, buses: '0x0 0x100')),
    'bridge-bus-reversed' => tree(BRIDGE.call(ranges: nil, buses: '0x2 0x1')),
    'bridge-bus-short' => tree(BRIDGE.call(ranges: nil, buses: '0x0'))
  }.freeze

  # The RNG200's row in the Pi 4's platform record: its path, compatible string and window;
  # and the same window at the root, for the fixtures with no soc bus.
  RNG_ROW = "/soc/rng@7e104000 #{RNG_COMPATIBLE} 0xfe104000 0x28"
  ROOT_RNG_ROW = "/rng@7e104000 #{RNG_COMPATIBLE} 0xfe104000 0x28"

  # The framebuffer row's window in the fixtures, above their RAM; one whose end is not
  # a page boundary; one over the RAM below.
  WINDOW = '0x7e000000 0x400000'
  CROSSING_WINDOW = '0x7e000000 0x3ff900'
  RAM_WINDOW = '0x3fe00000 0x800000'

  # name => [original, replacement, fixture, query, the line the unseeded reader gives, and
  # the source seeded when it is not the reader].
  MUTANTS = {
    'the all-zero test turned round' =>
      ["\t\tif (bytes[at] != 0)\n", "\t\tif (bytes[at] == 0)\n", 'seed-zero', 'seeds',
       'seeds rng-seed 0 - kaslr-seed 0 -'],
    'the zero test over the whole property' =>
      ['if (!any_set((const uint8_t *)value, length))', 'if (!any_set((const uint8_t *)value, (size_t)len))',
       'seed-zero-prefix', 'seeds', 'seeds rng-seed 0 - kaslr-seed 0 -'],
    'the header read before fdt_check_full' =>
      ['if (bytes == NULL || size < FDT_V17_SIZE || fdt_check_full(bytes, size) != 0)',
       'if (bytes == NULL || fdt_check_header(bytes) != 0 || fdt_check_full(bytes, size) != 0)', 'own-mark@8', nil,
       'accept structure memory 0'],
    'the depth bound removed' =>
      ['walk->depth < 0 || walk->depth > ERX_DT_DEPTH_MAX', 'walk->depth < 0', 'deep-17', nil, 'accept depth memory 0'],
    "a dma-ranges entry read with the parent's cell counts" =>
      ["ac = fdt_address_cells(tree->bytes, path[at]);\n\t\tsc = fdt_size_cells(tree->bytes, path[at]);",
       "ac = fdt_address_cells(tree->bytes, path[at - 1]);\n\t\tsc = fdt_size_cells(tree->bytes, path[at - 1]);",
       'nested', 'device /outer/inner/dev node', 'device ok coherent 0 range 0x0 0x80000000 0xffffff mac none'],
    'the marks above the node passed over' =>
      ['for (i = 0; i < depth; i++)', 'for (i = depth; i < depth; i++)', 'parent-coherent', 'device /bus/dev node',
       'device coherence coherent 0 range 0x0 0x0 0x0 mac none'],
    'the marks tested for presence only' =>
      ['if ((on != NULL && on_len != 0) || (off != NULL && off_len != 0))', 'if (false)', 'mark-with-value',
       'device /dev node', 'device malformed coherent 0 range 0x0 0x0 0x0 mac none'],
    'the level above the first non-empty one dropped' =>
      ['for (at = level; at >= 0; at--)', 'for (at = level; at >= level; at--)', 'nested',
       'device /outer/inner/dev node', 'device ok coherent 0 range 0x0 0x80000000 0xffffff mac none'],
    "the windows' bound removed" =>
      ["\t\t\tif (count == ERX_DT_WINDOWS_MAX)\n\t\t\t\treturn (ERX_DT_DMA_RANGES);\n", '', 'splitting',
       'device /outer/inner/dev node', 'device ranges coherent 0 range 0x0 0x0 0x0 mac none'],
    'the space-code mask dropped' =>
      ['>> PCI_SPACE_SHIFT & PCI_SPACE_MASK) == PCI_SPACE_IO)', '>> PCI_SPACE_SHIFT) == PCI_SPACE_IO)', 'pci-memory-and-io',
       'device /pcie pcie', 'device ok coherent 0 range 0x0 0x0 0x3fffffff mac none'],
    'an IO entry taken' =>
      ["\t\t\tif ((cells_read(at, 1) >> PCI_SPACE_SHIFT & PCI_SPACE_MASK) == PCI_SPACE_IO)\n\t\t\t\tcontinue;\n", '',
       'pci-memory-and-io', 'device /pcie pcie', 'device ok coherent 0 range 0x0 0x0 0x3fffffff mac none'],
    'three cells taken above the host bridge' =>
      ['three = pci && at == level && ac == PCI_ADDRESS_CELLS;', 'three = pci && ac == PCI_ADDRESS_CELLS;',
       'pci-three-cells-above', 'device /outer/pcie pcie', 'device cells coherent 0 range 0x0 0x0 0x0 mac none'],
    "the map's pin match dropped" =>
      ["for (i = 0; i < PCI_INTX_CELLS; i++)\n\t\tif (cells_read(entry", "for (i = 0; i < PCI_ADDRESS_CELLS; i++)\n\t\tif (cells_read(entry",
       'intx-pins', "intx /pcie #{PI_PLACE} 2", 'intx ok 176'],
    "the controller's compatible unchecked" =>
      ['if (!known || ', 'if (', 'intx-other-controller', "intx /pcie #{PI_PLACE} 1", 'intx unsupported 0'],
    'the level check removed' =>
      ['(cells[2] & GIC_TRIGGER_MASK) != GIC_LEVEL_HIGH)', 'false)', 'intx-edge', "intx /pcie #{PI_PLACE} 1",
       'intx unsupported 0', BINDING],
    'the RAM filter removed' =>
      ['if (memory_meets(tree, windows[i].at,', 'if (true || memory_meets(tree, windows[i].at,', 'over-no-ram',
       'device /bus/dev node', 'device ranges coherent 0 range 0x0 0x0 0x0 mac none'],
    'the group-bit test removed' =>
      ['(value[0] & 1) != 0)', 'false)', 'macs', 'device /multicast node', 'device ok coherent 0 range 0x0 0x0 0xffffffffffffffff mac none'],
    'the stride test removed' =>
      ['(uint64_t)width * (dt_formats[format].bits / 8) > stride || ', '', 'fb-short-stride',
       "fb /chosen simple-framebuffer #{WINDOW}", 'fb malformed 0x0 0x0 0x0 0 - 0'],
    "the reg's length test removed" =>
      ['if (reg == NULL || len != (ac + sc) * DT_CELL)', 'if (reg == NULL)', 'fb-short-reg',
       "fb /chosen simple-framebuffer #{WINDOW}", 'fb malformed 0x0 0x0 0x0 0 - 0'],
    "the framebuffer's RAM test removed" =>
      ['last_page > window_last || memory_meets(tree, first_page, last_page)', 'last_page > window_last', 'fb-in-ram',
       "fb /chosen simple-framebuffer #{RAM_WINDOW}", 'fb outside 0x3ff00000 0x400000 0x0 0 - 0'],
    'the window test made over the unrounded reg' =>
      ['first_page < window.base || last_page > window_last', 'base < window.base || last > window_last', 'fb-crossing',
       "fb /chosen simple-framebuffer #{CROSSING_WINDOW}", 'fb outside 0x7e000000 0x3ff801 0x0 0 - 0'],
    "the buses' ranges passed over" =>
      ['for (level = depth - 1; level > 0; level--)', 'for (level = depth - 1; level > depth - 1; level--)', 'regs-translated',
       "regs #{RNG_ROW}", 'regs ok'],
    'a bus with no ranges taken as the identity' =>
      ["if (ranges == NULL)\n\t\t\treturn (false);\n\t\tif (len == 0)", 'if (ranges == NULL || len == 0)', 'regs-no-ranges',
       "regs #{RNG_ROW}", 'regs malformed'],
    "the window's start left untested" =>
      ['count != 1 || pieces[0].bus != first ||', 'count != 1 ||', 'regs-tail', "regs #{RNG_ROW}", 'regs malformed'],
    'the window taken from the first of two pieces' =>
      ['count != 1 || pieces[0].bus != first ||', 'pieces[0].bus != first ||', 'regs-twice', "regs #{RNG_ROW}", 'regs malformed'],
    "the register window's RAM test removed" =>
      ['pieces[0].last != last || memory_meets(tree, pieces[0].at, window_at_last(&pieces[0])))', 'pieces[0].last != last)',
       'regs-in-ram', "regs #{RNG_ROW}", 'regs malformed'],
    "the row's base left unchecked" =>
      ['if (cpu != window.base || size != window.size)', 'if (size != window.size)', 'regs-other-page', "regs #{RNG_ROW}",
       'regs other'],
    'the wrap check on a window removed' =>
      ["__builtin_add_overflow(parent, size - 1, &parent_last))\n\t\t\treturn (ERX_DT_BRIDGE_MALFORMED);",
       "(parent_last = parent + (size - 1), false))\n\t\t\treturn (ERX_DT_BRIDGE_MALFORMED);",
       'bridge-cpu-wrap', 'bridge /pcie', 'bridge malformed buses 0 0'],
    "an inbound window's one-piece check removed" =>
      ["count != 1 ||\n\t    pieces[0].bus != first || pieces[0].last != last)", 'false)', 'bridge-inbound-split',
       'bridge /scb/pcie', 'bridge malformed buses 0 0'],
    'the bus-range bound removed' =>
      ['if (first > last || last > UINT8_MAX)', 'if (first > last)', 'bridge-bus-past', 'bridge /pcie',
       'bridge malformed buses 0 0'],
    "the DMA limit's cut removed" =>
      ['if (dma_limit != 0 && windows[i].last >= dma_limit)', 'if (false)', 'pci-three-cells',
       'device /pcie pcie 0x3c000000', 'device ok coherent 0 range 0x0 0x0 0x3bffffff mac none']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-dt-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  # The driver over the target's sources, each source in seeded (a tree path) replaced by
  # the file it maps to.
  def build(seeded: {}, name: 'driver', flags: @flags)
    output = File.join(@directory, name.tr(" '/", '---'))
    sources = TARGET.sources.map { |source| seeded.fetch(source) { File.join(ROOT, source) } }
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *Erx::PackFuzz.define_flags(TARGET), *flags, *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, LIBFDT), *sources,
                                  File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def driver = (@driver ||= build)

  # Compiles a fixture's source with dtc. NAME@N hands over only its first N bytes.
  def fixture(name)
    path = File.join(@directory, "#{name}.dtb")
    unless File.exist?(path)
      log, status = Open3.capture2e('dtc', '-q', '-I', 'dts', '-O', 'dtb', '-o', path, '-', stdin_data: FIXTURES.fetch(name))
      assert status.success?, "#{name}: #{log}"
    end
    path
  end

  # The driver's lines for a tree and queries, with the process status.
  def ask(tree, queries = [], program: driver, prefix: nil)
    output, status = Open3.capture2e(program, tree, *[prefix].compact.map(&:to_s), stdin_data: queries.map { |query| "#{query}\n" }.join)
    [output.lines.map(&:chomp), status]
  end

  def answers(tree, queries = [], prefix: nil)
    lines, status = ask(tree, queries, prefix: prefix)
    assert status.success?, lines.join("\n")
    lines
  end

  def fixture_answers(name, queries = [])
    tree_name, prefix = name.split('@')
    answers(fixture(tree_name), queries, prefix: prefix&.to_i)
  end

  def test_qemu_virt_tree
    tree = File.join(@directory, 'virt.dtb')
    log, status = Open3.capture2e('gtimeout', '-k', '10', '30', 'qemu-system-aarch64', '-machine', 'virt-11.1,gic-version=3,dumpdtb=' + tree,
                                  '-cpu', 'cortex-a72', '-m', '1024', '-display', 'none', '-serial', 'null', '-no-reboot', stdin_data: '')
    assert status.success?, log
    lines = answers(tree, ['device /virtio_mmio@a003e00 node', 'device /virtio_mmio@a002e00 node',
                           'device /pl011@9000000 node', 'device /pcie@10000000 pcie', 'device /nowhere node',
                           'bridge /pcie@10000000',
                           "fb /chosen simple-framebuffer #{WINDOW}", 'seeds'])
    assert_equal ['accept ok memory 1',
                  "device ok coherent 1 #{IDENTITY} mac none",
                  "device ok coherent 1 #{IDENTITY} mac none",
                  # QEMU marks the root dma-coherent; the UART carries no mark of its own.
                  'device coherence coherent 0 range 0x0 0x0 0x0 mac none',
                  "device ok coherent 1 #{IDENTITY} mac none",
                  'device no_node coherent 0 range 0x0 0x0 0x0 mac none',
                  # Its 32-bit and 64-bit windows above RAM, the 64 KiB of I/O space skipped.
                  'bridge ok buses 0 255 window 0x10000000 0x10000000 0x2eff0000 0 ' \
                  'window 0x8000000000 0x8000000000 0x8000000000 1',
                  'fb none 0x0 0x0 0x0 0 - 0'], lines[0..-2]
    # QEMU virt's seeds are random, so only their lengths are known.
    assert_match(/\Aseeds rng-seed 32 \h{64} kaslr-seed 8 \h{16}\z/, lines.last)
  end

  def test_raspberry_pi_4_trees
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    platform = Erx::Platform.load(root: ROOT, name: 'raspi4b')
    built = Erx::BoardTree.build(root: ROOT, runner: runner, platform: platform,
                                 compiler: ENV.fetch('ERX_CLANG', 'clang'), revision: nil)
    queries = ['device /emmc2bus/mmc@7e340000 node', 'device /scb/ethernet@7d580000 node', 'device /scb/pcie@7d500000 pcie',
               'device /scb/pcie@7d500000 pcie 0x3c000000', 'bridge /scb/pcie@7d500000']
    # The bridge's one 64 MiB window, PCI 0xf8000000 at CPU 0x600000000, its one inbound window,
    # PCI 0 at CPU 0 for 3 GiB, and buses 0 to 255, the tree having no bus-range (bcm2711.dtsi,
    # pcie@7d500000).
    bridge = 'bridge ok buses 0 255 window 0xf8000000 0x600000000 0x4000000 0 inbound 0x0 0x0 0xc0000000 0'
    # The model's tree has the memory node the firmware fills. The PCIe bridge's one dma-ranges
    # entry maps PCI address 0 to physical 0 for 3 GiB (docs/design-device-tree.md, "The reader").
    assert_equal ['accept ok memory 1',
                  'device ok coherent 0 range 0x0 0xc0000000 0x3fffffff mac none',
                  "device ok coherent 0 #{IDENTITY} mac none",
                  'device ok coherent 0 range 0x0 0x0 0xbfffffff mac none',
                  'device ok coherent 0 range 0x0 0x0 0x3bffffff mac none', bridge], answers(built.model, queries)
    # The card's tree leaves the memory node as zeros, so no window has RAM behind it.
    assert_equal ['accept ok memory 0',
                  'device ranges coherent 0 range 0x0 0x0 0x0 mac none',
                  'device ranges coherent 0 range 0x0 0x0 0x0 mac none',
                  'device ranges coherent 0 range 0x0 0x0 0x0 mac none',
                  'device ranges coherent 0 range 0x0 0x0 0x0 mac none', bridge], answers(built.board, queries)
    # The card's tree places the RNG200 where its row in the platform record says, 0x7e104000
    # on the soc bus, CPU address 0xfe104000; the model's tree disables it, since QEMU's model
    # does not answer there (Erx::BoardTree).
    row = platform.record.fetch('units').flat_map { |unit| unit.fetch('devices') }
                  .find { |device| device.fetch('compatible') == RNG_COMPATIBLE }
    query = "regs #{row.values_at('path', 'compatible', 'base', 'size').join(' ')}"
    assert_equal 'regs ok', answers(built.board, [query])[1]
    assert_equal 'regs none', answers(built.model, [query])[1]
    # Both trees route the closed bus's INTA to INTD to SPIs 143 to 146, interrupt ids 175
    # to 178 (docs/design-pcie.md, "The closed bus").
    intx = (1..4).map { |pin| "intx /scb/pcie@7d500000 #{PI_PLACE} #{pin}" }
    expected = (175..178).map { |line| "intx ok #{line}" }
    assert_equal expected, answers(built.board, intx)[1..]
    assert_equal expected, answers(built.model, intx)[1..]
  end

  def test_coherence_marks
    assert_equal 'device coherence coherent 0 range 0x0 0x0 0x0 mac none', fixture_answers('parent-coherent', ['device /bus/dev node'])[1]
    assert_equal 'device coherence coherent 0 range 0x0 0x0 0x0 mac none', fixture_answers('both-marks', ['device /dev node'])[1]
    assert_equal 'device malformed coherent 0 range 0x0 0x0 0x0 mac none', fixture_answers('mark-with-value', ['device /dev node'])[1]
    assert_equal ["device ok coherent 1 #{IDENTITY} mac none", "device ok coherent 0 #{IDENTITY} mac none"],
                 fixture_answers('own-mark', ['device /dev node', 'device /plain node'])[1..]
  end

  def test_dma_walk
    {
      ['gap-below-ranges', 'device /outer/gap/dev node'] => 'device malformed coherent 0 range 0x0 0x0 0x0 mac none',
      ['two-memories', 'device /dev node'] => "device ok coherent 0 #{IDENTITY} mac none",
      ['pci-three-cells', 'device /pcie pcie'] => 'device ok coherent 0 range 0x0 0x0 0x3fffffff mac none',
      ['pci-three-cells', 'device /pcie/dev node'] => 'device cells coherent 0 range 0x0 0x0 0x0 mac none',
      ['pci-memory-and-io', 'device /pcie pcie'] => 'device ok coherent 0 range 0x0 0x0 0x3fffffff mac none',
      ['pci-three-cells-above', 'device /outer/pcie pcie'] => 'device cells coherent 0 range 0x0 0x0 0x0 mac none',
      ['pcie-two-cells', 'device /pcie pcie'] => 'device ok coherent 0 range 0x0 0x80000000 0x3fffffff mac none',
      # A function's DMA limit, a device address, cuts its range, keeping the bridge's offset;
      # a limit at or below every device address leaves no range; one above it, the range whole.
      ['pci-three-cells', 'device /pcie pcie 0x3c000000'] => 'device ok coherent 0 range 0x0 0x0 0x3bffffff mac none',
      ['pci-three-cells', 'device /pcie pcie 0x100000000'] => 'device ok coherent 0 range 0x0 0x0 0x3fffffff mac none',
      ['pcie-two-cells', 'device /pcie pcie 0x90000000'] => 'device ok coherent 0 range 0x0 0x80000000 0xfffffff mac none',
      ['pcie-two-cells', 'device /pcie pcie 0x80000000'] => 'device ranges coherent 0 range 0x0 0x0 0x0 mac none',
      # A window the function cannot reach makes no range ambiguous.
      ['pci-two-windows', 'device /pcie pcie'] => 'device ranges coherent 0 range 0x0 0x0 0x0 mac none',
      ['pci-two-windows', 'device /pcie pcie 0x80000000'] => 'device ok coherent 0 range 0x0 0x0 0x1fffffff mac none',
      ['nested', 'device /outer/inner/dev node'] => 'device ok coherent 0 range 0x0 0x80000000 0xffffff mac none',
      ['over-no-ram', 'device /bus/dev node'] => 'device ranges coherent 0 range 0x0 0x0 0x0 mac none',
      ['splitting', 'device /outer/inner/dev node'] => 'device ranges coherent 0 range 0x0 0x0 0x0 mac none',
      ['own-mark', 'device / node'] => 'device malformed coherent 0 range 0x0 0x0 0x0 mac none',
      ['own-mark', 'device dev node'] => 'device no_node coherent 0 range 0x0 0x0 0x0 mac none'
    }.each { |(name, query), expected| assert_equal expected, fixture_answers(name, [query])[1], name }
  end

  def test_hardware_address
    lines = fixture_answers('macs', %w[local placeholder multicast short].map { |node| "device /#{node} node" })
    assert_equal %w[02:11:22:33:44:55 02:aa:bb:cc:dd:ee none none], lines[1..].map { |line| line.split.last }
  end

  def test_acceptance_refusals
    assert_equal 'accept ok memory 1', fixture_answers('deep-16')[0]
    assert_equal 'accept depth memory 0', fixture_answers('deep-17')[0]
    assert_equal 'accept memory memory 0', fixture_answers('memory-17')[0]
    assert_equal 'accept memory memory 0', fixture_answers('memory-overflow')[0]
    size = File.size(fixture('own-mark'))
    [0, 4, 8, 39, 40, size - 1].each do |prefix|
      assert_equal 'accept structure memory 0', fixture_answers("own-mark@#{prefix}")[0], "prefix #{prefix}"
    end
    assert_equal 'device no_node coherent 0 range 0x0 0x0 0x0 mac none', fixture_answers('own-mark@40', ['device /dev node'])[1]
  end

  # A version 2 header is 32 bytes, yet libfdt's fdt_check_header reads the strings
  # block's size at offset 32 whatever the version (fdt.c:139-142), so a 32-byte tree
  # claiming version 2 read past its buffer under ASan until the reader refused any
  # buffer shorter than the version 17 header first.
  def test_a_short_old_header_is_refused_before_libfdt_reads_it
    bytes = File.binread(fixture('own-mark'))
    bytes[20, 8] = [2, 2].pack('N2')
    path = File.join(@directory, 'version-2.dtb')
    File.binwrite(path, bytes)
    lines, status = ask(path, [], program: build(name: 'asan', flags: %w[-fsanitize=address,undefined -fno-sanitize-recover=all]), prefix: 32)
    assert status.success?, lines.join("\n")
    assert_equal 'accept structure memory 0', lines.first
  end

  def test_seeds
    seed_32 = SEED_32.delete(' ')
    long = Array.new(SEED_MAX) { |i| format('%02x', (i % 255) + 1) }.join
    {
      'seed-32' => "seeds rng-seed 32 #{seed_32} kaslr-seed 8 0123456789abcdef",
      'seed-long' => "seeds rng-seed #{SEED_MAX} #{long} kaslr-seed 0 -",
      'seed-zero' => 'seeds rng-seed 0 - kaslr-seed 0 -',
      'seed-zero-prefix' => 'seeds rng-seed 0 - kaslr-seed 0 -',
      'own-mark' => 'seeds rng-seed 0 - kaslr-seed 0 -'
    }.each { |name, expected| assert_equal expected, fixture_answers(name, ['seeds'])[1], name }
  end

  def test_framebuffer
    query = ["fb /chosen simple-framebuffer #{WINDOW}"]
    {
      'fb-ok' => 'fb ok 0x7e000000 0x400000 1920x480 7680 x8r8g8b8 32',
      'fb-none' => 'fb none 0x0 0x0 0x0 0 - 0',
      'fb-two' => 'fb ambiguous 0x0 0x0 0x0 0 - 0',
      'fb-region' => 'fb unsupported 0x0 0x0 0x0 0 - 0',
      'fb-format' => 'fb malformed 0x0 0x0 0x0 0 - 0',
      'fb-short-stride' => 'fb malformed 0x0 0x0 0x0 0 - 0',
      'fb-no-stride' => 'fb malformed 0x0 0x0 0x0 0 - 0',
      'fb-no-reg' => 'fb malformed 0x0 0x0 0x0 0 - 0',
      'fb-short-reg' => 'fb malformed 0x0 0x0 0x0 0 - 0'
    }.each { |name, expected| assert_equal expected, fixture_answers(name, query)[1], name }
    assert_equal 'fb ok 0x7e000000 0x3ff801 1920x480 7680 x8r8g8b8 32', fixture_answers('fb-crossing', query)[1]
    assert_equal 'fb outside 0x7e000000 0x3ff801 0x0 0 - 0',
                 fixture_answers('fb-crossing', ["fb /chosen simple-framebuffer #{CROSSING_WINDOW}"])[1]
    assert_equal 'fb outside 0x3ff00000 0x400000 0x0 0 - 0', fixture_answers('fb-in-ram', ["fb /chosen simple-framebuffer #{RAM_WINDOW}"])[1]
    assert_equal 'fb outside 0x7e000000 0x400000 0x0 0 - 0', fixture_answers('fb-ok', ['fb /chosen simple-framebuffer 0x7e000000 0'])[1]
    assert_equal 'fb outside 0x7e000000 0x400000 0x0 0 - 0',
                 fixture_answers('fb-ok', ['fb /chosen simple-framebuffer 0x9000000 0x400000'])[1]
  end

  def test_register_windows
    {
      'regs-identity' => [ROOT_RNG_ROW, 'regs ok'],
      'regs-translated' => [RNG_ROW, 'regs ok'],
      'regs-empty-ranges' => [RNG_ROW, 'regs ok'],
      'regs-no-ranges' => [RNG_ROW, 'regs malformed'],
      'regs-split' => [RNG_ROW, 'regs malformed'],
      'regs-partial' => [RNG_ROW, 'regs malformed'],
      'regs-tail' => [RNG_ROW, 'regs malformed'],
      'regs-twice' => [RNG_ROW, 'regs malformed'],
      'regs-in-ram' => [RNG_ROW, 'regs malformed'],
      'regs-empty' => [ROOT_RNG_ROW, 'regs malformed'],
      'regs-short' => [ROOT_RNG_ROW, 'regs malformed'],
      'regs-disabled' => [ROOT_RNG_ROW, 'regs none'],
      'regs-other-compatible' => [ROOT_RNG_ROW, 'regs none'],
      'own-mark' => [ROOT_RNG_ROW, 'regs none']
    }.each { |name, (row, expected)| assert_equal expected, fixture_answers(name, ["regs #{row}"])[1], name }
    # A row whose window starts or ends elsewhere than the node's is not confirmed.
    assert_equal 'regs other', fixture_answers('regs-translated', ["regs /soc/rng@7e104000 #{RNG_COMPATIBLE} 0xfe105000 0x28"])[1]
    assert_equal 'regs other', fixture_answers('regs-translated', ["regs /soc/rng@7e104000 #{RNG_COMPATIBLE} 0xfe104000 0x1000"])[1]
  end

  # A closed bus's place takes the line its bridge's interrupt-map routes for its pin
  # (docs/design-device-tree.md, "A PCI host bridge").
  def test_intx_routes
    {
      ['intx-pins', "intx /pcie #{PI_PLACE} 1"] => 'intx ok 175',
      ['intx-pins', "intx /pcie #{PI_PLACE} 2"] => 'intx ok 176',
      ['intx-pins', "intx /pcie #{PI_PLACE} 4"] => 'intx ok 178',
      ['intx-pins', 'intx /nowhere 1 0 0 1'] => 'intx no_node 0',
      ['intx-by-device', 'intx /pcie 1 0 3 2'] => 'intx ok 176',
      ['intx-by-device', 'intx /pcie 1 1 0 2'] => 'intx none 0',
      ['intx-no-map', "intx /pcie #{PI_PLACE} 1"] => 'intx none 0',
      ['intx-edge', "intx /pcie #{PI_PLACE} 1"] => 'intx unsupported 0',
      ['intx-ppi', "intx /pcie #{PI_PLACE} 1"] => 'intx unsupported 0',
      ['intx-past-last-spi', "intx /pcie #{PI_PLACE} 1"] => 'intx malformed 0',
      ['intx-short-entry', "intx /pcie #{PI_PLACE} 1"] => 'intx malformed 0',
      ['intx-short-mask', "intx /pcie #{PI_PLACE} 1"] => 'intx malformed 0',
      ['intx-two-cell-bridge', "intx /pcie #{PI_PLACE} 1"] => 'intx malformed 0',
      ['intx-no-parent', "intx /pcie #{PI_PLACE} 1"] => 'intx malformed 0',
      ['intx-nexus-parent', "intx /pcie #{PI_PLACE} 1"] => 'intx unsupported 0',
      ['intx-parent-address', "intx /pcie #{PI_PLACE} 2"] => 'intx ok 176',
      ['intx-no-mask', "intx /pcie #{PI_PLACE} 2"] => 'intx ok 176',
      ['intx-no-mask', 'intx /pcie 0 0 0 2'] => 'intx none 0',
      ['intx-wide-parent-address', "intx /pcie #{PI_PLACE} 1"] => 'intx malformed 0',
      ['intx-other-controller', "intx /pcie #{PI_PLACE} 1"] => 'intx unsupported 0',
      ['intx-two-parents', "intx /pcie #{PI_PLACE} 1"] => 'intx unsupported 0',
      ['intx-two-parents', "intx /pcie #{PI_PLACE} 2"] => 'intx unsupported 0'
    }.each { |(name, query), expected| assert_equal expected, fixture_answers(name, [query])[1], "#{name}: #{query}" }
  end

  # A host bridge's windows and buses (docs/design-device-tree.md, "A PCI host bridge").
  def test_bridge_facts
    {
      ['bridge-virt', 'bridge /pcie'] => 'bridge ok buses 0 31 window 0x40000000 0x40000000 0x2eff0000 0 ' \
                                         'window 0x8000000000 0x8000000000 0x8000000000 3',
      ['bridge-bare', 'bridge /pcie'] => 'bridge ok buses 0 255',
      ['bridge-bare', 'bridge /nowhere'] => 'bridge no_node buses 0 0',
      ['bridge-bare', 'bridge /'] => 'bridge malformed buses 0 0',
      ['bridge-empty-ranges', 'bridge /pcie'] => 'bridge malformed buses 0 0',
      ['bridge-partial-entry', 'bridge /pcie'] => 'bridge malformed buses 0 0',
      ['bridge-two-cells', 'bridge /pcie'] => 'bridge cells buses 0 0',
      ['bridge-wide-sizes', 'bridge /pcie'] => 'bridge cells buses 0 0',
      ['bridge-configuration', 'bridge /pcie'] => 'bridge malformed buses 0 0',
      ['bridge-cpu-wrap', 'bridge /pcie'] => 'bridge malformed buses 0 0',
      ['bridge-pci-wrap', 'bridge /pcie'] => 'bridge malformed buses 0 0',
      ['bridge-in-ram', 'bridge /pcie'] => 'bridge malformed buses 0 0',
      ['bridge-five', 'bridge /pcie'] => 'bridge ranges buses 0 0',
      ['bridge-translated', 'bridge /scb/pcie'] => 'bridge ok buses 0 255 window 0xf8000000 0x80000000 0x4000000 0',
      ['bridge-half-translated', 'bridge /scb/pcie'] => 'bridge malformed buses 0 0',
      ['bridge-one-size-cell', 'bridge /pcie'] => 'bridge ok buses 0 255 window 0xf8000000 0x80000000 0x4000000 2',
      ['bridge-overlap-pci', 'bridge /pcie'] => 'bridge malformed buses 0 0',
      ['bridge-overlap-cpu', 'bridge /pcie'] => 'bridge malformed buses 0 0',
      ['bridge-bus-past', 'bridge /pcie'] => 'bridge malformed buses 0 0',
      ['bridge-bus-reversed', 'bridge /pcie'] => 'bridge malformed buses 0 0',
      ['bridge-bus-short', 'bridge /pcie'] => 'bridge malformed buses 0 0',
      ['bridge-inbound', 'bridge /scb/pcie'] =>
        'bridge ok buses 0 255 window 0xf8000000 0x80000000 0x4000000 0 inbound 0x0 0x0 0xc0000000 0',
      ['bridge-inbound-moved', 'bridge /scb/pcie'] =>
        'bridge ok buses 0 255 window 0xf8000000 0x80000000 0x4000000 0 inbound 0x0 0x100000000 0xc0000000 0',
      ['bridge-inbound-split', 'bridge /scb/pcie'] => 'bridge malformed buses 0 0',
      ['bridge-inbound-overlap', 'bridge /scb/pcie'] => 'bridge malformed buses 0 0',
      ['bridge-inbound-io', 'bridge /scb/pcie'] => 'bridge malformed buses 0 0'
    }.each { |(name, query), expected| assert_equal expected, fixture_answers(name, [query])[1], "#{name}: #{query}" }
  end

  # The root maps only the window its row names: a tree that names another device's page
  # under the RNG200's compatible string is refused, at the row's path or elsewhere.
  def test_register_window_is_the_rows
    assert_equal 'regs other', fixture_answers('regs-other-page', ["regs #{RNG_ROW}"])[1]
    assert_equal 'regs none', fixture_answers('regs-elsewhere', ["regs #{RNG_ROW}"])[1]
  end

  MUTANTS.each do |name, (original, replacement, fixture_name, query, expected, source)|
    define_method("test_seeded_#{name.tr(" '", '__')}_is_caught") do
      assert_equal expected, fixture_answers(fixture_name, [query].compact).last, 'the unseeded reader'
      source ||= READER
      text = File.read(File.join(ROOT, source))
      assert_equal 1, text.scan(original).size, 'the seed names one site'
      seeded = File.join(@directory, "seeded_#{File.basename(source)}")
      File.write(seeded, text.sub(original) { replacement })
      program = build(seeded: { source => seeded }, name: name, flags: %w[-fsanitize=address,undefined -fno-sanitize-recover=all])
      tree_name, prefix = fixture_name.split('@')
      lines, status = ask(fixture(tree_name), [query].compact, program: program, prefix: prefix&.to_i)
      refute status.success? && lines.last == expected, "#{name} went unnoticed"
    end
  end
end
