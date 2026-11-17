# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
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
  #
  # The published package key is the other key the tree packs with: an Ed25519 key whose
  # seed is the SHA-256 of PUBLISHED, so its private half is no secret, anyone may seal
  # with it, and every build of a tree seals alike. It seals the kiosk of the card the
  # website offers (ImageApps.packed_kiosk), which the card trusts by its row's hash, not
  # by a key, so two builders' cards of one commit are the same. It is never a trust
  # root: the manifest check refuses it as a signer row's key or the build's development
  # key (PackageKey.published?), and ImageApps.signer refuses it as a --signer first.
  module PackageKey
    DIRECTORY = '.erxos/package-key'
    KEY = 'development.key'
    WHAT = 'the development package key'
    PUBLISHED = 'erXos published package key: it seals what is trusted by hash, and nothing trusts it'

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

    # The published package key as an AppPackage::Signer.
    def published = AppPackage::Signer.new(OpenSSL::PKey.new_raw_private_key('ED25519', Digest::SHA256.digest(PUBLISHED)))

    # Whether key, a raw 32-byte Ed25519 public key, is the published package key's.
    def published?(key) = key.b == published.public_key.b
  end
end
