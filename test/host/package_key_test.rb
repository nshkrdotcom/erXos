# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/package_key'

# The development package key (docs/design-packaging.md, "The SDK"): made on first use
# under the user's home directory, owner-only, kept once made, and refused when others
# may read it or its directory.
class PackageKeyTest < Minitest::Test
  def test_the_key_is_made_once_and_kept_owner_only
    Dir.mktmpdir('erx-package-key-') do |home|
      File.chmod(0o755, home)
      directory = Erx::PackageKey.directory(home: home)
      assert_equal File.join(home, '.erxos/package-key'), directory
      signer = Erx::PackageKey.ensure(directory: directory)
      path = File.join(directory, Erx::PackageKey::KEY)
      assert_equal [0o700, 0o700, 0o600], [File.dirname(directory), directory, path].map { File.stat(it).mode & 0o777 }
      text = File.binread(path)
      assert_equal signer.public_key, Erx::PackageKey.ensure(directory: directory).public_key
      assert_equal text, File.binread(path)
      assert_equal %w[package-key], Dir.children(File.dirname(directory))
      File.chmod(0o644, path)
      error = assert_raises(Erx::Error) { Erx::PackageKey.ensure(directory: directory) }
      assert_match(/not an owner-only regular file/, error.message)
      File.chmod(0o600, path)
      File.chmod(0o755, directory)
      error = assert_raises(Erx::Error) { Erx::PackageKey.ensure(directory: directory) }
      assert_match(/not an owner-only directory/, error.message)
    end
  end

  def test_a_link_in_place_of_the_key_is_refused
    Dir.mktmpdir('erx-package-key-') do |home|
      directory = Erx::PackageKey.directory(home: home)
      Erx::PackageKey.ensure(directory: directory)
      path = File.join(directory, Erx::PackageKey::KEY)
      File.rename(path, File.join(home, 'elsewhere.key'))
      File.symlink(File.join(home, 'elsewhere.key'), path)
      error = assert_raises(Erx::Error) { Erx::PackageKey.ensure(directory: directory) }
      assert_match(/not an owner-only regular file/, error.message)
    end
  end
end
