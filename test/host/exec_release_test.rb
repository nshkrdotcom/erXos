# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/generated_tree'
require_relative '../../tools/lib/erx/generated_abi'
require_relative '../../tools/lib/erx/runner'

# The end of a loader's tenure (docs/design-programs.md, "The loader's
# bootstrap", Release, and Verification, "The loader's window"): the program
# layer's erx_prog_enter (liberx/program/program.c) running erx_exec_release
# (liberx/exec/release.c) over a stand-in space, through the host driver
# test/fixtures/exec_release_driver.c. The window is the ABI's
# (abi/protocols/prog.txt).
class ExecReleaseTest < Minitest::Test
  PAGE = 4096
  CODEC = Erx::ABI::Generated::CODEC
  BASE = CODEC.constant('exec_window_base')
  BYTES = CODEC.constant('exec_window_bytes')
  RECORD = CODEC.constant('exec_record_page')
  # ERX_EINVAL (abi/erx_abi.txt), the stand-in space's refusal.
  EINVAL = -1
  # ERX_PROG_STATUS_RELEASE (liberx/program/startup.h).
  RELEASE = -(1 << 32)
  # An executable's own image, beside the window: just above it, as the space
  # places one larger than the room below the window.
  ABOVE = [BASE + BYTES, 8 * PAGE].freeze

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

  def enter(exec, own, refuse: 0)
    record = @runner.run([@driver, 'enter', exec, *own, refuse].map(&:to_s), name: 'exec-release', deadline: 30)
    File.read(record.fetch('log')).lines.map(&:chomp)
  end

  def test_the_record_is_the_windows_last_page
    assert_equal BASE + BYTES - PAGE, RECORD
  end

  def test_a_program_erx_exec_did_not_load_releases_nothing
    assert_equal ['entered'], enter(0, ABOVE)
    assert_equal ['entered'], enter(0, [BASE, 8 * PAGE]), 'a fixed-link task'
  end

  # Seeded fault: an erx_prog_enter that leaves the release to liberx_program_main,
  # after musl's start, lets a constructor run while the loader is mapped.
  def test_the_whole_window_is_released_once_before_a_constructor_runs
    assert_equal ["release #{BASE} #{BYTES} 0", 'entered'], enter(RECORD, ABOVE)
    assert_equal ["release #{BASE} #{BYTES} 0", 'entered'], enter(1, [BASE - 8 * PAGE, 8 * PAGE]),
                 'an image ending where the window starts, and any exec value but 0'
  end

  # Seeded fault: a release without the comparison with the program's own image
  # releases the image of a fixed-link task whose register 7 is wrongly not 0.
  def test_a_window_that_meets_the_programs_own_image_is_refused
    [[[BASE, 8 * PAGE], 'a fixed-link task, at the window\'s base'],
     [[BASE - PAGE, 2 * PAGE], 'an image across the window\'s base'],
     [[RECORD, 2 * PAGE], 'an image across the window\'s end'],
     [[BASE + PAGE, PAGE], 'an image inside the window'],
     [[BASE - PAGE, BYTES + 2 * PAGE], 'an image around the window']].each do |own, label|
      assert_equal ["stop #{RELEASE}"], enter(RECORD, own), label
    end
  end

  def test_a_release_the_space_refuses_stops_the_program
    assert_equal ["release #{BASE} #{BYTES} #{EINVAL}", "stop #{RELEASE}"], enter(RECORD, ABOVE, refuse: 1)
  end
end
