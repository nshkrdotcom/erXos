# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'app_pack'
require_relative 'error'

module Erx
  # The packages an image builder adds to an image (docs/design-packaging.md, "Adding an
  # app to an image"), as the rows and files the image takes: for each package NAME.app,
  # the file at pkg/NAME.app of the release (on the stopgap, the boot image's domain
  # release, "Where a package lies"), a `package NAME` row whose input is the package's
  # artifact and whose enable is YES only when the builder enables it. A development
  # image's trust in its builder's development package key (Erx::PackageKey) is no row:
  # the build hands the key's public half to the manifest check as its context's
  # development_key, which the check packs as its own record.
  #
  # The board's manifest source is never edited: the rows are appended to the image's
  # copy, and the manifest check (property 19's fifth clause) binds each to its artifact,
  # whose header SHA-256 the build's file check found (AppPack.describe), so a package of
  # the image is trusted by that hash whoever signed it, the builder's key included.
  module ImageApps
    # A package an image carries: its file, by absolute path, and what the file check
    # found in it. Its name is an app name, so no name it carries spells another
    # manifest row.
    Package = Data.define(:path, :name, :memory, :sha256) do
      def initialize(path:, name:, memory:, sha256:)
        raise Error, "#{name.inspect} is not an app name" unless AppPackage::APPLICATION.match?(name)

        super(path: File.expand_path(path), name: name, memory: memory, sha256: sha256)
      end
    end
    # What the image takes for its packages: entries maps each release-relative path to
    # the package file that lies there, artifacts names each package's artifact for the
    # manifest check, and rows is the manifest source text appended to the board's.
    Plan = Data.define(:entries, :artifacts, :rows)

    RELEASE_DIRECTORY = 'pkg'
    ARTIFACT_KIND = 'package'

    module_function

    # The package file at path as the image takes it, refused unless the machine's file
    # check decodes it whole under its own name (AppPack.describe).
    def read(path, sdk:, runner:)
      described = AppPack.describe(File.expand_path(path), sdk: sdk, runner: runner)
      Package.new(path: path, name: described.name, memory: described.memory, sha256: described.sha256)
    end

    # The Plan of packages (Package), each row enabled when enable names it. An image
    # takes one package of a name, and enable names only packages it takes.
    def plan(packages, enable:)
      names = packages.map(&:name)
      twice = names.tally.select { |_name, count| count > 1 }.keys
      raise Error, "two packages of the image are named #{twice.join(', ')}" unless twice.empty?
      unknown = enable - names
      raise Error, "--enable names #{unknown.join(', ')}, which no added package is" unless unknown.empty?

      sorted = packages.sort_by(&:name)
      Plan.new(entries: sorted.to_h { |package| ["#{RELEASE_DIRECTORY}/#{package.name}.app", package.path] }.freeze,
               artifacts: sorted.to_h { |package| [artifact_name(package.name), artifact(package)] }.freeze,
               rows: sorted.map { |package| package_row(package, enabled: enable.include?(package.name)) }.join.freeze)
    end

    def artifact_name(name) = "#{ARTIFACT_KIND}-#{name}"

    # The artifact the manifest check binds a package row to (Manifest's check_packages).
    def artifact(package)
      { 'kind' => ARTIFACT_KIND, 'name' => package.name, 'memory' => package.memory,
        'sha256' => package.sha256.unpack1('H*') }.freeze
    end

    def package_row(package, enabled:)
      "package #{package.name}\n  input @artifact.#{artifact_name(package.name)}\n  enable #{enabled ? 'YES' : 'NO'}\n"
    end

    private_class_method :artifact_name, :artifact, :package_row
  end
end
