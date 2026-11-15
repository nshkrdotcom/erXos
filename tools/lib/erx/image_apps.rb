# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'openssl'
require_relative 'abi_source'
require_relative 'app_pack'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'manifest_frontend'

module Erx
  # The packages an image builder adds to an image (docs/design-packaging.md, "Adding an
  # app to an image"), as the rows and files the image takes: for each package NAME.app,
  # the file at pkg/NAME.app of the release (on the stopgap, the boot image's domain
  # release, "Where a package lies"), a `package NAME` row whose input is the package's
  # artifact and whose enable is YES only when the builder enables it, a `signer` row for
  # each key the builder names (--signer). The builder's development package key, which a
  # development image trusts, is the build context's, never a source row.
  #
  # The board's manifest source is never edited: the rows are appended to the image's
  # copy, and the manifest check (property 19's fifth clause) binds each to its artifact,
  # whose header SHA-256 the build's file check found (AppPack.describe), so a package of
  # the image is trusted by that hash whoever signed it, the builder's key included. The
  # image judges each package's license as it judges an archive's (ProductionImage's
  # package receipts), so the license the package declares decides whether it may enter.
  module ImageApps
    RELEASE_DIRECTORY = 'pkg'
    ARTIFACT_KIND = 'package'
    DEVELOPMENT_SIGNER = 'development'
    KEY_BYTES = 32
    # The most bytes of a signer's key file; a PEM Ed25519 public key takes about 115.
    KEY_FILE_MAX = 16 * 1024

    # A package an image carries: its file, by absolute path, and what the file check
    # found in it (AppPack::Described). Its name is an app name, so no name it carries
    # spells another manifest row.
    Package = Data.define(:path, :name, :memory, :sha256, :license) do
      def initialize(path:, name:, memory:, sha256:, license:)
        raise Error, "#{name.inspect} is not an app name" unless AppPackage::APPLICATION.match?(name)

        super(path: File.expand_path(path), name: name, memory: memory, sha256: sha256, license: license)
      end

      # Where the package lies in its release, and its artifact's name.
      def entry_path = "#{RELEASE_DIRECTORY}/#{name}.app"
      def artifact_name = "#{ARTIFACT_KIND}-#{name}"
    end

    # A key the image trusts for packages installed later: a `signer NAME` row with its
    # 32-byte Ed25519 public key. Its name is a manifest identifier, so it spells no other
    # row.
    Signer = Data.define(:name, :key) do
      def initialize(name:, key:)
        raise Error, "#{name.inspect} is not a signer name" unless Manifest::Frontend::IDENTIFIER.match?(name)
        raise Error, "signer #{name}'s key is not an Ed25519 public key" unless key.is_a?(String) && key.bytesize == KEY_BYTES

        super(name: name, key: key.b.freeze)
      end
    end

    # What the image takes for its packages, each in name order, and the manifest
    # source text appended to the board's: the package rows, then the signer rows.
    Plan = Data.define(:packages, :rows) do
      # Each release-relative path mapped to the package file that lies there.
      def entries = packages.to_h { |package| [package.entry_path, package.path] }

      # Each package's artifact for the manifest check (Manifest's check_packages) by
      # name, naming its entry in the archive's sorted paths, where the release whose
      # paths begin with prefix holds it.
      def artifacts(paths, prefix:)
        packages.to_h do |package|
          entry = paths.index("#{prefix}#{package.entry_path}".b)
          raise Error, "the archive holds no entry for package #{package.name}" unless entry

          [package.artifact_name, { 'kind' => ARTIFACT_KIND, 'name' => package.name, 'memory' => package.memory,
                                    'sha256' => package.sha256.unpack1('H*'), 'entry' => entry }.freeze]
        end
      end
    end

    module_function

    # The packages of sources, each an app directory, which AppPack.pack packs with sdk
    # and signer into the directory into, or a package file, copied there as it is: the
    # image takes the copy in the build tree, which nothing else writes, so the file the
    # file check described is the file the image packs. into must be empty.
    def gather(sources, into:, sdk:, signer:, runner:, root:)
      raise Error, "#{into} is not an empty directory" unless Dir.exist?(into) && Dir.empty?(into)

      sources.map do |source|
        path = if File.directory?(source)
                 AppPack.pack(directory: source, sdk: sdk, signer: signer, output_directory: into, runner: runner, root: root)
               else
                 copied(source, into)
               end
        read(path, sdk: sdk, runner: runner)
      end
    end

    # The package file at path as the image takes it, refused unless the machine's file
    # check decodes it whole under its own name (AppPack.describe).
    def read(path, sdk:, runner:)
      described = AppPack.describe(File.expand_path(path), sdk: sdk, runner: runner)
      Package.new(path: path, **described.to_h)
    end

    # The signer whose public key is the PEM file at path, named by the file's name
    # without its extension; a private key is refused, so none is read for a row, and
    # no passphrase is asked for. development is the builder's own key's name, which only
    # the build gives.
    def signer(path)
      name = File.basename(path, '.*')
      raise Error, "--signer #{path}: #{DEVELOPMENT_SIGNER} names the builder's own key" if name == DEVELOPMENT_SIGNER

      pem = BoundedFile.read(path, maximum: KEY_FILE_MAX)
      raise Error, "--signer #{path} is not a PEM public key" unless pem.start_with?('-----BEGIN PUBLIC KEY-----')

      key = OpenSSL::PKey.read(pem, '')
      raise Error, "--signer #{path} is not an Ed25519 public key" unless key.oid == 'ED25519'

      Signer.new(name: name, key: key.raw_public_key)
    rescue OpenSSL::PKey::PKeyError
      raise Error, "--signer #{path} is not a PEM public key"
    end

    # The Plan of packages (Package), each row enabled when enable names it, and a signer
    # row for each of signers. An image takes one package of a name and one signer of a
    # name, and enable names only packages it takes.
    def plan(packages, enable:, signers: [])
      refuse_twice(packages.map(&:name), 'two packages of the image are named')
      refuse_twice(signers.map(&:name), 'two signers of the image are named')
      unknown = enable - packages.map(&:name)
      raise Error, "--enable names #{unknown.join(', ')}, which no added package is" unless unknown.empty?

      sorted = packages.sort_by(&:name).freeze
      records = [*sorted.map { |package| package_record(package, enabled: enable.include?(package.name)) },
                 *signers.sort_by(&:name).map { |signer| signer_record(signer) }]
      Plan.new(packages: sorted, rows: Manifest::Frontend.records_text(records).freeze)
    end

    # The image with no packages, which adds no row.
    def none = plan([], enable: [])

    def copied(source, into)
      raise Error, "#{source} is neither an app directory nor a package file" unless File.file?(source)

      target = File.join(into, File.basename(source))
      File.open(source, 'rb') do |input|
        File.open(target, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644) { |output| IO.copy_stream(input, output) }
      end
      target
    rescue SystemCallError => error
      raise Error, "cannot take the package #{source}: #{error.message}"
    end

    def refuse_twice(names, what)
      twice = names.tally.select { |_name, count| count > 1 }.keys
      raise Error, "#{what} #{twice.join(', ')}" unless twice.empty?
    end

    def package_record(package, enabled:)
      record('package', package.name, 'input' => "@artifact.#{package.artifact_name}", 'enable' => enabled ? 'YES' : 'NO')
    end

    def signer_record(signer) = record('signer', signer.name, 'key' => "hex:#{signer.key.unpack1('H*')}")

    # A manifest record of kind and name whose fields each hold one unquoted token.
    def record(kind, name, fields)
      Manifest::Record.new(kind: kind, name: name, parameters: [].freeze, line: nil,
                                     properties: fields.transform_values { |value| [ABI::Token.new(value: value, quoted: false)].freeze })
    end

    private_class_method :copied, :refuse_twice, :package_record, :signer_record, :record
  end
end
