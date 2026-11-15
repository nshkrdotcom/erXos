# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# The channel's send, the only writer of a program's outbound lane (liberx/program/channel.h),
# through test/fixtures/prog_channel_driver.c, which plays the session and the backend: a frame
# is written whole; a send without room for its whole frame writes nothing and waits until the
# executor's announcement of room brings enough; a sender still waiting when another leaves is woken to
# publish its need again; two senders' frames never interleave; a frame larger than
# the ring is refused with ERX_ERANGE. A kill is a request on a reply slot that waits for its
# reply, which only its own slot's reply ends, and a kill of signal 0 a probe on one; a kill with
# no target in the request table is answered without one; with every worker slot held a
# request waits for a free one. Every case runs under the address and undefined sanitizers,
# and the threaded cases under the thread sanitizer too (docs/design-programs.md, "The
# channel" and "The program protocol"). Each seeded fault must fail its case.
class ProgChannelTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  CHANNEL = 'liberx/program/channel.c'
  SOURCES = %w[liberx/erx_lane.c liberx/program/wake.c liberx/program/inbound.c liberx/program/signal.c
               liberx/erx_profile.c liberx/erx_etf.c kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c
               build/gen/liberx/generated/prog_profile.c build/gen/liberx/generated/abi_reader.c
               test/fixtures/prog_channel_driver.c].freeze
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-pthread'].freeze
  SANITIZERS = {
    address: ['-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'],
    thread: ['-fsanitize=thread']
  }.freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  CASES = %w[whole wait waiters two large kill probe local slots].freeze
  THREADED = %w[wait waiters two kill probe slots].freeze

  # A seeded fault, the case that catches it, and the edit that plants it.
  MUTANTS = {
    'the lock is let go of inside a frame' => ['two', '.whole = true', '.whole = false'],
    'a woken send does not look at the room again' => ['wait', 'while (status == ERX_LANE_PUT_SHORT) {',
                                                       'if (status == ERX_LANE_PUT_SHORT) {'],
    'a sender that leaves does not wake those still waiting' =>
      ['waiters', "\terx_prog_waitq_wake(&room_waiters);\n\t(void)pthread_mutex_unlock(&lock);\n\treturn (status);",
       "\t(void)pthread_mutex_unlock(&lock);\n\treturn (status);"],
    'a requester returns before its reply' => ['kill', "\t\treply_wait(slot);\n", "\t\t(void)reply_wait;\n"],
    'a reply is read on a slot its request did not take' =>
      ['kill', "read = erx_prog_inbound_read(&slots,", "slots.busy[0] = slots.busy[1] = ERX_PROG_REQUEST_KILL;\n\tread = erx_prog_inbound_read(&slots,"]
  }.freeze

  def test_each_case_under_the_address_and_undefined_sanitizers
    with_driver(File.join(ROOT, CHANNEL), :address) do |driver|
      CASES.each { |name| assert_equal "ok #{name}", run_case(driver, name), name }
    end
  end

  def test_threaded_cases_under_the_thread_sanitizer
    with_driver(File.join(ROOT, CHANNEL), :thread) do |driver|
      THREADED.each { |name| assert_equal "ok #{name}", run_case(driver, name), name }
    end
  end

  def test_seeded_faults_are_caught
    source = File.read(File.join(ROOT, CHANNEL))
    Dir.mktmpdir('erx-prog-channel-mutant-') do |directory|
      MUTANTS.each do |name, (kase, original, replacement)|
        assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
        path = File.join(directory, "#{name.tr(' ', '-')}.c")
        File.write(path, source.sub(original, replacement))
        with_driver(path, :address) do |driver|
          refute_equal "ok #{kase}", run_case(driver, kase), "seeded fault not caught: #{name}"
        end
      end
    end
  end

  private

  def with_driver(channel, sanitizer)
    Dir.mktmpdir('erx-prog-channel-') do |directory|
      binary = File.join(directory, 'driver')
      includes = ['-I', ROOT, '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'build/gen/include'),
                  '-I', File.join(ROOT, 'kernel/crypto')]
      sources = [channel, *SOURCES.map { |path| File.join(ROOT, path) }]
      output, status = Open3.capture2e(COMPILER, *FLAGS, *SANITIZERS.fetch(sanitizer), *includes,
                                       *sources, '-o', binary)
      assert status.success?, "compiling the driver failed:\n#{output}"
      yield binary
    end
  end

  # The case's last line: "ok NAME", or what the driver or a sanitizer said instead.
  def run_case(driver, name)
    output, = Open3.capture2e({ 'TSAN_OPTIONS' => 'halt_on_error=1', 'ASAN_OPTIONS' => 'detect_leaks=0' },
                              driver, name, stdin_data: '')
    lines = output.lines.map(&:chomp)
    lines.last == "ok #{name}" && lines.size == 1 ? lines.last : output
  end
end
