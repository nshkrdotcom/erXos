# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'build_facts'
require_relative 'error'
require_relative 'json_input'
require_relative 'source_revision'

module Erx
  # An image's build record, image.boot.receipt.json beside the image.boot that the
  # website's image build (`tools/erx boot --without-web`, InteractiveBoot) alone writes
  # (ProductionImage#build's record:), and the website's check of it
  # (docs/design-packaging.md, "Adding an app to an image"):
  #
  #   { "version": 1, "kind": "image",
  #     "artifact": { "path": "image.boot", "sha256": "..." },
  #     "source": { "commit": "<40 hex>", "dirty": false },
  #     "build_facts": { "revision": "n1234-5e45e725588e", "date": "1794163353",
  #                      "configuration": "qemu-virt/development", "kernel": "fiasco-50bbe8a98119" },
  #     "packages": [{ "path": "apps/NAME.app", "sha256": "..." }] }
  #
  # source is the commit the tree was at and whether it differed from it (null for a tree
  # that is no checkout), read once with the revision the build facts name; build_facts is
  # the image's own build-facts file, fact by fact (BuildFacts.texts), so a local test
  # image's record says local as uname -i on its machine does; packages are the packages
  # the image carries. No other image build writes one, so the website takes no other
  # image: not a test image, a development image or one with a login key.
  #
  # The record is not signed. It keeps a local test image, or one that carries a package,
  # from being published by mistake; whoever publishes the site is trusted not to forge one.
  module ImageRecord
    IMAGE = 'image.boot'
    # A record is well under a kilobyte; anything far larger is not one.
    MAX_BYTES = 64 * 1024

    module_function

    # The record of the image whose SHA-256 is sha256, built from revision (a
    # SourceRevision::Revision, or nil) with facts (BuildFacts::Facts), carrying packages,
    # each { 'path' => its archive path, 'sha256' => its file's SHA-256 }.
    def of(sha256:, revision:, facts:, packages:)
      { 'version' => 1, 'kind' => 'image',
        'artifact' => { 'path' => IMAGE, 'sha256' => sha256 },
        'source' => revision && { 'commit' => revision.commit, 'dirty' => revision.dirty },
        'build_facts' => BuildFacts.texts(facts),
        'packages' => packages }
    end

    # Where image's record lies: beside it, its name with .receipt.json added.
    def path(image) = "#{image}.receipt.json"

    # Writes image's record (of) at path(image) and returns that path. image is a checked
    # image.boot.
    def write(image:, revision:, facts:, packages:)
      path = path(image)
      record = of(sha256: Digest::SHA256.file(image).hexdigest, revision: revision, facts: facts, packages: packages)
      File.write(path, "#{JSON.pretty_generate(record)}\n")
      path
    end

    # The record parsed from bytes, once it names sha256 as its image's, commit as the one
    # the image was built from with no changes, a configuration that is not a local test
    # image's, and no package; anything else raises Erx::Error. The website checks the
    # image it publishes with it (Site.inventory). An error names no value of the record
    # but a configuration of the shape uname shows, which is printable ASCII.
    def check(bytes, sha256:, commit:)
      record = JsonInput.parse(bytes, max_bytes: MAX_BYTES, label: "the image's build record")
      raise Error, "the image's build record is not one of version 1 of an image's" unless
        record.is_a?(Hash) && record['version'] == 1 && record['kind'] == 'image'
      unless record['artifact'] == { 'path' => IMAGE, 'sha256' => sha256 }
        raise Error, "the image's build record is not of this image, #{IMAGE} with SHA-256 #{sha256}"
      end
      unless record['source'] == { 'commit' => commit, 'dirty' => false }
        raise Error, "the image's build record does not name #{commit}, with no changes, as the source it was built from"
      end

      check_configuration(record['build_facts'])
      raise Error, "the image's build record lists packages, and the website offers no image that carries one" unless
        record['packages'] == []

      record
    end

    def check_configuration(facts)
      configuration = facts['configuration'] if facts.is_a?(Hash)
      unless configuration.is_a?(String) && BuildFacts::SHAPES.fetch(:configuration).match?(configuration)
        raise Error, "the image's build record names no configuration of the shape its build facts take"
      end
      return unless BuildFacts.local?(configuration)

      raise Error, "the image's build record names the configuration #{configuration}, a local test image's, " \
                   'which never leaves the host that built it'
    end
    private_class_method :check_configuration
  end
end
