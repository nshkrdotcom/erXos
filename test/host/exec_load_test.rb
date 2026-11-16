# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/elf_fixture'
require_relative '../fixtures/generated_tree'
require_relative '../../tools/lib/erx/runner'

# erx_exec's pure core (liberx/exec/load_plan.h) through its host driver
# (test/fixtures/exec_load_driver.c), against an image this test builds
# from the file's program headers alone: each read-only or executable
# segment's pages as the file holds them, each writable one's file bytes
# then zeros to its last page, and every relocation's word the base plus
# its addend, modulo 2^64.
class ExecLoadTest < Minitest::Test
  PAGE = 4096
  # Where ElfFixture.pie's program headers start, and the offsets of a header's
  # file size and alignment.
  PHOFF = 64
  FILE_SIZE = 32
  ALIGN = 48
  # pie's headers: read-execute, note, read-write, dynamic.
  WRITABLE = 2
  EXECUTABLE = 0

  def setup
    @directory = Dir.mktmpdir('erx-exec-load-')
    root = File.expand_path('../..', __dir__)
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @driver = File.join(@directory, 'exec-load')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported exec-load sanitizer' unless (sanitizers - %w[address undefined]).empty?
    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', *flags,
                 *Erx::Generated.include_flags(root: root), '-I', File.join(root, 'include'), '-I', root,
                 File.join(root, 'liberx/elf_plan.c'), File.join(root, 'liberx/exec/load_plan.c'),
                 Erx::Generated.path('liberx/generated/abi_reader.c', root: root),
                 File.join(root, 'test/fixtures/exec_load_driver.c'), '-o', @driver],
                name: 'compile-exec-load', deadline: 60)
    # The effects edge builds against the kernel interface's declarations; only a program links it.
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-fsyntax-only',
                 *Erx::Generated.include_flags(root: root), '-I', File.join(root, 'include'), '-I', root,
                 File.join(root, 'liberx/exec/load.c')], name: 'syntax-exec-load', deadline: 60)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  Loaded = Data.define(:status, :base, :entry, :span, :reserve, :steps, :image, :output)

  def load(bytes, reserved:, size: 0)
    input = File.join(@directory, 'input.elf')
    output = File.join(@directory, 'image.bin')
    File.binwrite(input, bytes)
    File.delete(output) if File.exist?(output)
    record = run_driver(input, reserved, size, output)
    text = File.read(record.fetch('log'))
    header = text[/^base (\d+) entry (\d+) span (\d+) reserve (\d+)$/] && Regexp.last_match.captures.map(&:to_i)
    steps = text.scan(/^step (\w+) (\d+) (\d+) (\d+) (\d+)$/).map { |kind, *rest| [kind, *rest.map(&:to_i)] }
    Loaded.new(status: record.fetch('exit_status'), base: header&.at(0), entry: header&.at(1), span: header&.at(2),
               reserve: header&.at(3), steps: steps, image: File.exist?(output) ? File.binread(output) : nil,
               output: text)
  end

  def run_driver(*arguments)
    @runner.run([@driver, *arguments.map(&:to_s)], name: 'exec-load', deadline: 30)
  rescue Erx::CommandError => error
    error.result
  end

  def pages(bytes) = (bytes + PAGE - 1) / PAGE * PAGE

  def patch(bytes, index, field, value)
    copy = bytes.dup
    copy[PHOFF + index * 56 + field, 8] = [value].pack('Q<')
    copy
  end

  # The image the program should see, from the program headers and the relocations.
  def expected(bytes, base:, span:, relocations:)
    image = "\xee".b * span
    count = bytes[56, 2].unpack1('v')
    count.times do |index|
      type, flags, offset, address, _, file_size, memory_size = bytes[PHOFF + index * 56, 56].unpack('V2Q<5')
      next unless type == 1

      if (flags & 2).zero?
        image[address, pages(memory_size)] = bytes[offset, pages(memory_size)]
      else
        image[address, pages(memory_size)] = bytes[offset, file_size].ljust(pages(memory_size), "\0")
      end
    end
    relocations.each { |target, addend| image[target, 8] = [(base + addend) % (1 << 64)].pack('Q<') }
    image
  end

  # A pie whose writable segment ends partway through its file page, the rest of
  # which the file fills with bytes that must read as zeros, with a relocation
  # into that tail, one into the zero page and one whose sum wraps.
  def partial_pie
    relocations = [[4352, 1024], [4360, 6144], [7200, 32], [8200, 16], [4368, -16]]
    bytes = ElfFixture.pie(relocations: relocations.map { |target, addend| ElfFixture.relocation(target, addend) })
    bytes = patch(bytes, WRITABLE, FILE_SIZE, 3000)
    bytes[4096 + 3000, 4096 - 3000] = "\x5a".b * (4096 - 3000)
    [bytes, relocations]
  end

  def test_segments_map_zero_commit_and_relocate_in_place
    bytes, relocations = partial_pie
    loaded = load(bytes, reserved: 0x40_0000)
    assert_equal 0, loaded.status, loaded.output
    assert_equal 0x40_0000, loaded.base
    assert_equal 0x40_0000 + 1024, loaded.entry
    assert_equal [['map', 0x40_0000, PAGE, 0, 5], ['child', 0x40_1000, PAGE, 4096, 0],
                  ['zero', 0x40_1000 + 3000, PAGE - 3000, 0, 0], ['commit', 0x40_2000, PAGE, 0, 0]], loaded.steps
    assert_equal expected(bytes, base: loaded.base, span: loaded.span, relocations: relocations), loaded.image
  end

  def test_base_is_the_first_aligned_address_and_the_span_fits_the_reservation
    bytes, relocations = partial_pie
    bytes = patch(bytes, EXECUTABLE, ALIGN, 0x10000)
    loaded = load(bytes, reserved: 0x50_2000)
    assert_equal 0, loaded.status, loaded.output
    assert_equal loaded.span + 0x10000 - PAGE, loaded.reserve
    assert_equal 0x51_0000, loaded.base
    assert_operator loaded.base + loaded.span, :<=, 0x50_2000 + loaded.reserve
    assert_equal expected(bytes, base: loaded.base, span: loaded.span, relocations: relocations), loaded.image
  end

  def test_a_writable_segment_without_file_bytes_is_committed_whole
    writable = ElfFixture.program(type: 1, flags: 6, offset: 8192, address: 12_288, file_size: 0,
                                  memory_size: 5000, alignment: PAGE)
    loaded = load(ElfFixture.pie(relocations: [], extra: [writable]), reserved: 0x40_0000)
    assert_equal 0, loaded.status, loaded.output
    assert_includes loaded.steps, ['commit', 0x40_3000, 2 * PAGE, 0, 0]
    refute(loaded.steps.any? { |kind, address, *| kind == 'child' && address == 0x40_3000 })
  end

  def test_a_fixed_plan_is_refused
    loaded = load(ElfFixture.valid, reserved: 0x40_0000)
    assert_equal 1, loaded.status
    assert_match(/^error fixed_image /, loaded.output)
  end

  def test_a_reservation_the_aligned_span_does_not_fit_is_refused
    bytes, = partial_pie
    loaded = load(bytes, reserved: 0x40_0000, size: 3 * PAGE - 1)
    assert_match(/^error reservation /, loaded.output)
    loaded = load(patch(bytes, EXECUTABLE, ALIGN, 0x10000), reserved: 0x40_1000, size: 3 * PAGE)
    assert_match(/^error reservation /, loaded.output)
    loaded = load(bytes, reserved: 0xffff_ffff_ffff_f000, size: 3 * PAGE)
    assert_match(/^error reservation /, loaded.output)
  end
end
