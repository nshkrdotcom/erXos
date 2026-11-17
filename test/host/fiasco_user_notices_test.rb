# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/fiasco'

# The notices L4Re's user libraries ship under, in every image and in the SDK:
# the package's declaration, the license's permission text and the copyright
# notices of the files each library is compiled from.
class FiascoUserNoticesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__).freeze

  def profile = Erx::ImportNotices.parse(File.binread(File.join(ROOT, Erx::ImportNotices::PROFILE)))

  def test_each_library_carries_its_license_text_and_copyright_notices
    fiasco = Erx::Fiasco.new(root: ROOT)
    Erx::Fiasco::USER_LIBRARIES.each_key do |name|
      notices = fiasco.user_library_notices(name)
      assert_includes notices, 'fiasco/l4re-core/LICENSE.spdx', name
      assert_includes notices, 'otp/LICENSES/MIT.txt', name
      copyrights = File.read(File.join(ROOT, notices.last))
      assert_match(/\(c\) 2007-2009 Author\(s\)/, copyrights, name)
      assert_match(/Adam Lackorzynski/, copyrights, name)
    end
    sigma0 = File.read(File.join(ROOT, fiasco.user_library_notices('libsigma0.a').last))
    assert_match(/Frank Mehnert/, sigma0)
    l4sys = File.read(File.join(ROOT, fiasco.user_library_notices('libl4sys.p.a').last))
    # A copyright after a preprocessor line (debugger.h), and a second copyright block
    # after a first (__typeinfo.h), are both kept.
    assert_match(/\(c\) 2008-2011 Adam Lackorzynski/, l4sys)
    assert_match(/\(c\) 2010 Alexander Warg/, l4sys)
  end

  # Fills tree with links to the source tree's entries, with no build directory of its own.
  def tree_without_build(tree)
    Dir.children(ROOT).reject { it == 'build' }.each { File.symlink(File.join(ROOT, it), File.join(tree, it)) }
  end

  # Seeded fault: a file where the notices directory goes. A file system that ignores
  # case, as macOS's does, takes a file build/fiasco/NOTICES for build/fiasco/notices;
  # the build stops with a diagnostic naming the file as it is spelled on disk, not
  # with a bare "File exists" for a path that looks absent. Where case matters, the
  # file is another name and the notices are written beside it.
  def test_a_file_where_the_notices_go_is_named
    Dir.mktmpdir do |tree|
      tree_without_build(tree)
      FileUtils.mkdir_p(File.join(tree, 'build/fiasco'))
      File.write(File.join(tree, 'build/fiasco/NOTICES'), 'kept')
      fiasco = Erx::Fiasco.new(root: tree)
      if File.exist?(File.join(tree, 'build/fiasco/notices'))
        error = assert_raises(Erx::Error) { fiasco.user_library_notices('libsigma0.a') }
        assert_match(%r{build/fiasco/NOTICES \(type file\) is not a directory}, error.message)
      else
        assert_includes fiasco.user_library_notices('libsigma0.a'), 'build/fiasco/notices/libsigma0.a.copyright'
      end
      assert_equal 'kept', File.read(File.join(tree, 'build/fiasco/NOTICES'))
    end
  end

  # Seeded fault: a source directory that does not exist, as a typo in USER_LIBRARIES
  # or a renamed import would give, fails instead of shipping a notice with no holders.
  def test_a_missing_source_directory_fails
    error = assert_raises(Erx::Error) { Erx::Fiasco.source_copyrights('fiasco/l4re-core/l4sys/absent', root: ROOT) }
    assert_match(/states no copyright/, error.message)
  end

  # Seeded fault: a profile with no text for MIT. The library's notice would lack the
  # license's permission text, so the build stops.
  def test_a_license_without_permission_text_fails
    seeded = profile.merge('licenses' => profile.fetch('licenses').except('MIT'))
    error = assert_raises(Erx::Error) { Erx::Fiasco.user_license_notices('libl4sys.p.a', profile: seeded, root: ROOT) }
    assert_match(/libl4sys\.p\.a.*MIT/, error.message)
  end

  # Seeded fault: a license text whose bytes differ from the profile's pin.
  def test_a_changed_license_text_fails
    licenses = profile.fetch('licenses').merge('MIT' => [{ 'path' => 'otp/LICENSES/MIT.txt', 'sha256' => '0' * 64 }])
    error = assert_raises(Erx::Error) do
      Erx::Fiasco.user_license_notices('libsigma0.a', profile: profile.merge('licenses' => licenses), root: ROOT)
    end
    assert_match(%r{otp/LICENSES/MIT\.txt differs}, error.message)
  end
end
