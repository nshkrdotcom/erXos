# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require_relative '../../tools/lib/erx/file_lock'
require_relative '../../tools/lib/erx/native_jit_runtime'

# Two runtime builds in one tree must not run at once: each configures and
# makes in the same copy under build/runtime, and two at once delete each
# other's files. Another process holds the lock here; the build it would race
# is a stand-in that only records that it ran.
class RuntimeLockTest < Minitest::Test
  DEADLINE = 10

  # A runtime whose build does nothing but say it ran.
  class StubRuntime < Erx::Runtime
    attr_reader :built

    private

    def build_locked(jobs:)
      @built = jobs
    end
  end

  # Another process, holding path's lock until release is called.
  Holder = Data.define(:pid, :release_writer) do
    def release
      release_writer.close
      Process.wait(pid)
    end
  end

  def setup
    @root = Dir.mktmpdir('erx-runtime-lock')
    @lock = File.join(@root, Erx::Runtime::LOCK)
    FileUtils.mkdir_p(File.dirname(@lock))
  end

  def teardown
    @holder&.release
    FileUtils.rm_rf(@root)
  end

  def test_a_second_build_waits_for_the_holder_and_names_it
    @holder = hold_elsewhere(@lock)
    runtime = StubRuntime.new(root: @root, runner: :unused, oracle: :unused)
    errors = StringIO.new
    build = with_stderr(errors) do
      thread = Thread.new { runtime.build(jobs: 3) }
      wait_until { errors.string.include?('waiting') }
      thread
    end
    assert_includes errors.string, "in use by pid #{@holder.pid}"
    assert_includes errors.string, File.realpath(@lock)
    assert_nil runtime.built, 'the build ran while another process held the lock'

    @holder.release
    @holder = nil
    assert build.join(DEADLINE), 'the build did not run once the lock was released'
    assert_equal 3, runtime.built
  end

  # The oracle refuses rather than waits, and the refusal names the holder.
  def test_a_refusing_hold_names_the_holder
    @holder = hold_elsewhere(@lock)
    error = assert_raises(Erx::Error) do
      Erx::FileLock.hold(@lock, what: 'the test lock', busy: :refuse) { flunk 'ran under a held lock' }
    end
    assert_match(/\Athe test lock is in use by pid #{@holder.pid} \(lock .*\.lock\)\z/, error.message)
  end

  # Every kind of runtime build enters through Runtime's locked build.
  def test_every_runtime_kind_builds_through_the_locked_entry
    kinds = kinds_of(Erx::Runtime) - [StubRuntime]
    assert_includes kinds, Erx::NativeJitRuntime
    kinds.each do |kind|
      assert_equal Erx::Runtime, kind.instance_method(:build).owner, kind.name
      assert_includes kind.private_instance_methods, :build_locked, kind.name
    end
  end

  # The holder's pid overwrites the lock file, so a symlink planted at its
  # path is refused rather than followed to the file it names.
  def test_a_symlink_at_the_lock_path_is_refused
    target = File.join(@root, 'precious')
    File.write(target, "precious\n")
    File.symlink(target, @lock)
    error = assert_raises(Erx::Error) do
      Erx::FileLock.hold(@lock, what: 'the test lock', busy: :refuse) { flunk 'ran under a planted lock' }
    end
    assert_match(/cannot lock the test lock/, error.message)
    assert_equal "precious\n", File.read(target)
  end

  private

  # Forks a process that takes path's lock and keeps it until released.
  def hold_elsewhere(path)
    ready_reader, ready_writer = IO.pipe
    release_reader, release_writer = IO.pipe
    pid = fork do
      ready_reader.close
      release_writer.close
      Erx::FileLock.hold(path, what: 'the holder', busy: :refuse) do
        ready_writer.write('held')
        ready_writer.close
        release_reader.read
      end
    ensure
      exit!(0)
    end
    ready_writer.close
    release_reader.close
    held = ready_reader.read
    ready_reader.close
    assert_equal 'held', held, 'the holder did not take the lock'
    Holder.new(pid: pid, release_writer: release_writer)
  end

  def kinds_of(base) = base.subclasses.flat_map { |kind| [kind, *kinds_of(kind)] }

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DEADLINE
    until yield
      flunk 'timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
  end

  def with_stderr(stream)
    saved = $stderr
    $stderr = stream
    yield
  ensure
    $stderr = saved
  end
end
