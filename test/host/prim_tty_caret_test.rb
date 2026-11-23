# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs the EUnit cases of test/erlang/prim_tty_caret_tests.erl against the tree's prim_tty,
# otp/lib/kernel/src/prim_tty.erl, loaded over the kernel's, so the run is -nostick.
class PrimTtyCaretTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  KERNEL = File.join(ROOT, 'otp/lib/kernel')
  TESTS = File.join(ROOT, 'test/erlang/prim_tty_caret_tests.erl')
  SOURCE = File.join(KERNEL, 'src/prim_tty.erl')
  DEADLINE = '300'

  def test_control_characters_are_shown_in_caret_notation_by_the_trees_prim_tty
    Dir.mktmpdir('erx-prim-tty') do |work|
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERLC'), '-I', File.join(KERNEL, 'src'),
                                       '-I', File.join(KERNEL, 'include'), '-o', work, SOURCE, TESTS, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-nostick',
                                       '-eval', eval_text, chdir: work, stdin_data: '')
      report_path = File.join(work, 'eunit.out')
      report = File.exist?(report_path) ? File.read(report_path) : ''
      assert status.success?, output + report
      assert_match(/All \d+ tests passed/, report)
    end
  end

  private

  # The tree's prim_tty has no NIF, so it cannot write to the host terminal: once it is
  # loaded, the emulator's own `user` can no longer print. EUnit reports to a file instead.
  def eval_text
    'code:add_patha("."), code:purge(prim_tty), {module, prim_tty} = code:load_abs("prim_tty"), ' \
      '{ok, Out} = file:open("eunit.out", [write]), group_leader(Out, self()), ' \
      'halt(case eunit:test(prim_tty_caret_tests, []) of ok -> 0; _ -> 1 end).'
  end
end
