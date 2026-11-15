# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/native_jit_runtime'

# When the native runtimes' copies of OTP start again from configure: the configure
# stamp keys the sysroot's headers by content. OTP's make dependencies leave out the
# sysroot's headers, as system headers, so without the key an object compiled against
# an earlier errno or signal number would be linked as if current.
class NativeRuntimeConfigureTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PLATFORM = Erx::Platform.development(ROOT)

  def setup = @root = Dir.mktmpdir('native-runtime-configure-')
  def teardown = FileUtils.rm_rf(@root)

  def test_a_changed_sysroot_header_changes_the_configure_stamp
    write_header('#define EAGAIN 11')
    before = stamp
    write_header('#define EAGAIN 35')

    refute_equal before, stamp
  end

  # The JIT's stamp builds on the interpreter's, with libc++'s configuration beside it.
  def test_a_changed_sysroot_header_changes_the_jit_configure_stamp
    write_header('#define EAGAIN 11')
    before = stamp(Erx::NativeJitRuntime)
    write_header('#define EAGAIN 35')

    refute_equal before, stamp(Erx::NativeJitRuntime)
  end

  # Musl#merge_headers copies every header again on each build, keeping its source's
  # time; only the bytes count.
  def test_rewritten_identical_headers_keep_the_configure_stamp
    write_header('#define EAGAIN 35')
    before = stamp
    write_header('#define EAGAIN 35')
    File.utime(Time.at(0), Time.at(0), header_path)

    assert_equal before, stamp
  end

  private

  def header_path = File.join(@root, Erx::NativeRoot::LIBC_HEADERS, 'bits/errno.h')

  def write_header(text)
    FileUtils.mkdir_p(File.dirname(header_path))
    File.write(header_path, text)
  end

  # The stamp copy_sources records for a runtime of kind over this root. A JIT
  # runtime's libc++ is set by its build; a stand-in configuration takes its place.
  def stamp(kind = Erx::NativeRuntime)
    runtime = kind.new(root: @root, runner: nil, compiler: '/nonexistent/clang', linker: '/nonexistent/ld.lld',
                       fiasco: nil, platform: PLATFORM, oracle: nil)
    runtime.instance_variable_set(:@libcxx, Erx::Libcxx::Built.new(include: '', archives: [], configuration: 'libc++'))
    Erx::Runtime.configure_stamp(otp: @root, inputs: [], sdk_root: runtime.send(:sdk_root))
  end
end
