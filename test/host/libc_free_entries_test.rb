# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require_relative '../../tools/lib/erx/dependencies'
require_relative '../../tools/lib/erx/native_task'
require_relative '../../tools/lib/erx/native_musl'

# The entries that start no processes read none of musl's headers, which only the runtime's
# build makes (NativeRoot::LIBC_HEADERS): libc-test's tasks and the native_musl root link
# two of them, and both build in a tree that never built the runtime.
class LibcFreeEntriesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  ENTRIES = %w[libc_root_write.c libc_task.c domain_entry.c].map { |name| "#{Erx::NativeRoot::BACKEND}/#{name}" }.freeze

  def test_libc_test_and_native_musl_compile_no_source_that_reads_musls_headers
    assert_empty((Erx::NativeRoot::LIBC_TASK + Erx::NativeMusl::SOURCES) & Erx::NativeRoot::LIBC_SOURCES)
  end

  # Each entry compiles with the flags NativeRoot gives a source outside LIBC_SOURCES.
  def test_each_entry_compiles_without_musls_headers
    compiler = ENV.fetch('ERX_CLANG', '')
    skip('set ERX_CLANG') if compiler.empty?
    headers = Erx::Fiasco.new(root: ROOT).user_include_directories
    built = headers.any? { |path| Dir.exist?(path) } && Dir.exist?(File.join(ROOT, 'build/gen/include'))
    skip('build Fiasco and the generated headers first') unless built

    ENTRIES.each do |entry|
      said, status = Open3.capture2e(compiler, *Erx::NativeRoot::FLAGS, *headers.flat_map { |path| ['-isystem', path] },
                                     '-fsyntax-only', entry, chdir: ROOT)
      assert(status.success?, "#{entry}: #{said}")
    end
  end
end
