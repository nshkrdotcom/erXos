# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/lib/erx/no_follow'

# Opening without following a link (Erx::NoFollow): a link at the path's end is one typed
# error whichever errno the host's open(2) gives for it (ELOOP on macOS and Linux, EMLINK
# on FreeBSD), and nothing else the open or its block raises is turned into it.
class NoFollowTest < Minitest::Test
  def setup
    @scratch = Dir.mktmpdir('erx-no-follow-test-')
    @file = File.join(@scratch, 'file')
    File.write(@file, 'bytes')
  end

  def teardown
    FileUtils.rm_rf(@scratch)
  end

  def test_a_regular_file_is_yielded_and_closed_after
    opened = Erx::NoFollow.open(@file, File::RDONLY) { |file| [file.read, file] }
    assert_equal 'bytes', opened.first
    assert opened.last.closed?
  end

  def test_a_symbolic_link_is_refused_as_a_link
    link = File.join(@scratch, 'link')
    File.symlink(@file, link)
    error = assert_raises(Erx::NoFollow::Link) { Erx::NoFollow.open(link, File::RDONLY) { flunk 'opened a link' } }
    assert_equal "#{link} is a symbolic link", error.message
  end

  # The block's own errors pass unchanged, even one with the errno a link gives.
  def test_the_blocks_errors_pass_as_they_are
    assert_raises(Errno::ELOOP) { Erx::NoFollow.open(@file, File::RDONLY) { raise Errno::ELOOP } }
  end

  def test_the_opens_other_errors_pass_as_they_are
    assert_raises(Errno::ENOENT) { Erx::NoFollow.open(File.join(@scratch, 'missing'), File::RDONLY) }
  end
end
