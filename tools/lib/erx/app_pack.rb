# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'tmpdir'
require_relative 'app_package'
require_relative 'bounded_file'
require_relative 'erofs_image'
require_relative 'error'

module Erx
  # `erx-app pack` (docs/design-packaging.md, "Building and packing"): an app's directory
  # into its package, NAME.app. The image holds every file below the directory's bin/
  # and share/ and below lib/APP/ebin and lib/APP/priv for each application directory APP
  # of lib/, at the same relative path, so nothing of the host's paths, owners, modes or
  # times reaches the package (Erx::ErofsImage). A name starting with '.' is left out
  # wherever it lies, so a host's own files (.DS_Store, ._NAME, editor files) never enter
  # a package; a link or a file of any other kind is refused. The salt is the image's
  # SHA-256, so the same files give the same package.
  module AppPack
    DECLARATION = 'app.txt'
    PARTS = %w[bin share].freeze
    APPLICATION_PARTS = %w[ebin priv].freeze

    module_function

    # Packs the app in directory, sealed by signer (Erx::AppPackage::Signer), into
    # output_directory/NAME.app, which a finished package replaces whole; returns its path.
    # runner runs fsimg, the build under root.
    def pack(directory:, signer:, output_directory:, runner:, root: ErofsImage::ROOT)
      declaration = declaration(directory)
      files = image_files(directory)
      check_start(declaration.start, files)
      output = File.join(File.expand_path(output_directory), "#{declaration.name}.app")
      Dir.mktmpdir('.erx-app-', File.dirname(output)) do |work|
        image = ErofsImage.new(runner: runner, root: root).write(files: files, name: "app-#{declaration.name}",
                                                                 output: File.join(work, 'image'))
        staged = File.join(work, File.basename(output))
        File.open(staged, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644) do |file|
          file.write(package(declaration, image: File.binread(image), signer: signer))
          file.fsync
        end
        File.rename(staged, output)
      end
      output
    rescue SystemCallError => error
      raise Error, "cannot write the package of #{directory}: #{error.message}"
    end

    def declaration(directory)
      path = File.join(directory, DECLARATION)
      raise Error, "#{DECLARATION} is not a regular file in #{directory}" unless kind(path) == :file

      AppPackage.parse_declaration(BoundedFile.read(path, maximum: AppPackage::DECLARATION_MAX), path: DECLARATION)
    end

    # A package's bytes: its header, zeros to the block boundary, its image and the image's
    # hash tree.
    def package(declaration, image:, signer:)
      block = AppPackage.block
      salt = Digest::SHA256.digest(image)
      tree = AppPackage.verity_tree(image, salt: salt)
      header = AppPackage.header(declaration, image_blocks: image.bytesize / block,
                                              tree_blocks: tree.bytes.bytesize / block, salt: salt,
                                              root_hash: tree.root_hash, signer: signer)
      bytes = header.ljust(((header.bytesize + block - 1) / block) * block, "\0") + image + tree.bytes
      limit = AppPackage.codec.constant('pkg_bytes_max')
      raise Error, "the package of #{declaration.name} is over #{limit} bytes" if bytes.bytesize > limit

      bytes
    end

    # Each path the image holds mapped to the host file under directory that holds it.
    def image_files(directory)
      (PARTS + application_parts(directory)).flat_map { |part| files_below(directory, part) }.to_h
    end

    # Refuses a start the image cannot serve: an application without its resource file,
    # or a program that is not a file of the image.
    def check_start(start, files)
      wanted = case start
               in AppPackage::Applications(names:) then names.map { |name| "lib/#{name}/ebin/#{name}.app" }
               in AppPackage::Program(path:) then [path]
               end
      missing = wanted.reject { |path| files.key?(path) }
      raise Error, "the app's directory has no #{missing.join(', ')}" unless missing.empty?
    end

    # The parts below lib/: ebin and priv of each application directory.
    def application_parts(directory)
      return [] unless part_kind(directory, 'lib') == :directory

      visible(File.join(directory, 'lib')).flat_map do |application|
        relative = "lib/#{application}"
        unless AppPackage::APPLICATION.match?(application) && kind(File.join(directory, relative)) == :directory
          raise Error, "#{relative} is not an application directory"
        end

        APPLICATION_PARTS.map { |part| "#{relative}/#{part}" }
      end
    end

    # [relative path, host path] of each file below part, which is a directory or absent,
    # walked without recursion.
    def files_below(directory, part)
      return [] unless part_kind(directory, part) == :directory

      pending = [part]
      found = []
      until pending.empty?
        relative = pending.pop
        host = File.join(directory, relative)
        case kind(host)
        when :directory then pending.concat(visible(host).map { |name| "#{relative}/#{name}" })
        when :file then found << [relative, host]
        end
      end
      found
    end

    def part_kind(directory, part)
      kind(File.join(directory, part)).tap do |found|
        raise Error, "#{part} is not a directory" if found == :file
      end
    end

    # A directory's names but those starting with '.', sorted.
    def visible(directory) = Dir.children(directory).reject { |name| name.start_with?('.') }.sort

    # :file, :directory or :absent for path, which is not followed if a link; a link or
    # any other kind of file raises the refusal.
    def kind(path)
      stat = File.lstat(path)
      return :directory if stat.directory?
      return :file if stat.file?

      raise Error, "#{path} is #{stat.symlink? ? 'a link' : 'neither a regular file nor a directory'}; a package holds neither"
    rescue Errno::ENOENT
      :absent
    end

    private_class_method :application_parts, :files_below, :part_kind, :visible, :kind
  end
end
