# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/generated_tree'
require_relative '../../tools/lib/erx/runner'

# The end of a loader's tenure (docs/design-programs.md, "The loader's
# bootstrap", Release, and Verification, "The record's span"): the pure
# check of erx_exec_release (liberx/exec/release.c), and the program layer's
# erx_prog_enter (liberx/program/program.c) running it over a stand-in space,
# through the host driver test/fixtures/exec_release_driver.c.
class ExecReleaseTest < Minitest::Test
  PAGE = 4096
  MAX = (1 << 64) - 1
  # ERX_EINVAL (abi/erx_abi.txt), the stand-in space's refusal.
  EINVAL = -1
  # ERX_PROG_STATUS_RELEASE (liberx/program/startup.h).
  RELEASE = -(1 << 32)
  # In the stand-in space: the record's page, the loader's span and the program's own image.
  RECORD = 8 * PAGE
  LOADER = 16 * PAGE
  LOADER_SIZE = 4 * PAGE
  OWN = 32 * PAGE
  OWN_SIZE = 8 * PAGE

  def setup
    @directory = Dir.mktmpdir('erx-exec-release-')
    root = File.expand_path('../..', __dir__)
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @driver = File.join(@directory, 'exec-release')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported exec-release sanitizer' unless (sanitizers - %w[address undefined]).empty?

    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', *flags,
                 *Erx::Generated.include_flags(root: root), '-I', File.join(root, 'include'), '-I', root,
                 *%w[liberx/exec/release.c liberx/program/program.c test/fixtures/exec_release_stubs.c
                     test/fixtures/exec_release_driver.c].map { |path| File.join(root, path) },
                 '-o', @driver],
                name: 'compile-exec-release', deadline: 60)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def driver(*arguments)
    record = @runner.run([@driver, *arguments.map(&:to_s)], name: 'exec-release', deadline: 30)
    File.read(record.fetch('log')).lines.map(&:chomp)
  end

  def verdict(record, base, size, own: [OWN, OWN_SIZE]) = driver('check', record, base, size, *own).fetch(0)

  def test_the_check_accepts_the_loader_span_beside_the_image
    assert_equal 'go', verdict(PAGE, LOADER, LOADER_SIZE)
    assert_equal 'go', verdict(PAGE, OWN - LOADER_SIZE, LOADER_SIZE), 'ending where the image starts'
    assert_equal 'go', verdict(PAGE, OWN + OWN_SIZE, LOADER_SIZE), 'starting where the image ends'
  end

  def test_the_check_refuses_a_record_that_is_not_a_page_boundary
    assert_equal 'record', verdict(0, LOADER, LOADER_SIZE)
    assert_equal 'record', verdict(PAGE + 8, LOADER, LOADER_SIZE)
  end

  def test_the_check_refuses_an_unaligned_span
    assert_equal 'unaligned', verdict(PAGE, LOADER + 1, LOADER_SIZE)
    assert_equal 'unaligned', verdict(PAGE, LOADER, LOADER_SIZE + 1), 'an end one byte past a page'
  end

  # Seeded fault: a check that admits a size of 0 accepts the record of a load that failed.
  def test_the_check_refuses_an_empty_span
    assert_equal 'empty', verdict(PAGE, LOADER, 0)
    assert_equal 'empty', verdict(PAGE, 0, 0), 'a record whose load failed'
  end

  def test_the_check_refuses_a_span_whose_end_overflows
    assert_equal 'overflow', verdict(PAGE, MAX + 1 - PAGE, 2 * PAGE)
    assert_equal 'overflow', verdict(PAGE, PAGE, MAX + 1 - PAGE)
    assert_equal 'overflow', verdict(PAGE, MAX + 1 - PAGE, PAGE), 'an end of 2^64'
  end

  # Seeded fault: a check without the comparison with the executable's image accepts each.
  def test_the_check_refuses_a_span_that_meets_the_image
    assert_equal 'overlap', verdict(PAGE, OWN, LOADER_SIZE), 'the image itself'
    assert_equal 'overlap', verdict(PAGE, OWN - PAGE, 2 * PAGE), 'the image start'
    assert_equal 'overlap', verdict(PAGE, OWN + OWN_SIZE - PAGE, 2 * PAGE), 'the image end'
    assert_equal 'overlap', verdict(PAGE, OWN - PAGE, OWN_SIZE + 2 * PAGE), 'around the image'
    assert_equal 'overlap', verdict(PAGE, OWN + PAGE, PAGE), 'inside the image'
  end

  def enter(record, base, size, refuse: 0) = driver('enter', record, base, size, OWN, OWN_SIZE, refuse)

  def test_a_program_erx_exec_did_not_load_releases_nothing
    assert_equal ['entered'], enter('-', LOADER, LOADER_SIZE)
  end

  # Seeded fault: an erx_prog_enter that leaves the release to liberx_program_main,
  # after musl's start, lets the constructor read the record.
  def test_the_span_then_the_record_are_released_before_a_constructor_runs
    assert_equal ["release #{LOADER} #{LOADER_SIZE} 0", "release #{RECORD} #{PAGE} 0", 'entered',
                  "constructor #{'dd' * 8}"], enter(RECORD, LOADER, LOADER_SIZE)
  end

  def test_a_refused_span_stops_the_program_before_any_release
    assert_equal ["stop #{RELEASE}"], enter(RECORD, OWN, LOADER_SIZE), 'a span over the image'
    assert_equal ["stop #{RELEASE}"], enter(RECORD, '-', 0), 'the record of a load that failed'
    assert_equal ["stop #{RELEASE}"], enter(RECORD + 8, LOADER, LOADER_SIZE), 'a record off its page'
  end

  def test_a_release_the_space_refuses_stops_the_program
    assert_equal ["release #{LOADER} #{LOADER_SIZE} #{EINVAL}", "stop #{RELEASE}"],
                 enter(RECORD, LOADER, LOADER_SIZE, refuse: 1)
    assert_equal ["release #{LOADER} #{LOADER_SIZE} 0", "release #{RECORD} #{PAGE} #{EINVAL}",
                  "stop #{RELEASE}"], enter(RECORD, LOADER, LOADER_SIZE, refuse: 2)
  end
end
