# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/musl'

# Musl#merge_headers names the sysroot's header tree by its content, which is what
# lets every native build step follow a changed musl or ABI header through the include
# path it already keys on. A fault that drops the digest from the name leaves the path
# unchanged and fails the first test.
class MuslHeadersTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('musl-headers-')
    @sysroot = File.join(@root, 'sysroot')
  end

  def teardown = FileUtils.rm_rf(@root)

  def test_a_changed_header_names_a_new_tree_and_removes_the_old
    old = merge('#define EAGAIN 11')
    new = merge('#define EAGAIN 35')

    refute_equal old, new
    refute File.exist?(old)
    assert_equal '#define EAGAIN 35', File.read(File.join(new, 'bits/errno.h'))
    assert_equal new, Erx::Musl.headers(@sysroot)
  end

  # Only the bytes count: a header copied again with a new time keeps the tree, and the
  # tree keeps the times it had.
  def test_identical_headers_keep_the_tree
    tree = merge('#define EAGAIN 35')
    File.utime(Time.at(0), Time.at(0), File.join(tree, 'bits/errno.h'))

    assert_equal tree, merge('#define EAGAIN 35')
    assert_equal Time.at(0), File.mtime(File.join(tree, 'bits/errno.h'))
  end

  # The first directory searched wins: musl's build's obj/include over its include/.
  def test_an_earlier_layer_wins
    write('musl-build/obj/include/bits/errno.h', '#define EAGAIN 35')
    tree = merge('#define EAGAIN 11')

    assert_equal '#define EAGAIN 35', File.read(File.join(tree, 'bits/errno.h'))
  end

# A tree whose content no longer matches its name, such as one a removal left half
# done, is merged again rather than trusted.
def test_a_tree_that_lost_files_is_merged_again
  tree = merge('#define EAGAIN 35')
  File.delete(File.join(tree, 'bits/errno.h'))

  assert_equal tree, merge('#define EAGAIN 35')
  assert_equal '#define EAGAIN 35', File.read(File.join(tree, 'bits/errno.h'))
end

# Every other header tree, and an interrupted merge's staging tree, are removed, so
# the one tree left is the one merged.
def test_other_header_trees_are_removed
  FileUtils.mkdir_p([File.join(@sysroot, 'include-0000000000000000'), File.join(@sysroot, Erx::Musl::HEADERS_STAGING),
                     File.join(@sysroot, 'lib')])
  tree = merge('#define EAGAIN 35')

  assert_equal [File.basename(tree), 'lib'], Dir.children(@sysroot).sort
end

  def test_a_sysroot_without_one_tree_is_refused
    assert_raises(Erx::Error) { Erx::Musl.headers(@sysroot) }
    FileUtils.mkdir_p([File.join(@sysroot, 'include-0000000000000000'), File.join(@sysroot, 'include-1111111111111111')])
    assert_raises(Erx::Error) { Erx::Musl.headers(@sysroot) }
  end

  private

  def write(path, text)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  # Writes text as musl's own bits/errno.h and merges the layers into the sysroot.
  def merge(text)
    write('musl/include/bits/errno.h', text)
    Erx::Musl.new(root: @root, runner: nil, compiler: '/nonexistent/clang')
             .merge_headers(directory: File.join(@root, 'musl-build'), sysroot: @sysroot)
  end
end
