# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
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
    assert_raises(Erx::Error) do
      Erx::Fiasco.user_license_notices('libsigma0.a', profile: profile.merge('licenses' => licenses), root: ROOT)
    end
  end
end
