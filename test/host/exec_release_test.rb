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
# check of erx_exec_release (liberx/exec/release.c) against the linked
# loader, and the program layer's erx_prog_enter (liberx/program/program.c)
# running it over a stand-in space, through the host driver
# test/fixtures/exec_release_driver.c.
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
                 *%w[liberx/exec/release.c liberx/program/program.c build/gen/liberx/generated/abi_reader.c
                     test/fixtures/exec_release_stubs.c
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

  def verdict(record, base, size, own: [OWN, OWN_SIZE], loader: [LOADER, LOADER_SIZE])
    driver('check', record, base, size, *own, *loader).fetch(0)
  end

  def test_the_check_accepts_the_linked_loader_beside_the_image
    assert_equal 'go', verdict(PAGE, LOADER, LOADER_SIZE)
    assert_equal 'go', verdict(PAGE, OWN - LOADER_SIZE, LOADER_SIZE, loader: [OWN - LOADER_SIZE, LOADER_SIZE]),
                 'ending where the image starts'
    assert_equal 'go', verdict(PAGE, OWN + OWN_SIZE, LOADER_SIZE, loader: [OWN + OWN_SIZE, LOADER_SIZE]),
                 'starting where the image ends'
    assert_equal 'go', verdict(LOADER - PAGE, LOADER, LOADER_SIZE), 'the record just below the loader'
    assert_equal 'go', verdict(LOADER + LOADER_SIZE, LOADER, LOADER_SIZE), 'the record just above it'
    assert_equal 'go', verdict(OWN + OWN_SIZE, LOADER, LOADER_SIZE), 'the record just above the image'
  end

  def test_the_check_refuses_a_record_that_is_not_a_page_boundary
    assert_equal 'record', verdict(0, LOADER, LOADER_SIZE)
    assert_equal 'record', verdict(PAGE + 8, LOADER, LOADER_SIZE)
  end

  # Seeded fault: a check that takes the record's span without comparing it
  # with the linked loader's releases each of these.
  def test_the_check_refuses_a_span_other_than_the_linked_loader
    assert_equal 'loader', verdict(PAGE, LOADER + PAGE, LOADER_SIZE), 'moved by a page'
    assert_equal 'loader', verdict(PAGE, LOADER, LOADER_SIZE + PAGE), 'a page longer'
    assert_equal 'loader', verdict(PAGE, LOADER, LOADER_SIZE - PAGE), 'a page shorter'
    assert_equal 'loader', verdict(PAGE, LOADER + 1, LOADER_SIZE), 'unaligned'
    assert_equal 'loader', verdict(PAGE, 0, 0), 'the record of a load that failed'
    assert_equal 'loader', verdict(PAGE, MAX + 1 - PAGE, 2 * PAGE), 'an end past 2^64'
    assert_equal 'loader', verdict(PAGE, OWN, OWN_SIZE), "the executable's own image"
  end

  def test_a_task_linked_with_no_loader_refuses_every_record
    assert_equal 'loader', verdict(PAGE, LOADER, LOADER_SIZE, loader: [0, 0])
    assert_equal 'loader', verdict(PAGE, 0, 0, loader: [0, 0]), 'a record of zeros'
  end

  def test_the_check_refuses_a_loader_that_meets_the_image
    assert_equal 'loader-image', verdict(PAGE, OWN - PAGE, 2 * PAGE, loader: [OWN - PAGE, 2 * PAGE]), 'the image start'
    assert_equal 'loader-image', verdict(PAGE, OWN + PAGE, PAGE, loader: [OWN + PAGE, PAGE]), 'inside the image'
  end

  # Seeded fault: a check without the comparison of the record's page with
  # the executable's image releases a page of the executable.
  def test_the_check_refuses_a_record_page_in_the_image
    assert_equal 'record-image', verdict(OWN, LOADER, LOADER_SIZE), 'the first page'
    assert_equal 'record-image', verdict(OWN + OWN_SIZE - PAGE, LOADER, LOADER_SIZE), 'the last page'
    assert_equal 'record-image', verdict(MAX + 1 - PAGE, LOADER, LOADER_SIZE, own: [MAX + 1 - 2 * PAGE, 2 * PAGE]),
                 'the last page of the space'
    assert_equal 'go', verdict(MAX + 1 - PAGE, LOADER, LOADER_SIZE, own: [MAX + 1 - 2 * PAGE, PAGE]),
                 'the last page of the space, just above the image'
  end

  # Seeded fault: a check without the comparison of the record's page with
  # the loader's span releases the span and then a page of it again.
  def test_the_check_refuses_a_record_page_in_the_loader
    assert_equal 'record-loader', verdict(LOADER, LOADER, LOADER_SIZE), 'the first page'
    assert_equal 'record-loader', verdict(LOADER + LOADER_SIZE - PAGE, LOADER, LOADER_SIZE), 'the last page'
  end

  def enter(record, base, size, refuse: 0, loader: [LOADER, LOADER_SIZE])
    driver('enter', record, base, size, OWN, OWN_SIZE, *loader, refuse)
  end

  def test_a_program_erx_exec_did_not_load_releases_nothing
    assert_equal ['entered'], enter('-', LOADER, LOADER_SIZE)
    assert_equal ['entered'], enter('-', LOADER, LOADER_SIZE, loader: ['-', 0]), 'a fixed-link task'
  end

  # Seeded fault: an erx_prog_enter that leaves the release to liberx_program_main,
  # after musl's start, lets the constructor read the record.
  def test_the_span_then_the_record_are_released_before_a_constructor_runs
    assert_equal ["release #{LOADER} #{LOADER_SIZE} 0", "release #{RECORD} #{PAGE} 0", 'entered',
                  "constructor #{'dd' * 8}"], enter(RECORD, LOADER, LOADER_SIZE)
  end

  def test_a_refused_record_stops_the_program_before_any_release
    assert_equal ["stop #{RELEASE}"], enter(RECORD, LOADER + PAGE, LOADER_SIZE), 'a span other than the loader'
    assert_equal ["stop #{RELEASE}"], enter(RECORD, '-', 0), 'the record of a load that failed'
    assert_equal ["stop #{RELEASE}"], enter(RECORD + 8, LOADER, LOADER_SIZE), 'a record off its page'
    assert_equal ["stop #{RELEASE}"], enter(OWN, LOADER, LOADER_SIZE), 'a record in the image'
    assert_equal ["stop #{RELEASE}"], enter(LOADER, LOADER, LOADER_SIZE), 'a record in the loader'
    assert_equal ["stop #{RELEASE}"], enter(RECORD, LOADER, LOADER_SIZE, loader: ['-', 0]), 'a fixed-link task'
  end

  def test_a_release_the_space_refuses_stops_the_program
    assert_equal ["release #{LOADER} #{LOADER_SIZE} #{EINVAL}", "stop #{RELEASE}"],
                 enter(RECORD, LOADER, LOADER_SIZE, refuse: 1)
    assert_equal ["release #{LOADER} #{LOADER_SIZE} 0", "release #{RECORD} #{PAGE} #{EINVAL}",
                  "stop #{RELEASE}"], enter(RECORD, LOADER, LOADER_SIZE, refuse: 2)
  end
end
