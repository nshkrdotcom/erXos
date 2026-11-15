# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'error'

module Erx
  # The directory a development key lives in, the login pair's (Erx::DevKey) or the
  # package key's (Erx::PackageKey): a directory of mode 0700 whose private key file is
  # of mode 0600, both the user's own. Its paths reach a caller only through checked and
  # private_file, which refuse a link, another user's entry, or one others may reach.
  #
  # ensure makes a missing directory whole or not at all: its block writes the key files
  # into a fresh owner-only directory beside it, which is then renamed into place, so no
  # half-made key is ever in place, and of two builds racing one wins and the other's
  # fresh directory is removed. A build killed part-way leaves only its fresh directory,
  # owner-only, beside the place.
  module KeyDirectory
    module_function

    # directory, checked, made by make(fresh) first when it does not exist. Directories
    # created on the way to it are of mode 0700.
    def ensure(directory, what:, &make)
      create(directory, &make) unless File.exist?(directory)
      checked(directory, what: what)
    rescue SystemCallError => e
      raise Error, "cannot make #{what} directory #{directory}: #{e.message}"
    end

    # directory, refused unless it is an owner-only directory.
    def checked(directory, what:)
      raise Error, "#{what} directory #{directory} is not an owner-only directory" unless owner_only?(directory, directory: true)

      directory
    end

    # The path of the private key file name in the checked directory, refused unless it is
    # an owner-only regular file.
    def private_file(directory, name, what:)
      path = File.join(directory, name)
      raise Error, "#{what} #{path} is not an owner-only regular file" unless owner_only?(path, directory: false)

      path
    end

    def create(directory, &make)
      parent = File.dirname(directory)
      FileUtils.mkdir_p(parent, mode: 0o700)
      fresh = Dir.mktmpdir(".#{File.basename(directory)}-", parent)
      begin
        make.call(fresh)
        begin
          File.rename(fresh, directory)
        rescue Errno::EEXIST, Errno::ENOTEMPTY
          nil # Another build's directory took the place first; the caller reads it.
        end
      ensure
        FileUtils.rm_rf(fresh)
      end
    end
    private_class_method :create

    def owner_only?(path, directory:)
      stat = File.lstat(path)
      kind = directory ? stat.directory? : stat.file?
      kind && stat.uid == Process.uid && stat.mode.nobits?(0o077)
    rescue SystemCallError
      false
    end
    private_class_method :owner_only?
  end
end
