# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'openssl'
require_relative 'app_package'
require_relative 'error'
require_relative 'key_directory'

module Erx
  # The development package key (docs/design-packaging.md, "The SDK"): the Ed25519 key
  # the packer signs a package with when it is given no other, and whose public half a
  # development image trusts when the same host builds it. It is a key of its own, never
  # the development login key or an update-signing key, so a package's seal can stand for
  # nothing else.
  #
  # There is one key per user and host, which the packer makes the first time it needs
  # one, in DIRECTORY under the user's home directory and so outside every tree, SDK and
  # image: no export copies it, and an SDK handed to someone else carries no key, so
  # their packages are trusted only by the images they build themselves. The key is a PEM
  # file of mode 0600 in a directory of mode 0700, both the user's own (Erx::KeyDirectory),
  # and it never enters an SDK, an image, a receipt or a log.
  module PackageKey
    DIRECTORY = '.erxos/package-key'
    KEY = 'development.key'
    WHAT = 'the development package key'

    module_function

    # The key's directory for the user whose home directory is home, the current user's
    # when nil.
    def directory(home: nil)
      File.join(home || Dir.home, DIRECTORY)
    rescue ArgumentError => e
      raise Error, "no home directory for the development package key: #{e.message}"
    end

    # The key in directory as an AppPackage::Signer, made first when there is none. It is
    # refused unless the directory and the key are the user's alone (Erx::KeyDirectory)
    # and the key is an Ed25519 private key. Tests pass a directory of their own, so no
    # test writes a key into the user's home.
    def ensure(directory: self.directory)
      KeyDirectory.ensure(directory, what: WHAT) do |fresh|
        File.open(File.join(fresh, KEY), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(OpenSSL::PKey.generate_key('ED25519').private_to_pem)
          file.fsync
        end
      end
      AppPackage::Signer.read(KeyDirectory.private_file(directory, KEY, what: WHAT))
    end
  end
end
