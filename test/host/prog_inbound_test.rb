# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/generated'
require_relative '../fixtures/prog_profile_frames'

# The event executor's decisions on a program's inbound lane (liberx/program/inbound.h),
# through test/fixtures/prog_inbound_driver.c under the address and undefined sanitizers:
# every record header of the grid below against the rule written here, the startup message
# first and reports and replies after it (docs/design-programs.md, "The program protocol"), each
# report of the profile read to its pipe end and the capabilities it installed, which the
# executor closes for an end the program does not hold, and the reply slots through every state
# and event: a reply is read only on a slot that awaits one. Each seeded fault must fail its case.
class ProgInboundTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  INBOUND = 'liberx/program/inbound.c'
  PROFILE = 'build/gen/liberx/generated/prog_profile.c'
  SOURCES = [INBOUND, PROFILE, 'liberx/erx_profile.c', 'liberx/erx_etf.c', 'kernel/crypto/blake3/blake3.c',
             'kernel/crypto/blake3/blake3_portable.c', 'test/fixtures/prog_inbound_driver.c'].freeze
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  E = ProgProfileFrames::Etf

  # The bounds are abi/protocols/prog.txt's limits, read from the schema the headers come from.
  LIMITS = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)).constants
  REC_FRAME = LIMITS.fetch('rec_frame').value
  FRAME_MAX = LIMITS.fetch('prog_frame_max').value
  REPORT_BYTES = LIMITS.fetch('prog_report_max').value
  KINDS = [0, REC_FRAME, 2, 3, 4, 0xffff_ffff].freeze
  ZEROS = [0, 1, 1 << 63].freeze
  LENS = [0, 1, REPORT_BYTES - 1, REPORT_BYTES, REPORT_BYTES + 1, FRAME_MAX, FRAME_MAX + 1, 0xffff_ffff].freeze
  GRID = [false, true].product(KINDS, ZEROS, LENS).freeze

  # The rule: a frame record with a zero word of 0 and a body; the first within the profile's
  # frame bound is the startup message, every later one within the report bound a report.
  def self.decision(started, kind, zero, len)
    return 'refuse' unless kind == REC_FRAME && zero.zero? && len.positive?
    return (len <= FRAME_MAX ? 'start' : 'refuse') unless started

    len <= REPORT_BYTES ? 'frame' : 'refuse'
  end

  def self.report(*body) = E.frame(E.tuple(E.atom('erx_prog'), E.small(1), body.size == 1 ? body.first : E.tuple(*body)))

  BIG_CAP = 1 << 40
  # name => [frame, answer]: which, pipe, end and the capabilities to close, or refused.
  REPORTS = {
    writer: [report(E.atom('pipe_writer'), E.small(3), E.small(4), E.small(2), E.small(100), E.small(101),
                    E.int(16_384), E.small_big(BIG_CAP), E.atom('open')),
             "report 0 3 4 100 101 #{BIG_CAP}"],
    writer_gone: [report(E.atom('pipe_writer_gone'), E.small(3), E.small(4), E.small(2)), 'report 1 3 4'],
    reader: [report(E.atom('pipe_reader'), E.small(3), E.small(4), E.small(63), E.small(7), E.atom('gone')),
             'report 2 3 4 7'],
    reader_gone: [report(E.atom('pipe_reader_gone'), E.small(3), E.small(4), E.small(0)), 'report 3 3 4'],
    lost: [report(E.atom('pipe_lost'), E.small(3), E.small(4)), 'report 4 3 4'],
    server_lost: [report(E.atom('pipe_server_lost')), 'report 5 0 0'],
    # The profile refuses these whole: a size other than the two, one capability named twice,
    # a read end index past 63, and a report the profile does not name.
    bad_size: [report(E.atom('pipe_writer'), E.small(3), E.small(4), E.small(2), E.small(100), E.small(101),
                      E.int(1000), E.small(102), E.atom('open')), 'refused'],
    twice: [report(E.atom('pipe_writer'), E.small(3), E.small(4), E.small(2), E.small(100), E.small(100),
                   E.int(16_384), E.small(102), E.atom('open')), 'refused'],
    rix: [report(E.atom('pipe_reader_gone'), E.small(3), E.small(4), E.small(64)), 'refused'],
    unknown: [report(E.atom('pipe_moved'), E.small(3), E.small(4)), 'refused']
  }.freeze

  def test_every_header_decides_as_the_rule
    answers = run_driver(open_requests)
    expected = GRID.map { |started, kind, zero, len| "open #{self.class.decision(started, kind, zero, len)}" }
    assert_equal expected.size, answers.size
    GRID.zip(answers, expected).each do |(started, kind, zero, len), got, want|
      assert_equal want, got, "started=#{started} kind=#{kind} zero=#{zero} len=#{len}"
    end
  end

  def test_each_report_reads_to_its_end_and_capabilities
    answers = run_driver(report_requests)
    REPORTS.each_value.zip(answers).each_with_index do |((_, want), got), at|
      assert_equal want, got, REPORTS.keys[at].to_s
    end
  end

  def self.reply(slot, body) = E.frame(E.tuple(E.atom('erx_prog'), E.small(1), E.small(slot), body))
  def self.reply_on(slot, body) = "frame #{reply(slot, body).unpack1('H*')}"
  KILL = 0 # ERX_PROG_REQUEST_KILL, the request union's first case
  # Every state of a slot (free, awaiting, answered) under every event (take, reply, release), with
  # the answer each request must give. Slot 0 is the one walked; take gives the lowest free one.
  SLOTS = [
    ['state 0', 'state free'],
    [reply_on(0, E.atom('ok')), 'refused'],                                         # free + reply
    ["take #{KILL}", 'take 0'],                                                     # free + take
    ['state 0', 'state awaiting'],
    ["take #{KILL}", 'take 1'],                                                     # awaiting + take
    ['release 1', 'release'],
    [reply_on(0, E.tuple(E.atom('error'), E.atom('esrch'))), "reply 0 #{KILL} 1 3"], # awaiting + reply
    ['state 0', 'state answered'],
    [reply_on(0, E.atom('ok')), 'refused'],                                         # answered + reply
    ["take #{KILL}", 'take 1'],                                                     # answered + take
    ['release 0', 'release'],                                                       # answered + release
    ['state 0', 'state free'],
    ["take #{KILL}", 'take 0'],
    ['release 0', 'release'],                                                       # awaiting + release
    ['state 0', 'state free'],
    [reply_on(1, E.atom('ok')), "reply 1 #{KILL} 0 0"],
    ['release 1', 'release'],
    # A reply on an awaiting slot that is not its request's reply, and one on the executor's slot.
    ["take #{KILL}", 'take 0'],
    [reply_on(0, E.tuple(E.atom('ok'), E.small(1))), 'refused'],
    ['state 0', 'state awaiting'],
    [reply_on(15, E.atom('ok')), 'refused'],
    # Every worker slot held: the next take finds none, and the executor's slot is never given.
    *(1..14).map { |slot| ["take #{KILL}", "take #{slot}"] },
    ["take #{KILL}", 'take 16'],
    ['release 9', 'release'],
    ["take #{KILL}", 'take 9']
  ].freeze

  def test_reply_slots_move_through_every_state_and_event
    answers = run_driver(SLOTS.map(&:first))
    assert_equal SLOTS.size, answers.size
    SLOTS.zip(answers).each_with_index do |((request, want), got), at|
      assert_equal want, got, "step #{at}: #{request[0, 40]}"
    end
  end

  # A seeded fault, the requests that catch it, the source it edits and the edit that plants it.
  # The capability walk is the profile's generated erx_prog_report_caps.
  MUTANTS = {
    'a nonzero zero word is admitted' => [:open, INBOUND, 'zero != 0', '(zero & 0) != 0'],
    'a report at the bound is refused' => [:open, INBOUND, 'len <= ERX_PROG_REPORT_MAX', 'len < ERX_PROG_REPORT_MAX'],
    "a writer's doorbell is left open" => [:report, PROFILE, "\t\treturn (3);\n", "\t\treturn (2);\n"],
    'a read reply leaves its slot awaiting' => [:slots, INBOUND, "\t\tslots->busy[got->slot] = ERX_PROFILE_NONE;\n",
                                                "\t\t(void)slots;\n"],
    'a worker takes the executor slot' => [:slots, INBOUND, 'slot < ERX_PROG_EXECUTOR_SLOT', 'slot <= ERX_PROG_EXECUTOR_SLOT']
  }.freeze

  def test_seeded_faults_are_caught
    Dir.mktmpdir('erx-prog-inbound-mutant-') do |directory|
      MUTANTS.each do |name, (requests, file, original, replacement)|
        source = File.read(File.join(ROOT, file))
        assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
        path = File.join(directory, "#{name.tr(' ', '-').delete("'")}.c")
        File.write(path, source.sub(original, replacement))
        answers = run_driver(requests_of(requests), file => path)
        expected = expected_of(requests)
        refute_equal expected, answers, "seeded fault not caught: #{name}"
      end
    end
  end

  private

  def open_requests = GRID.map { |started, kind, zero, len| "open #{started ? 1 : 0} #{kind} #{zero} #{len}" }
  def open_expected = GRID.map { |started, kind, zero, len| "open #{self.class.decision(started, kind, zero, len)}" }
  def requests_of(kind) = { open: open_requests, report: report_requests, slots: SLOTS.map(&:first) }.fetch(kind)
  def expected_of(kind) = { open: open_expected, report: REPORTS.values.map(&:last), slots: SLOTS.map(&:last) }.fetch(kind)
  def report_requests = REPORTS.values.map { |frame, _| "frame #{frame.unpack1('H*')}" }

  # Builds the driver from SOURCES, each path of replaced built from its replacement instead.
  def run_driver(requests, replaced = {})
    Dir.mktmpdir('erx-prog-inbound-') do |directory|
      binary = File.join(directory, 'driver')
      input = File.join(directory, 'requests')
      File.write(input, "#{requests.join("\n")}\n")
      sources = SOURCES.map { |path| replaced.fetch(path) { File.join(ROOT, path) } }
      includes = ['-I', ROOT, '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'build/gen/include'),
                  '-I', File.join(ROOT, 'kernel/crypto')]
      output, status = Open3.capture2e(COMPILER, *FLAGS, *includes, *sources, '-o', binary)
      assert status.success?, output
      output, status = Open3.capture2e(binary, input)
      assert status.success?, output
      output.lines.map(&:chomp)
    end
  end
end
