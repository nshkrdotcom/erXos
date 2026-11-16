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
    # The effects edge over the memory calls of test/fixtures/exec_load_effects.c.
    @effects = File.join(@directory, 'exec-load-effects')
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', *flags,
                 *Erx::Generated.include_flags(root: root), '-I', File.join(root, 'include'), '-I', root,
                 File.join(root, 'liberx/elf_plan.c'), File.join(root, 'liberx/exec/load_plan.c'),
                 File.join(root, 'liberx/exec/load.c'),
                 Erx::Generated.path('liberx/generated/abi_reader.c', root: root),
                 File.join(root, 'test/fixtures/exec_load_effects.c'), '-o', @effects],
                name: 'compile-exec-load-effects', deadline: 60)
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

  def run_driver(*arguments, driver: @driver)
    @runner.run([driver, *arguments.map(&:to_s)], name: 'exec-load', deadline: 30)
  rescue Erx::CommandError => error
    error.result
  end

  Effects = Data.define(:outcome, :reserves, :releases)

  # erx_exec_load over the effects driver's memory calls: the outcome line, each
  # reservation [address, size] and each release [address, size, status].
  def load_effects(bytes, refuse: 0, fail: '-')
    input = File.join(@directory, 'effects.elf')
    File.binwrite(input, bytes)
    text = File.read(run_driver(input, refuse, fail, driver: @effects).fetch('log'))
    Effects.new(outcome: text.lines.last.chomp,
                reserves: text.scan(/^reserve (\d+) (\d+)$/).map { |row| row.map(&:to_i) },
                releases: text.scan(/^release (\d+) (\d+) (-?\d+)$/).map { |row| row.map(&:to_i) })
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
  # The file's end: the planner reads the file's exact bytes, not the object's
  # page-rounded view, so a segment whose file bytes reach one byte into the last
  # page's padding is refused (seed: a load that plans the rounded length accepts it).
  def test_the_load_plans_the_files_exact_bytes
    bytes = patch(ElfFixture.pie, WRITABLE, FILE_SIZE, 3000)[0, PAGE + 3000]
    assert_match(/^loaded \d+ \d+$/, load_effects(bytes).outcome)
    assert_equal 'refused load_file_extent 4096', load_effects(patch(bytes, WRITABLE, FILE_SIZE, 3001)).outcome
  end

  # A load that succeeds releases its view of the object and keeps the executable's
  # reservation; a refused release of the view is refused cleanup, never a load
  # (seed: a load that discards the release's status reports the file loaded).
  def test_a_load_releases_its_view_and_a_refused_release_is_refused_cleanup
    loaded = load_effects(ElfFixture.pie)
    assert_match(/^loaded \d+ \d+$/, loaded.outcome)
    view, = loaded.reserves
    assert_equal [[*view, 0]], loaded.releases
    refused = load_effects(ElfFixture.pie, refuse: 1)
    assert_equal 'cleanup_refused', refused.outcome
    assert_equal [[*view, -1]], refused.releases
  end

  # A load that fails releases the reservation and the view, whether a call failed
  # part way or the plan refused the file, and reports the step that failed; a refused
  # release on that route is refused cleanup.
  def test_a_failed_load_releases_everything_and_a_refused_release_is_refused_cleanup
    failed = load_effects(ElfFixture.pie, fail: 'child:1')
    assert_equal 'failed child -6', failed.outcome
    view, reservation = failed.reserves
    assert_equal [[*reservation, 0], [*view, 0]], failed.releases
    view_map_failed = load_effects(ElfFixture.pie, fail: 'map:1')
    assert_equal ['failed view -6', [[*view, 0]]], [view_map_failed.outcome, view_map_failed.releases]
    refused = load_effects(ElfFixture.valid)
    assert_match(/^refused fixed_image /, refused.outcome)
    assert_equal [[*refused.reserves.first, 0]], refused.releases
    [1, 2].each do |index|
      assert_equal 'cleanup_refused', load_effects(ElfFixture.pie, fail: 'child:1', refuse: index).outcome
    end
  end
end
