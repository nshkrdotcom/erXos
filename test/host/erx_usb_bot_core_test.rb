# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_usb_bot_core_tests.erl, the Bulk-Only engine explored to a fixed
# point, BOT 1.0's thirteen cases, traces and the decoders, against the module compiled
# from source on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies).
# Then each seeded fault the design names (docs/design-usb.md, "Host tests of the
# cores"), applied to a copy of the module, must fail the exploration: the CSW's tag check
# removed, so a wrapper of another command is taken; the residue rule removed, so a
# device that cannot count its bytes is trusted; the medium reference check removed, so
# a request of an ended medium is sent to the next; the engine idle after a failed status
# with the sense queued behind it, so a queued write runs before a UNIT ATTENTION is
# seen; a failed sense answered by asking for sense again; and a flush of a medium that
# cannot flush answered `ok`.
class ErxUsbBotCoreTest < Minitest::Test
  APPLICATIONS = %w[erx_usb].freeze
  CORE = 'erlang/apps/erx_usb/src/erx_usb_bot_core.erl'
  TESTS = %w[test/erlang/erx_usb_bot_core_tests.erl].freeze
  EXPLORATION = 'the_engine_explored_keeps_its_invariants_test_'
  DEADLINE_SECONDS = '600'

  Seed = Data.define(:fault, :anchor, :replacement)

  SEEDS = [
    Seed.new(fault: "the CSW's tag check removed",
             anchor: 'Tag:32/little, Residue:32/little, Status>>, Tag, Length) ->',
             replacement: '_CswTag:32/little, Residue:32/little, Status>>, _Tag, Length) ->'),
    Seed.new(fault: 'the residue rule removed',
             anchor: "        Residue > Length -> not_meaningful;\n",
             replacement: ''),
    Seed.new(fault: 'the medium reference check removed',
             anchor: 'case {ref(Current) =:= Medium, Current, Request} of',
             replacement: 'case {true, Current, Request} of'),
    Seed.new(fault: 'the engine idle after a failed status, its sense queued behind',
             anchor: "failed(_Now, State = \#{op := Op = \#{stage := command, command := Command}}) ->\n    " \
                     "send(Op\#{stage := sense}, {request_sense, lun(Command)}, State);",
             replacement: "failed(Now, State = \#{op := \#{stage := command, " \
                          "entry := Entry = \#{request := Request}}, queue := Queue}) ->\n    " \
                          'Sense = Entry#{id := sense, request := {request_sense, lun(Request)}}, ' \
                          'finish({error, {device, failed}}, keep, Now, State#{queue := queue:in(Sense, Queue)});'),
    Seed.new(fault: 'a failed sense answered by asking for sense again',
             anchor: "failed(Now, State = \#{op := \#{stage := sense}}) ->\n    sense_failed(Now, State).",
             replacement: "failed(_Now, State = \#{op := Op = \#{stage := sense, command := Command}}) ->\n    " \
                          'send(Op, Command, State).'),
    Seed.new(fault: 'a flush of a medium that cannot flush answered ok',
             anchor: 'answer_next(Id, {error, no_flush}, Now, State)',
             replacement: 'answer_next(Id, ok, Now, State)')
  ].freeze

  def test_bot_core_cases_pass_under_eunit
    output, status = run_cases
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_the_exploration
    source = File.binread(File.join(ErlangBuild::ROOT, CORE))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases(replaced: { CORE => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(EXPLORATION)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  def run_cases(replaced: {})
    Dir.mktmpdir('erx-usb-bot-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_usb_bot_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
