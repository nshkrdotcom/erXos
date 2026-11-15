# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../fixtures/generated_tree'

# Judges the boot read of the RNG200, kernel/core/rng200.c, and the root's entropy line,
# liberx/backend/fiasco/entropy_line.c (docs/design-platforms.md, "Entropy sources";
# docs/design-stopgap.md, "The Raspberry Pi 4"), through test/fixtures/rng200_driver.c:
# a read whose FIFO fills is done after 32 bytes and never asks for more words than the
# count gave; one whose count stays zero gives up at the 100 ms bound and not before;
# and each banner line. Seeded faults in the read must each change a pinned answer.
class Rng200Test < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'kernel/core/rng200.c'
  LINE = 'liberx/backend/fiasco/entropy_line.c'
  DRIVER = 'test/fixtures/rng200_driver.c'
  WAIT = 100_000_000
  WORDS = 8

  # name => [original, replacement]; each must change the answers of test_reads.
  MUTANTS = {
    'the deadline checked after the count' =>
      ["\tif (now_ns >= read->deadline_ns)\n\t\treturn (ERX_RNG200_TIMED_OUT);\n\tif (count == 0)\n\t\treturn (ERX_RNG200_POLL);\n",
       "\tif (count == 0)\n\t\treturn (now_ns >= read->deadline_ns ? ERX_RNG200_TIMED_OUT : ERX_RNG200_POLL);\n"],
    'a take of the whole count' => ['*take = count < missing ? count : missing;', '*take = count;'],
    'the bound one tick late' => ['if (now_ns >= read->deadline_ns)', 'if (now_ns > read->deadline_ns)'],
    'no saturation at the clock\'s end' =>
      ["\tif (__builtin_add_overflow(now_ns, ERX_RNG200_WAIT_NS, &read.deadline_ns))\n\t\tread.deadline_ns = UINT64_MAX;\n",
       "\tread.deadline_ns = now_ns + ERX_RNG200_WAIT_NS;\n"]
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-rng200-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(core: File.join(ROOT, CORE), name: 'driver')
    output = File.join(@directory, name.tr(" '", '--'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *@flags, *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'), '-I', ROOT,
                                  core, File.join(ROOT, LINE), File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def ask(requests, program: (@driver ||= build))
    output, status = Open3.capture2e(program, stdin_data: requests.map { |request| "#{request}\n" }.join)
    assert status.success?, output
    output.lines.map(&:chomp)
  end

  # The requests of every read the tests pin, and the answers the design gives them.
  def reads
    {
      # A FIFO that holds three words at a time: takes of 3, 3 and the last 2, then done.
      'filling' => [['start 1000', "start #{1000 + WAIT}"],
                    *[3, 3, 2].flat_map.with_index do |take, pass|
                      [["next 3 #{2000 + pass}", "next take #{take}"],
                       *(1..take).map { |i| ['take 7', "take #{(pass * 3) + i}"] }]
                    end,
                    ['next 3 3000', 'next done 0'],
                    # A word past the eighth is dropped.
                    %w[take\ 9 take\ 8]],
      # A count that stays zero: polls until one tick before the bound, then gives up.
      'stuck' => [['start 0', "start #{WAIT}"], ['next 0 0', 'next poll 0'],
                  ["next 0 #{WAIT - 1}", 'next poll 0'], ["next 0 #{WAIT}", 'next timed_out 0'],
                  ["next 5 #{WAIT + 1}", 'next timed_out 0']],
      # Words that arrive after the bound are not taken.
      'late' => [['start 0', "start #{WAIT}"], ["next 8 #{WAIT}", 'next timed_out 0']],
      # A start near the clock's end saturates its deadline rather than wrapping.
      'end of clock' => [["start #{2**64 - 10}", "start #{2**64 - 1}"], ["next 0 #{2**64 - 2}", 'next poll 0']]
    }
  end

  def test_reads
    reads.each do |name, pairs|
      assert_equal pairs.map(&:last), ask(pairs.map(&:first)), name
    end
  end

  def test_lines
    {
      'line 0 0 none' => 'line erx: entropy: quality: low, from the counter alone',
      'line 0 0 read' => 'line erx: entropy: from the RNG200 (32 bytes) and the counter',
      'line 0 0 timed_out' =>
        'line erx: entropy: quality: low, from the counter alone, since the RNG200 gave too few words within 100 ms',
      'line 0 0 unreadable' => 'line erx: entropy: quality: low, from the counter alone, since the RNG200 could not be read',
      'line 32 8 none' => 'line erx: entropy: from /chosen/rng-seed (32 bytes), /chosen/kaslr-seed (8 bytes) and the counter',
      'line 1024 0 none' => 'line erx: entropy: from /chosen/rng-seed (1024 bytes) and the counter',
      'line 0 8 none' => 'line erx: entropy: from /chosen/kaslr-seed (8 bytes) and the counter',
      # /chosen's seeds win: the board is not read when they went in.
      'line 32 0 read' => 'line erx: entropy: from /chosen/rng-seed (32 bytes) and the counter'
    }.each { |request, expected| assert_equal [expected], ask([request]), request }
  end

  def test_seeded_faults_are_caught
    text = File.read(File.join(ROOT, CORE))
    requests = reads.values.flat_map { |pairs| pairs.map(&:first) }
    expected = reads.values.flat_map { |pairs| pairs.map(&:last) }
    MUTANTS.each do |name, (original, replacement)|
      assert_equal 1, text.scan(original).size, "#{name}: the seed must edit one place"
      mutant = File.join(@directory, "#{name.tr(" '", '--')}.c")
      File.write(mutant, text.sub(original, replacement))
      refute_equal expected, ask(requests, program: build(core: mutant, name: name)), name
    end
  end
end
