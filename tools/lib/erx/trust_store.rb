# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bounded_file'
require_relative 'error'

module Erx
  # The image's trust store (docs/design-crypto.md, "The trust store"): the root
  # certificates of config/trust/, one NAME.pem per root, joined in name order into the
  # cacerts.pem that public_key's {unix, erxos} row of pubkey_os_cacerts loads. A root
  # file is taken whole or refused, naming it: at most MAX_ROOT_BYTES of ASCII holding
  # exactly one CERTIFICATE block of PEM's base64, with blank lines around it. So the
  # store holds the tree's roots and nothing else: no second certificate rides in a
  # file, and no key or other block reaches it.
  module TrustStore
    DIRECTORY = 'config/trust'
    MAX_ROOT_BYTES = 8 * 1024
    ROOT_FORM = %r{\A\n*-----BEGIN CERTIFICATE-----\n(?:[A-Za-z0-9+/=]*\n)+-----END CERTIFICATE-----\n\n*\z}

    module_function

    # The root files of directory, in name order.
    def roots(directory) = Dir.glob('*.pem', base: directory).sort.map { |name| File.join(directory, name) }

    # The store's bytes: each root file of directory, checked, in name order.
    def store(directory)
      paths = roots(directory)
      raise Error, "#{directory} holds no root certificate" if paths.empty?

      paths.map { |path| root(path) }.join
    end

    # One root file's bytes, or a refusal naming the file.
    def root(path)
      bytes = BoundedFile.read(path, maximum: MAX_ROOT_BYTES)
      raise Error, "#{path}: a root file is ASCII" unless bytes.ascii_only?
      raise Error, "#{path}: a root file is one PEM CERTIFICATE block and blank lines" unless ROOT_FORM.match?(bytes)

      bytes
    end
  end
end
