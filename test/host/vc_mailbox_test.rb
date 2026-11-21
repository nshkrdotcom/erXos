# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../fixtures/generated_tree'

# Judges the one mailbox routine of erx_firmware_request, kernel/core/vc_mailbox.c
# (docs/design-kernel.md, "Firmware requests"; docs/design-usb.md, "The VL805's firmware"),
# a protocol state machine, exhaustively, through test/fixtures/vc_mailbox_driver.c: every
# event from every state against this file's model of the design, then one request against
# each firmware of a grid of model mailboxes, whose checks the driver makes. Seeded faults
# must each change the answers.
class VcMailboxTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'kernel/core/vc_mailbox.c'
  DRIVER = 'test/fixtures/vc_mailbox_driver.c'
  PROPERTY = 'kernel/core/vc_property.c'

  STATES = %w[idle posting posted answered lost].freeze
  EVENTS = %w[begin begin_misaligned begin_high begin_top status_room status_full status_empty status_both
              status_late read_match read_other read_channel read_late answer].freeze
  OUTSTANDING = %w[posting posted answered].freeze
  DEADLINE = 1_000_000_000
  START = 5000
  MESSAGE = 0x1008
  ETIMEDOUT = -9
  EBUSY = -8
  EINVAL = -1

  # name => [original, replacement]; each must change the driver's answers.
  MUTANTS = {
    'the deadline off by one' => ['now < mailbox->deadline', 'now <= mailbox->deadline'],
    'the deadline wraps' => ['now > UINT64_MAX - ERX_VC_DEADLINE_NS ? UINT64_MAX : now + ERX_VC_DEADLINE_NS',
                             'now + ERX_VC_DEADLINE_NS'],
    'a timeout forgotten' => ['*mailbox = (erx_vc_mailbox_t){ .state = ERX_VC_MAILBOX_LOST };',
                              '*mailbox = (erx_vc_mailbox_t){ .state = ERX_VC_MAILBOX_IDLE };'],
    'a lost mailbox revived' => ['if (mailbox->state != ERX_VC_MAILBOX_ANSWERED) {',
                                 'if (mailbox->state == ERX_VC_MAILBOX_IDLE) {'],
    'any word taken as the answer' => ['read_reg != mailbox->message', 'read_reg == 0'],
    'a word from before the post taken' => ['mailbox->state == ERX_VC_MAILBOX_POSTING || ', ''],
    'posted before mailbox 0 is drained' => ["\tif (erx_vc_mbox_status_empty_get(status_reg) == 0)\n\t\treturn (next(ERX_VC_MAILBOX_READ, 0));\n\tif (mailbox->state == ERX_VC_MAILBOX_POSTED)\n\t\treturn (next(ERX_VC_MAILBOX_READ_STATUS, 0));\n",
                                             "\tif (mailbox->state == ERX_VC_MAILBOX_POSTED)\n\t\treturn (next(erx_vc_mbox_status_empty_get(status_reg) == 0 ? ERX_VC_MAILBOX_READ : ERX_VC_MAILBOX_READ_STATUS, 0));\n"],
    'a late read taken' => ["\tif (expired(mailbox, now))\n\t\treturn (done(ERX_ETIMEDOUT));\n\tif (mailbox->state == ERX_VC_MAILBOX_POSTING ||",
                            "\t(void)now;\n\tif (mailbox->state == ERX_VC_MAILBOX_POSTING ||"],
    'a misaligned buffer posted' => ['(address & CHANNEL_MASK) == 0 && ', ''],
    'a second request beside an answer' => ["\tcase ERX_VC_MAILBOX_ANSWERED:\n\t\treturn (done(ERX_EBUSY));\n",
                                            "\t\treturn (done(ERX_EBUSY));\n\tcase ERX_VC_MAILBOX_ANSWERED:\n"]
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-vc-mailbox-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_every_event_from_every_state
    assert_equal table.map(&:last), ask(build).first(table.size)
  end

  def test_the_model_mailboxes
    assert_equal model_counts, ask(build).last
  end

  def test_seeded_faults_are_caught
    source = File.read(File.join(ROOT, CORE))
    expected = table.map(&:last) + [model_counts]
    MUTANTS.each do |name, (original, replacement)|
      assert_equal 1, source.scan(original).size, "mutant #{name}: #{original.inspect} is not unique in #{CORE}"
      mutant = File.join(@directory, "#{name.tr(" '", '--')}.c")
      File.write(mutant, source.sub(original, replacement))
      refute_equal expected, ask(build(core: mutant, name: name), strict: false), "mutant #{name} survives"
    end
  end

  private

  # [input line, the driver's line the design gives it] for every state and event.
  def table = STATES.product(EVENTS).map { |state, event| ["#{state} #{event}", expect(state, event)] }

  def line(op, word, status, after) = "#{op} #{format('%08x', word)} #{status} #{after}"

  def held(state) = OUTSTANDING.include?(state) ? "#{state} #{format('%08x', MESSAGE)} #{START + DEADLINE}" : "#{state} 00000000 0"

  # The design's answer to event in state: the step, then the state after it.
  def expect(state, event)
    case [state, event]
    in ['answered', 'answer'] then "answer 0 #{held('idle')}"
    in [_, 'answer'] then "answer #{EINVAL} #{held(state)}"
    in ['lost', /\Abegin/] then line('done', 0, ETIMEDOUT, held(state))
    in [_, /\Abegin/] if OUTSTANDING.include?(state) then line('done', 0, EBUSY, held(state))
    in ['idle', 'begin'] then line('fill', 0, 0, held('posting'))
    in ['idle', 'begin_top'] then line('fill', 0, 0, "posting fffffff8 #{2**64 - 1}")
    in ['idle', /\Abegin/] then line('done', 0, EINVAL, held(state))
    in ['posting' | 'posted', 'status_late' | 'read_late'] then line('done', 0, ETIMEDOUT, held('lost'))
    in ['posting' | 'posted', 'status_room' | 'status_full'] then line('read', 0, 0, held(state))
    in ['posting', 'status_empty' | 'status_both'] then line('write', MESSAGE, 0, held('posted'))
    in ['posted', 'status_empty' | 'status_both'] then line('read_status', 0, 0, held(state))
    in ['posted', 'read_match'] then line('check', 0, 0, held('answered'))
    in ['posting' | 'posted', /\Aread_/] then line('read_status', 0, 0, held(state))
    else line('done', 0, EINVAL, held(state))
    end
  end

  # The driver's grid: runs, then those whose answer, this buffer's, is read before the
  # deadline, at the poll after the drain, the post's, the wait and the noise.
  def model_counts
    steps = [1_000_000, 100_000_000, 250_000_000, 333_333_334, 1_000_000_000]
    grid = [0, 1, 2].product([0, 1, 2, 3], [0, 1, 2, 3], %i[none this other], steps)
    answered = grid.count { |stale, delay, noise, answer, step| answer == :this && (stale + 1 + delay + noise) * step < DEADLINE }
    "model #{grid.size} #{answered} #{grid.size - answered}"
  end

  def build(core: File.join(ROOT, CORE), name: 'driver')
    output = File.join(@directory, name.tr(" '", '--'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *@flags, *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'), '-I', ROOT,
                                  core, File.join(ROOT, PROPERTY), File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  # The driver's answers; a run that ends in a failure (a check's abort under a mutant)
  # answers nil, which no pinned list equals.
  def ask(program, strict: true)
    output, status = Open3.capture2e(program, stdin_data: table.map { |input, _| "#{input}\n" }.join)
    assert status.success?, output if strict
    status.success? ? output.lines.map(&:chomp) : nil
  end
end
