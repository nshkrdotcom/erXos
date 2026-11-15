# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'openssl'
require 'tmpdir'
require_relative '../../tools/lib/erx/app_pack'

# The packer's refusals before it writes anything (Erx::AppPackage, Erx::AppPack): app.txt's
# parser, the walk of an app's directory and the signing key's reader. The packages it
# writes are judged by test/host/erx_pkg_header_test.rb.
class ErxAppPackTest < Minitest::Test
  Package = Erx::AppPackage

  def parse(text) = Package.parse_declaration(text, path: 'app.txt')

  def test_a_declaration_parses_with_its_defaults
    declaration = parse("app doom\n  needs display\n  program \"bin/doom\" \"-iwad\" \"/app/share/freedoom1.wad\"\n")
    assert_equal Package::Declaration.new(name: 'doom', needs: %w[display],
                                          start: Package::Program.new(path: 'bin/doom', args: %w[-iwad /app/share/freedoom1.wad]),
                                          license: '', memory: Package.codec.constant('app_memory_default'), version: 1),
                 declaration
  end

  def test_a_malformed_declaration_is_refused
    { "app x\n  applications x\n  program \"bin/x\"\n" => /exactly one of applications and program/,
      "app x\n" => /exactly one of applications and program/,
      "app x\n  applications x\n  env \"A=1\"\n" => /unknown field env/,
      "app x\n  applications x\n  needs a a\n" => /names a value twice/,
      "app x\n  program \"bin/x\" \"a\\x00b\"\n" => /holds no NUL/,
      "app x\n  program \"/system/bin/sh\"\n" => /path under bin/,
      "app x\n  applications x\n  memory 4194303\n" => /memory is a decimal number/,
      "app x\n  applications x\n  version 0x10\n" => /version is a decimal number/,
      "app x\n  applications x\n  license \"GPL-2.0 OR\"\n" => /not an SPDX expression/,
      "app X\n  applications x\n" => /not an app name/,
      "app x\n  applications x\napp y\n  applications y\n" => /exactly one app row/ }.each do |text, message|
      error = assert_raises(Erx::Error, text) { parse(text) }
      assert_match message, error.message, text
    end
  end

  def test_a_license_with_a_control_byte_is_refused
    error = assert_raises(Erx::Error) { parse("app x\n  applications x\n  license \"MIT\\x09OR BSD-2-Clause\"\n") }
    assert_match(/printable ASCII/, error.message)
  end

  # Dot-names are left out, so a host's own files never reach the image.
  def test_the_image_holds_the_parts_but_dot_names
    Dir.mktmpdir('erx-app-pack-test') do |work|
      write(work, 'lib/erx_x/ebin/erx_x.app' => "{application, erx_x, []}.\n", 'lib/erx_x/src/erx_x.erl' => '',
                  'share/a' => 'a', 'share/.DS_Store' => 'finder', 'lib/.DS_Store' => 'finder', 'Makefile' => '')
      assert_equal %w[lib/erx_x/ebin/erx_x.app share/a], Erx::AppPack.image_files(work).keys.sort
    end
  end

  def test_a_link_a_misshapen_part_or_a_missing_start_is_refused
    Dir.mktmpdir('erx-app-pack-test') do |work|
      write(work, 'lib/erx_x/ebin/erx_x.app' => "{application, erx_x, []}.\n", 'share/a' => 'a')
      Erx::AppPack.check_start(Package::Applications.new(names: %w[erx_x]), Erx::AppPack.image_files(work))
      error = assert_raises(Erx::Error) { Erx::AppPack.check_start(Package::Program.new(path: 'bin/x', args: []), Erx::AppPack.image_files(work)) }
      assert_match(%r{has no bin/x}, error.message)
      write(work, 'bin' => 'a file')
      assert_match(/bin is not a directory/, assert_raises(Erx::Error) { Erx::AppPack.image_files(work) }.message)
      File.delete(File.join(work, 'bin'))
      write(work, 'lib/foo-1.0/ebin/foo.app' => '')
      assert_match(/is not an application directory/, assert_raises(Erx::Error) { Erx::AppPack.image_files(work) }.message)
      FileUtils.rm_r(File.join(work, 'lib/foo-1.0'))
      File.symlink('/etc/passwd', File.join(work, 'share/passwd'))
      assert_match(/is a link/, assert_raises(Erx::Error) { Erx::AppPack.image_files(work) }.message)
    end
  end

  # The hash tree of one level over a few blocks, and of none over one block, whose root
  # hash is its block's salted hash.
  def test_the_hash_tree_of_a_small_image
    block = Package.block
    salt = "\x01".b * 32
    one = Package.verity_tree("\x07".b * block, salt: salt)
    assert_equal ['', Digest::SHA256.digest(salt + ("\x07".b * block))], [one.bytes, one.root_hash]
    image = ("\x07".b * block) + ("\x08".b * block)
    two = Package.verity_tree(image, salt: salt)
    level = (Digest::SHA256.digest(salt + ("\x07".b * block)) + Digest::SHA256.digest(salt + ("\x08".b * block))).ljust(block, "\0")
    assert_equal [level, Digest::SHA256.digest(salt + level)], [two.bytes, two.root_hash]
  end

  def test_only_an_ed25519_private_key_signs
    Dir.mktmpdir('erx-app-pack-test') do |work|
      key = OpenSSL::PKey.generate_key('ED25519')
      write(work, 'private.pem' => key.private_to_pem, 'public.pem' => key.public_to_pem,
                  'rsa.pem' => OpenSSL::PKey::RSA.new(2048).private_to_pem, 'junk.pem' => 'not a key')
      signer = Package::Signer.read(File.join(work, 'private.pem'))
      assert_equal key.raw_public_key, signer.public_key
      assert key.verify(nil, signer.sign('bytes'), 'bytes')
      %w[public.pem rsa.pem junk.pem missing.pem].each do |name|
        error = assert_raises(Erx::Error) { Package::Signer.read(File.join(work, name)) }
        assert_match(/signing key/, error.message)
      end
    end
  end

  private

  def write(directory, files)
    files.each do |path, bytes|
      FileUtils.mkdir_p(File.dirname(File.join(directory, path)))
      File.binwrite(File.join(directory, path), bytes)
    end
  end
end
