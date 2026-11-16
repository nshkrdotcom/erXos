# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'

# The root's decision on an exception Fiasco reports for a task's thread
# (liberx/backend/fiasco/arch/aarch64/exception.c), on the host: an SError
# taken in user mode becomes a fault of kind async_error, and nothing else
# does. QEMU virt raises no SError a test can provoke, so this decision is
# what a test reaches; Fiasco's entry that delivers the SError is not.
class FiascoExceptionTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'liberx/backend/fiasco/arch/aarch64/exception.c'
  DRIVER = 'test/fixtures/fiasco_exception_driver.c'

  def setup = @directory = Dir.mktmpdir('erx-fiasco-exception-')
  def teardown = FileUtils.remove_entry(@directory)

  def run_driver(core)
    output = File.join(@directory, 'driver')
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                                  *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'), '-I', ROOT,
                                  core, File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    Open3.capture2e(output, stdin_data: '')
  end

  def test_only_an_serror_is_an_async_error
    log, status = run_driver(File.join(ROOT, CORE))
    assert status.success?, log
    assert_equal "ok\n", log
  end

  def test_seed_every_exception_undefined
    source = File.read(File.join(ROOT, CORE))
    original = 'class == EXCEPTION_CLASS_SERROR ? ERX_FAULT_ASYNC_ERROR : ERX_FAULT_UNDEFINED'
    assert_includes source, original, 'the seed no longer applies'
    seeded = File.join(@directory, File.basename(CORE))
    File.write(seeded, source.sub(original, original.sub('ERX_FAULT_ASYNC_ERROR', 'ERX_FAULT_UNDEFINED')))
    log, status = run_driver(seeded)
    refute status.success?, log
    assert_includes log, 'class 0x2f'
  end
end
