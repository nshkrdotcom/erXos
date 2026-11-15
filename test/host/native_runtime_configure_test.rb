# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/native_jit_runtime'

# When the native runtimes' copies of OTP start again from configure: the configure
# stamp names the sysroot's header tree, whose name follows its content
# (Musl#merge_headers). OTP's make dependencies leave out the sysroot's headers, as
# system headers, so without that an object compiled against an earlier errno or
# signal number would be linked as if current.
class NativeRuntimeConfigureTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PLATFORM = Erx::Platform.development(ROOT)

  def setup = @root = Dir.mktmpdir('native-runtime-configure-')
  def teardown = FileUtils.rm_rf(@root)

  def test_a_changed_sysroot_header_changes_the_configure_stamp
    before = stamp(merge('#define EAGAIN 11'))

    refute_equal before, stamp(merge('#define EAGAIN 35'))
  end

  # The JIT's stamp builds on the interpreter's, with libc++'s configuration beside it;
  # its build finds the tree the interpreter's merged.
  def test_a_changed_sysroot_header_changes_the_jit_configure_stamp
    merge('#define EAGAIN 11')
    before = stamp(jit_headers, kind: Erx::NativeJitRuntime)
    merge('#define EAGAIN 35')

    refute_equal before, stamp(jit_headers, kind: Erx::NativeJitRuntime)
  end

  # Musl#merge_headers copies every header again on each build; only the bytes count.
  def test_rewritten_identical_headers_keep_the_configure_stamp
    before = stamp(merge('#define EAGAIN 35'))
    source = File.join(@root, 'musl/include/bits/errno.h')
    File.utime(Time.at(0), Time.at(0), source)

    assert_equal before, stamp(merge('#define EAGAIN 35'))
  end

  private

  def sysroot = File.join(@root, Erx::NativeRuntime::SYSROOT)
  def jit_headers = Erx::Musl.headers(sysroot)

  # Writes text as musl's own bits/errno.h and merges the sysroot's headers, as the
  # interpreter's build does; returns the tree.
  def merge(text)
    source = File.join(@root, 'musl/include/bits/errno.h')
    FileUtils.mkdir_p(File.dirname(source))
    File.write(source, text)
    Erx::Musl.new(root: @root, runner: nil, compiler: '/nonexistent/clang')
             .merge_headers(directory: File.join(@root, 'musl-build'), sysroot: sysroot)
  end

  # The stamp copy_sources records for a runtime of kind over this root, whose build
  # took headers as the sysroot's tree. A JIT runtime's libc++ is set by its build; a
  # stand-in configuration takes its place.
  def stamp(headers, kind: Erx::NativeRuntime)
    runtime = kind.new(root: @root, runner: nil, compiler: '/nonexistent/clang', linker: '/nonexistent/ld.lld',
                       fiasco: nil, platform: PLATFORM, oracle: nil)
    runtime.instance_variable_set(:@headers, headers)
    runtime.instance_variable_set(:@libcxx, Erx::Libcxx::Built.new(include: '', archives: [], configuration: 'libc++'))
    Erx::Runtime.configure_stamp(otp: @root, inputs: [], sdk_root: runtime.send(:sdk_root))
  end
end
