# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'securerandom'
require 'shellwords'
require_relative 'error'
require_relative 'boot_partition'
require_relative 'bounded_file'
require_relative 'json_input'
require_relative 'no_follow'

module Erx
  # Puts a board's boot files where a TFTP server serves them, so the board's firmware
  # boots the build over the network instead of from a card (docs/design-platforms.md,
  # "Netbooting from a Mac"). The files are the boot partition's, boot/ beside the card
  # that `tools/erx pack --medium` wrote, the firmware's network boot root
  # (BootPartition); which files make the set is the card's build record's list
  # (BootPartition.listed_files), written from the same plan as the files.
  #
  # The TFTP root is a symbolic link this module owns, to a sibling directory that holds
  # one build. stage copies the set into a fresh sibling, checks every copy against the
  # record's SHA-256, and only then renames a new link over the old one, which rename(2)
  # does in one step: each file the server opens comes from one complete, checked set,
  # never from a copy in progress. The server resolves the link at each request (dnsmasq
  # 2.93's check_tftp_fileperm opens the root and the file's name afresh), so a boot that
  # runs across the moment of a swap can still read its first files from one build and
  # its later ones from the next; staging while the board is not booting avoids that.
  #
  # One stage runs at a time, under a lock file beside the link, so once the link names
  # the new sibling every other sibling of netboot's naming is stale, the previous build
  # or what an interrupted stage left, and is removed; a transfer the server has open
  # keeps reading the file it opened. Nothing at the root that netboot did not make is
  # replaced or removed, except a link, which it moves.
  module Netboot
    # The board netboot stages for when no --platform names another.
    PLATFORM = 'raspi4b'
    # Where the TFTP root lies when no --tftp names another.
    DEFAULT_ROOT = '~/erxos-tftp'
    # A staged sibling's name is the link's, a dot and STAGED_HEX random hexadecimal
    # digits (staged_path).
    STAGED_HEX = 16
    # A word the shell takes as it is, which shell_line prints unquoted.
    PLAIN_WORD = %r{\A[\w./=:@+,-]+\z}

    # What stage put in place: root, the link the server serves; directory, the sibling it
    # names; commit and dirty, the record's source (nil when the build tree was no git
    # checkout); kernel, the SHA-256 of the bootable file the firmware loads.
    Staged = Data.define(:root, :directory, :commit, :dirty, :kernel)

    module_function

    # Stages medium's boot files (medium is the production image's directory, which holds
    # BootPartition::ENTRIES) into the TFTP root root, a link this module made or a path
    # that does not exist yet; anything else at root is refused and left alone.
    def stage(medium:, root:)
      record = read_record(File.join(medium, BootPartition::RECORD))
      digests = BootPartition.listed_files(record)
      raise Error, "netboot: the build record lists no #{BootPartition::KERNEL}" unless digests.key?(BootPartition::KERNEL)

      link = File.expand_path(root)
      directory = locked(link) do
        check_link(link)
        staged = staged_path(link)
        Dir.mkdir(staged, 0o755)
        swapped = false
        begin
          copy(digests, from: File.join(medium, BootPartition::PARTITION), to: staged)
          swap(link, staged)
          swapped = true
        ensure
          FileUtils.rm_rf(staged) unless swapped
        end
        stale_siblings(link, keep: staged).each { |path| FileUtils.rm_rf(path) }
        staged
      end
      source = record['source'] || {}
      Staged.new(root: link, directory: directory, commit: source['commit'], dirty: source['dirty'],
                 kernel: digests.fetch(BootPartition::KERNEL))
    end

    # The command line that serves root over TFTP and nothing else, for the Mac's adapter
    # interface and the user and group the server drops root to after binding port 69:
    # Homebrew's dnsmasq with DNS off (port 0) and no DHCP range, so it leaves addresses
    # to Internet Sharing; --tftp-secure serves only files the user owns.
    def server_command(root:, interface:, user:, group:)
      ['sudo', '/opt/homebrew/sbin/dnsmasq', '--keep-in-foreground', '--conf-file=/dev/null', '--port=0',
       '--enable-tftp', "--tftp-root=#{root}", '--tftp-secure', "--interface=#{interface}",
       "--user=#{user}", "--group=#{group}", '--log-facility=-']
    end

    # words as one line to paste into a shell, each quoted only when the shell would not
    # take it as it is (PLAIN_WORD).
    def shell_line(words) = words.map { |word| PLAIN_WORD.match?(word) ? word : Shellwords.escape(word) }.join(' ')

    def read_record(path)
      raise Error, "netboot: no build record #{path}; pack the board's card first (tools/erx pack --medium --platform NAME)" unless
        File.file?(path)

      JsonInput.parse(BoundedFile.read(path, maximum: BootPartition::RECORD_BYTES),
                      max_bytes: BootPartition::RECORD_BYTES, label: path)
    end

    # Runs the block holding the lock file beside link, so stages never overlap.
    def locked(link)
      lock = begin
        File.open("#{link}.lock", File::WRONLY | File::CREAT, 0o644)
      rescue Errno::ENOENT
        raise Error, "netboot: #{File.dirname(link)}, where the TFTP root goes, does not exist"
      end
      lock.flock(File::LOCK_EX)
      yield
    ensure
      lock&.close
    end

    # Refuses a link that is something other than a symbolic link; a link or nothing at all
    # is what stage replaces.
    def check_link(link)
      return unless File.exist?(link) && !File.symlink?(link)

      raise Error, "netboot: #{link} is not a symbolic link; netboot keeps the TFTP root as a link to the staged build, so move it away first"
    end

    # A fresh sibling of link for one build; Dir.mkdir refuses a path that is taken.
    def staged_path(link) = "#{link}.#{SecureRandom.hex(STAGED_HEX / 2)}"

    # Every sibling of link of staged_path's naming but keep.
    def stale_siblings(link, keep:)
      name = /\A#{Regexp.escape(File.basename(link))}\.\h{#{STAGED_HEX}}\z/
      Dir.children(File.dirname(link)).select { |child| name.match?(child) }
         .map { |child| File.join(File.dirname(link), child) }.reject { |path| path == keep }
    end

    # Copies each file digests names from from into to, at most the partition's size of
    # each, then checks the copy's SHA-256 against digests', so what the server reads is
    # what the build wrote, whatever changed in from meanwhile. A name that is missing, a
    # symbolic link or no regular file is refused.
    def copy(digests, from:, to:)
      digests.each do |name, sha256|
        target = File.join(to, name)
        FileUtils.mkdir_p(File.dirname(target))
        open_listed(from, name) do |input|
          File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |output|
            IO.copy_stream(input, output, BootPartition::MAX_FILE + 1)
          end
        end
        raise Error, "netboot: #{BootPartition::PARTITION}/#{name} differs from the build record; pack the card again" unless
          Digest::SHA256.file(target).hexdigest == sha256
      end
    end

    # Opens from's file name for the block, refusing one that is missing, a symbolic link
    # or no regular file. Only the open's errors are read as the file's; the block's pass.
    def open_listed(from, name)
      place = "#{BootPartition::PARTITION}/#{name}"
      input = begin
        NoFollow.open(File.join(from, name), File::RDONLY)
      rescue Errno::ENOENT
        raise Error, "netboot: #{place}, which the build record lists, is missing; pack the card again"
      rescue NoFollow::Link
        raise Error, "netboot: #{place} is a symbolic link, not the file the card build wrote; pack the card again"
      end
      begin
        raise Error, "netboot: #{place} is not a regular file; pack the card again" unless input.stat.file?

        yield input
      ensure
        input.close
      end
    end

    # Points link at directory, its sibling, in one rename, over whatever link was.
    def swap(link, directory)
      temporary = "#{directory}.link"
      File.symlink(File.basename(directory), temporary)
      File.rename(temporary, link)
    ensure
      FileUtils.rm_f(temporary) if temporary && File.symlink?(temporary)
    end

    private_class_method :read_record, :locked, :check_link, :staged_path, :stale_siblings, :copy, :open_listed, :swap
  end
end
