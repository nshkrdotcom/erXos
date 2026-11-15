# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The one way erXos's tools keep two processes out of the same build
  # directory (the oracle, build/gen, the runtime builds): an exclusive flock
  # on a lock file, held while a block runs. The kernel drops the lock when
  # its holder exits, however it exits, so no stale lock outlives a killed
  # build. Each holder writes its pid into the file once it has the lock, so
  # a process that finds the lock taken names who holds it. The record is
  # read without the lock: in the moment between a holder taking the lock and
  # writing its pid, it names the previous holder or none.
  #
  # The lock is per open file, so a second hold of the same file on the
  # thread that holds it would wait on itself forever; it is refused
  # instead. Holds are named by the lock file's real path, so another
  # spelling of the same file is the same lock. Another thread of the same
  # process waits on the lock as another process does, and a process forked
  # inside a hold inherits the record of what its parent's thread holds.
  #
  # The lock file is opened without following a symlink and must be a plain
  # file with one link, owner-only, since the pid record overwrites it.
  module FileLock
    MODE = 0o600
    # A pid is at most this many characters; the read of a holder's record
    # stops there.
    PID_CHARACTERS = 20

    # What hold does when another process holds the lock: waits for it,
    # saying so on standard error first; waits without a word, for a lock
    # held only for moments, such as build/gen's; or raises an Error naming
    # the holder.
    BUSY = %i[wait wait_silently refuse].freeze

    # Runs the block holding an exclusive lock on path, whose directory must
    # exist, and returns its value. what names the thing the lock guards in
    # messages, and busy (one of BUSY) says what to do while another process
    # holds it. A system error on the lock file raises an Error naming it.
    def self.hold(path, what:, busy:)
      raise ArgumentError, "busy must be one of #{BUSY.join(' ')}" unless BUSY.include?(busy)

      key = filesystem(what, path) { File.join(File.realpath(File.dirname(path)), File.basename(path)) }
      held = Thread.current.thread_variable_get(:erx_file_locks) ||
             Thread.current.thread_variable_set(:erx_file_locks, [])
      raise Error, "#{what} is locked again by the thread that holds it (#{key})" if held.include?(key)

      lock = open_lock(key, what: what)
      begin
        acquire(lock, what: what, path: key, busy: busy)
        held.push(key)
        yield
      ensure
        held.delete(key)
        lock.close
      end
    end

    class << self
      private

      # Opens path, refusing a symlink, a file of another type or one with
      # another link, and leaves it owner-only.
      def open_lock(path, what:)
        lock = filesystem(what, path) { File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, MODE) }
        begin
          stat = filesystem(what, path) { lock.stat }
          raise Error, "cannot lock #{what}: #{path} is not a plain file with one link" unless stat.file? && stat.nlink == 1

          filesystem(what, path) { lock.chmod(MODE) }
          lock
        rescue Error
          lock.close
          raise
        end
      end

      # Takes the lock as busy says, then records this process's pid in it.
      def acquire(lock, what:, path:, busy:)
        filesystem(what, path) do
          unless lock.flock(File::LOCK_EX | File::LOCK_NB)
            message = "#{what} is in use by #{holder(lock)} (lock #{path})"
            raise Error, message if busy == :refuse

            $stderr.puts("#{message}; waiting") if busy == :wait
            lock.flock(File::LOCK_EX)
          end
        end
        record_holder(lock, what: what, path: path)
      end

      def record_holder(lock, what:, path:)
        filesystem(what, path) do
          lock.rewind
          lock.truncate(0)
          lock.write("#{Process.pid}\n")
          lock.flush
        end
      end

      # The holder's pid as its record gives it, or an unknown process when
      # the record is empty or not a pid.
      def holder(lock)
        lock.rewind
        record = lock.read(PID_CHARACTERS + 1).to_s.chomp
        /\A[1-9][0-9]{0,#{PID_CHARACTERS - 1}}\z/.match?(record) ? "pid #{record}" : 'an unknown process'
      end

      def filesystem(what, path)
        yield
      rescue SystemCallError => error
        raise Error, "cannot lock #{what} (#{path}): #{error.message}"
      end
    end
  end
end
