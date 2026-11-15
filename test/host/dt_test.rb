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

  FIXTURES = {
    'parent-coherent' => tree('bus { #address-cells = <2>; #size-cells = <1>; dma-coherent; dev { }; };'),
    'both-marks' => tree('dev { dma-coherent; dma-noncoherent; };'),
    'mark-with-value' => tree('dev { dma-coherent = <0>; };'),
    'own-mark' => tree('dev { dma-coherent; }; plain { };'),
    'gap-below-ranges' => tree('outer { #address-cells = <2>; #size-cells = <1>; dma-ranges = <0x0 0x0 0x0 0x0 0x40000000>; ' \
                               'gap { #address-cells = <2>; #size-cells = <1>; dev { }; }; };'),
    'two-memories' => tree('dev { };', memory: 'memory@0 { device_type = "memory"; reg = <0x0 0x0 0x1000000 0x1 0x0 0x1000000>; };'),
    'pci-three-cells' => tree('pcie { device_type = "pci"; #address-cells = <3>; #size-cells = <2>; ' \
                              'dma-ranges = <0x2000000 0x0 0x0 0x0 0x0 0x0 0x40000000>; };'),
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
    # The first node disabled, the second enabled.
    'regs-second' => tree(RNG.call(reg: '0x0 0xfe104000 0x28', status: 'disabled') +
                          RNG.call(reg: '0x0 0xfe105000 0x28').sub('rng@7e104000', 'rng@7e105000')),
    'regs-empty' => tree(RNG.call(reg: '0x0 0xfe104000 0x0')),
    'regs-short' => tree(RNG.call(reg: '0x0 0xfe104000'))
  }.freeze

  # The framebuffer row's window in the fixtures, above their RAM; one whose end is not
  # a page boundary; one over the RAM below.
  WINDOW = '0x7e000000 0x400000'
  CROSSING_WINDOW = '0x7e000000 0x3ff900'
  RAM_WINDOW = '0x3fe00000 0x800000'

  # name => [original, replacement, fixture, query, the line the unseeded reader gives].
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
      ["ac = fdt_address_cells(tree->bytes, path[level]);\n\t\tsc = fdt_size_cells(tree->bytes, path[level]);",
       "ac = fdt_address_cells(tree->bytes, path[level - 1]);\n\t\tsc = fdt_size_cells(tree->bytes, path[level - 1]);",
       'nested', 'device /outer/inner/dev node', 'device ok coherent 0 range 0x0 0x80000000 0xffffff mac none'],
    'the marks above the node passed over' =>
      ['for (i = 0; i < depth; i++)', 'for (i = depth; i < depth; i++)', 'parent-coherent', 'device /bus/dev node',
       'device coherence coherent 0 range 0x0 0x0 0x0 mac none'],
    'the marks tested for presence only' =>
      ['if ((on != NULL && on_len != 0) || (off != NULL && off_len != 0))', 'if (false)', 'mark-with-value',
       'device /dev node', 'device malformed coherent 0 range 0x0 0x0 0x0 mac none'],
    'the level above the first non-empty one dropped' =>
      ['for (level = bus_level; level >= 0; level--)', 'for (level = bus_level; level >= bus_level; level--)', 'nested',
       'device /outer/inner/dev node', 'device ok coherent 0 range 0x0 0x80000000 0xffffff mac none'],
    "the windows' bound removed" =>
      ["\t\t\tif (count == ERX_DT_WINDOWS_MAX)\n\t\t\t\treturn (ERX_DT_DMA_RANGES);\n", '', 'splitting',
       'device /outer/inner/dev node', 'device ranges coherent 0 range 0x0 0x0 0x0 mac none'],
    'the RAM filter removed' =>
      ['if (memory_meets(tree, windows[side][i].at,', 'if (true || memory_meets(tree, windows[side][i].at,', 'over-no-ram',
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
       "regs #{RNG_COMPATIBLE}", 'regs ok 0xfe104000 0x28'],
    'a bus with no ranges taken as the identity' =>
      ["if (ranges == NULL)\n\t\t\treturn (false);\n\t\tif (len == 0)", 'if (ranges == NULL || len == 0)', 'regs-no-ranges',
       "regs #{RNG_COMPATIBLE}", 'regs malformed 0x0 0x0'],
    "the window's start left untested" =>
      ['count != 1 || pieces[0].bus != base ||', 'count != 1 ||', 'regs-tail', "regs #{RNG_COMPATIBLE}", 'regs malformed 0x0 0x0'],
    'the window taken from the first of two pieces' =>
      ['count != 1 || pieces[0].bus != base ||', 'pieces[0].bus != base ||', 'regs-twice', "regs #{RNG_COMPATIBLE}", 'regs malformed 0x0 0x0'],
    "the register window's RAM test removed" =>
      ['pieces[0].last != last || memory_meets(tree, pieces[0].at, window_at_last(&pieces[0])))', 'pieces[0].last != last)',
       'regs-in-ram', "regs #{RNG_COMPATIBLE}", 'regs malformed 0x0 0x0']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-dt-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(reader: File.join(ROOT, READER), name: 'driver', flags: @flags)
    output = File.join(@directory, name.tr(" '", '--'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *Erx::PackFuzz.define_flags(TARGET), *flags, *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, LIBFDT), reader,
                                  *(TARGET.sources - [READER]).map { |source| File.join(ROOT, source) }, File.join(ROOT, DRIVER),
                                  '-o', output, stdin_data: '')
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
                           "fb /chosen simple-framebuffer #{WINDOW}", 'seeds'])
    assert_equal ['accept ok memory 1',
                  "device ok coherent 1 #{IDENTITY} mac none",
                  "device ok coherent 1 #{IDENTITY} mac none",
                  # QEMU marks the root dma-coherent; the UART carries no mark of its own.
                  'device coherence coherent 0 range 0x0 0x0 0x0 mac none',
                  "device ok coherent 1 #{IDENTITY} mac none",
                  'device no_node coherent 0 range 0x0 0x0 0x0 mac none',
                  'fb none 0x0 0x0 0x0 0 - 0'], lines[0..-2]
    # QEMU virt's seeds are random, so only their lengths are known.
    assert_match(/\Aseeds rng-seed 32 \h{64} kaslr-seed 8 \h{16}\z/, lines.last)
  end

  def test_raspberry_pi_4_trees
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    built = Erx::BoardTree.build(root: ROOT, runner: runner, platform: Erx::Platform.load(root: ROOT, name: 'raspi4b'),
                                 compiler: ENV.fetch('ERX_CLANG', 'clang'), revision: nil)
    queries = ['device /emmc2bus/mmc@7e340000 node', 'device /scb/ethernet@7d580000 node', 'device /scb/pcie@7d500000 pcie']
    # The model's tree has the memory node the firmware fills.
    assert_equal ['accept ok memory 1',
                  'device ok coherent 0 range 0x0 0xc0000000 0x3fffffff mac none',
                  "device ok coherent 0 #{IDENTITY} mac none",
                  'device cells coherent 0 range 0x0 0x0 0x0 mac none'], answers(built.model, queries)
    # The card's tree leaves the memory node as zeros, so no window has RAM behind it.
    assert_equal ['accept ok memory 0',
                  'device ranges coherent 0 range 0x0 0x0 0x0 mac none',
                  'device ranges coherent 0 range 0x0 0x0 0x0 mac none',
                  'device cells coherent 0 range 0x0 0x0 0x0 mac none'], answers(built.board, queries)
    # Both trees place the RNG200 at 0x7e104000 on the soc bus, CPU address 0xfe104000.
    [built.model, built.board].each { |tree| assert_equal 'regs ok 0xfe104000 0x28', answers(tree, ["regs #{RNG_COMPATIBLE}"])[1] }
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
      ['pci-three-cells', 'device /pcie pcie'] => 'device cells coherent 0 range 0x0 0x0 0x0 mac none',
      ['pcie-two-cells', 'device /pcie pcie'] => 'device ok coherent 0 range 0x0 0x80000000 0x3fffffff mac none',
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
      'regs-identity' => 'regs ok 0xfe104000 0x28',
      'regs-translated' => 'regs ok 0xfe104000 0x28',
      'regs-empty-ranges' => 'regs ok 0xfe104000 0x28',
      'regs-second' => 'regs ok 0xfe105000 0x28',
      'regs-no-ranges' => 'regs malformed 0x0 0x0',
      'regs-split' => 'regs malformed 0x0 0x0',
      'regs-partial' => 'regs malformed 0x0 0x0',
      'regs-tail' => 'regs malformed 0x0 0x0',
      'regs-twice' => 'regs malformed 0x0 0x0',
      'regs-in-ram' => 'regs malformed 0x0 0x0',
      'regs-empty' => 'regs malformed 0x0 0x0',
      'regs-short' => 'regs malformed 0x0 0x0',
      'regs-disabled' => 'regs none 0x0 0x0',
      'own-mark' => 'regs none 0x0 0x0'
    }.each { |name, expected| assert_equal expected, fixture_answers(name, ["regs #{RNG_COMPATIBLE}"])[1], name }
  end

  MUTANTS.each do |name, (original, replacement, fixture_name, query, expected)|
    define_method("test_seeded_#{name.tr(" '", '__')}_is_caught") do
      assert_equal expected, fixture_answers(fixture_name, [query].compact).last, 'the unseeded reader'
      text = File.read(File.join(ROOT, READER))
      assert_includes text, original
      seeded = File.join(@directory, 'seeded_dt.c')
      File.write(seeded, text.sub(original) { replacement })
      program = build(reader: seeded, name: name, flags: %w[-fsanitize=address,undefined -fno-sanitize-recover=all])
      tree_name, prefix = fixture_name.split('@')
      lines, status = ask(fixture(tree_name), [query].compact, program: program, prefix: prefix&.to_i)
      refute status.success? && lines.last == expected, "#{name} went unnoticed"
    end
  end
end
