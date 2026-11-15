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
# other's files; nor may a build run while something reads the tree. Another
# process holds the lock here; the build it would race is a stand-in that only
# records that it ran.
class RuntimeLockTest < Minitest::Test
  DEADLINE = 10

  # A runtime whose build only runs inside, if given, and says it ran.
  class StubRuntime < Erx::Runtime
    attr_reader :built
    attr_writer :inside

    private

    def build_locked(jobs:)
      @inside&.call
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

  def test_a_reader_waits_for_a_build
    @holder = hold_elsewhere(@lock)
    read = false
    errors = StringIO.new
    reader = with_stderr(errors) do
      thread = Thread.new { Erx::Runtime.reading(root: @root) { read = true } }
      wait_until { errors.string.include?('waiting') }
      thread
    end
    assert_includes errors.string, "in use by pid #{@holder.pid}"
    refute read, 'the reader read while a build held the lock'

    @holder.release
    @holder = nil
    assert reader.join(DEADLINE), 'the reader did not read once the build was done'
    assert read
  end

  def test_a_build_waits_for_a_reader_and_says_so
    @holder = hold_elsewhere(@lock, mode: :shared)
    runtime = StubRuntime.new(root: @root, runner: :unused, oracle: :unused)
    errors = StringIO.new
    build = with_stderr(errors) do
      thread = Thread.new { runtime.build(jobs: 3) }
      wait_until { errors.string.include?('waiting') }
      thread
    end
    assert_includes errors.string, 'in use by shared holders'
    assert_nil runtime.built, 'the build ran while another process read the tree'

    @holder.release
    @holder = nil
    assert build.join(DEADLINE), 'the build did not run once the reader was done'
    assert_equal 3, runtime.built
  end

  def test_readers_share_the_lock
    @holder = hold_elsewhere(@lock, mode: :shared)
    assert_equal :read, Erx::FileLock.hold(@lock, what: 'the test lock', busy: :refuse, mode: :shared) { :read }
  end

  # A build may read what it built: the read inside its own hold takes nothing.
  def test_a_read_inside_a_build_proceeds
    runtime = StubRuntime.new(root: @root, runner: :unused, oracle: :unused)
    read = false
    runtime.inside = -> { Erx::Runtime.reading(root: @root) { read = true } }
    build = Thread.new { runtime.build(jobs: 3) }
    assert build.join(DEADLINE), 'the read inside the build waited on the build'
    assert read
    assert_equal 3, runtime.built
  end

  # A build inside a read would wait on the read forever, and is refused.
  def test_a_build_inside_a_read_is_refused
    runtime = StubRuntime.new(root: @root, runner: :unused, oracle: :unused)
    error = assert_raises(Erx::Error) { Erx::Runtime.reading(root: @root) { runtime.build(jobs: 1) } }
    assert_match(/locked exclusively inside this thread's own hold/, error.message)
    assert_nil runtime.built
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

  # Forks a process that takes path's lock in mode and keeps it until released.
  def hold_elsewhere(path, mode: :exclusive)
    ready_reader, ready_writer = IO.pipe
    release_reader, release_writer = IO.pipe
    pid = fork do
      ready_reader.close
      release_writer.close
      Erx::FileLock.hold(path, what: 'the holder', busy: :refuse, mode: mode) do
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
