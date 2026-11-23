# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require_relative '../../tools/lib/erx/dependencies'
require_relative '../../tools/lib/erx/native_irq'
require_relative '../../tools/lib/erx/native_task'
require_relative '../../tools/lib/erx/native_musl'

# The sources a native root compiles outside NativeRoot::LIBC_SOURCES read none of musl's
# headers, which only the runtime's build makes (NativeRoot::LIBC_SYSROOT):
# - the entries that start no processes, which libc-test's tasks and the native_musl root
#   link, and both build in a tree that never built the runtime;
# - the device NIF's C the native_irq root links, which ERTS's build compiles with musl's
#   headers, so only this test or that suite's build sees a C library header in it.
class LibcFreeEntriesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  ENTRIES = %w[libc_root_write.c output_line.c libc_task.c domain_entry.c].map { |name| "#{Erx::NativeRoot::BACKEND}/#{name}" }.freeze

  def test_libc_test_and_native_musl_compile_no_source_that_reads_musls_headers
    assert_empty((Erx::NativeRoot::LIBC_TASK + Erx::NativeMusl::SOURCES) & Erx::NativeRoot::LIBC_SOURCES)
  end

  def test_each_entry_compiles_without_musls_headers
    assert_compile_without_musls_headers(ENTRIES)
  end

  def test_native_irqs_device_nif_compiles_without_musls_headers
    assert_empty(Erx::NativeIrq::DEVICE_NIF & (Erx::NativeRoot::LIBC_SOURCES + Erx::NativeRoot::DEVICE_TREE))
    assert_compile_without_musls_headers(Erx::NativeIrq::DEVICE_NIF, flags: Erx::NativeIrq::DEVICE_NIF_FLAGS)
  end

  private

  # Each source compiles with the flags NativeRoot gives a source outside LIBC_SOURCES, and
  # the flags the caller adds to every source of the root it links into.
  def assert_compile_without_musls_headers(sources, flags: [])
    compiler = ENV.fetch('ERX_CLANG', '')
    skip('set ERX_CLANG') if compiler.empty?
    headers = Erx::Fiasco.new(root: ROOT).user_include_directories
    built = headers.any? { |path| Dir.exist?(path) } && Dir.exist?(File.join(ROOT, 'build/gen/include'))
    skip('build Fiasco and the generated headers first') unless built

    sources.each do |source|
      said, status = Open3.capture2e(compiler, *Erx::NativeRoot::FLAGS, *flags, *headers.flat_map { |path| ['-isystem', path] },
                                     '-fsyntax-only', source, chdir: ROOT)
      assert(status.success?, "#{source}: #{said}")
    end
  end
end
