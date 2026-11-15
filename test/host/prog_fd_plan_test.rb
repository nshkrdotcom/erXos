# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# The descriptor table's decisions (liberx/program/fd_plan.h) through
# test/fixtures/prog_fd_plan_driver.c under the address and undefined sanitizers. Every dup
# over every table of up to four slots, each mode, each source from -1 past the table and
# each target from -2 past it, against the model below, which restates FreeBSD 15.1's
# kern_dup (sys/kern/kern_descrip.c) and its libc's dup3 (lib/libc/gen/dup3.c); and the
# fcntl commands, dup3's flags, F_SETFL's status flags and lseek of a device against the
# tables below, after kern_fcntl and vn_seek (sys/kern/vfs_vnops.c). Each seeded fault must
# fail its case.
class ProgFdPlanTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PLAN = 'liberx/program/fd_plan.c'
  SOURCES = [PLAN, 'test/fixtures/prog_fd_plan_driver.c'].freeze
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  SIZES = (1..4).freeze

  # FreeBSD's libc dup3 refuses a target equal to the source with EINVAL before anything
  # else; then kern_dup: a negative source is EBADF; for dup3's fixed mode a target outside
  # the table is EBADF and an empty source EBADF; for F_DUPFD's mode a bound outside the table is EINVAL, an empty source
  # EBADF, and no empty slot at or above the bound EMFILE.
  def self.dup(mode, held, from, at, size)
    holds = ->(slot) { slot >= 0 && slot < size && held[slot] == 1 }
    inside = at >= 0 && at < size
    return 'EINVAL' if mode == 'at' && at == from
    return 'EBADF' if from.negative?

    case mode
    when 'at'
      return 'EBADF' unless inside

      holds.call(from) ? at.to_s : 'EBADF'
    when 'lowest'
      return 'EINVAL' unless inside
      return 'EBADF' unless holds.call(from)

      (at...size).find { |slot| held[slot].zero? }&.to_s || 'EMFILE'
    end
  end

  def self.plan_lines(size)
    %w[lowest at].product((0...(1 << size)).to_a, (-1..size).to_a, (-2..size + 1).to_a)
                 .map { |mode, held, from, at| "#{mode} #{held} #{from} #{at} #{dup(mode, held, from, at, size)}" }
  end

  INT64_MAX = (1 << 63) - 1
  # Each request with its answer.
  CASES = {
    'dup3 3 5 0' => 'ok at 3 5 -',
    'dup3 3 5 oc' => 'ok at 3 5 cloexec',
    'dup3 3 5 nonblock' => 'EINVAL',
    'dup3 3 5 oc+append' => 'EINVAL',
    'fcntl 3 dupfd 7' => 'dup lowest 3 7 -',
    'fcntl 3 dupfd_cloexec 7' => 'dup lowest 3 7 cloexec',
    'fcntl 3 dupfd -1' => 'dup lowest 3 -1 -',
    'fcntl 3 getfd 0' => 'getfd',
    'fcntl 3 setfd cloexec' => 'setfd cloexec',
    'fcntl 3 setfd 0' => 'setfd -',
    'fcntl 3 setfd 2' => 'setfd -',
    'fcntl 3 getfl 0' => 'getfl',
    'fcntl 3 setfl nonblock' => 'setfl arg',
    'fcntl -1 getlk 0' => 'EINVAL',
    'status nonblock' => 'nonblock',
    'status nonblock+append' => 'nonblock+append',
    'status wronly+sync+append' => 'append',
    'status 0' => '-',
    'status nonblock+async' => 'EINVAL',
    'seek 5 7 set 0' => '7',
    'seek 5 7 cur 0' => '12',
    'seek 5 -5 cur 0' => '0',
    'seek 5 -6 cur 0' => 'EINVAL',
    'seek 5 3 end 0' => '3',
    'seek 5 -1 set 0' => 'EINVAL',
    "seek #{INT64_MAX} 1 cur 0" => 'EOVERFLOW',
    "seek 0 #{INT64_MAX} set 0" => INT64_MAX.to_s,
    'seek 5 0 99 0' => 'EINVAL'
  }.freeze

  # Each seeded fault: the requests it must fail, the source, the text replaced and its replacement.
  MUTANTS = {
    'a dup onto the slot it copies is let through' =>
      [:plans, PLAN, "\tif (req.mode == ERX_PROG_DUP_AT && req.at == req.from)\n\t\treturn (-EINVAL);\n", ''],
    'F_DUPFD searches below its bound' =>
      [:plans, PLAN, 'for (uint32_t at = (uint32_t)req.at; at < nslots; at++)', 'for (uint32_t at = 0; at < nslots; at++)'],
    'the last slot is never taken' =>
      [:plans, PLAN, '; at < nslots; at++)', '; at + 1 < nslots; at++)'],
    'dup3 into a slot past the table' =>
      [:plans, PLAN, "\t\tif (!inside)\n\t\t\treturn (-EBADF);\n", ''],
    'dup3 takes any flag' => [:cases, PLAN, "\tif ((flags & ~O_CLOEXEC) != 0)\n\t\treturn (-EINVAL);\n", ''],
    'O_ASYNC is taken' => [:cases, PLAN, "\treturn (on ? -EINVAL : 0);", "\treturn (on ? 0 : 0);"],
    'a seek to a negative offset' => [:cases, PLAN, 'return (*to < 0 ? -EINVAL : 0);', 'return (0);']
  }.freeze

  def test_every_dup_over_small_tables_decides_as_kern_dup
    SIZES.each do |size|
      assert_equal self.class.plan_lines(size), run_driver(["plans #{size}"]), "a table of #{size} slots"
    end
  end

  def test_fcntl_dup3_status_and_seek_decide_as_freebsd
    assert_equal CASES.to_a, CASES.keys.zip(run_driver(CASES.keys))
  end

  def test_seeded_faults_are_caught
    Dir.mktmpdir('erx-prog-fd-plan-mutant-') do |directory|
      MUTANTS.each do |name, (which, file, original, replacement)|
        source = File.read(File.join(ROOT, file))
        assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
        path = File.join(directory, "#{name.tr(' ', '-').delete("'")}.c")
        File.write(path, source.sub(original, replacement))
        requests, expected = which == :plans ? plan_requests : [CASES.keys, CASES.values]
        refute_equal expected, run_driver(requests, file => path), "seeded fault not caught: #{name}"
      end
    end
  end

  private

  def plan_requests = [SIZES.map { |size| "plans #{size}" }, SIZES.flat_map { |size| self.class.plan_lines(size) }]

  # Builds the driver from SOURCES, each path of replaced built from its replacement instead.
  def run_driver(requests, replaced = {})
    Dir.mktmpdir('erx-prog-fd-plan-') do |directory|
      binary = File.join(directory, 'driver')
      input = File.join(directory, 'requests')
      File.write(input, "#{requests.join("\n")}\n")
      sources = SOURCES.map { |path| replaced.fetch(path) { File.join(ROOT, path) } }
      output, status = Open3.capture2e(COMPILER, *FLAGS, '-I', ROOT, *sources, '-o', binary)
      assert status.success?, output
      output, status = Open3.capture2e(binary, input)
      assert status.success?, output
      output.lines.map(&:chomp)
    end
  end
end
