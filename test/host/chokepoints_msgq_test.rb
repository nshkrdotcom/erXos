# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsMsgqTest < Minitest::Test
  include ChokepointsHelper

  SIG_QUEUE_H = 'otp/erts/emulator/beam/erl_proc_sig_queue.h'
  SIG_QUEUE_C = 'otp/erts/emulator/beam/erl_proc_sig_queue.c'
  PROCESS_C = 'otp/erts/emulator/beam/erl_process.c'

  def found(files) = evaluate([rule('msgq-length')], files, imported: files.keys).map(&:line)

  # Reading the length, raising it, the one decrement in
  # erts_msgq_count_removed's header and a new process's zero pass.
  def test_reads_raises_and_the_permitted_lines_pass
    allowed = {
      SIG_QUEUE_H => "    c_p->sig_qs.mq_len--;\n    ASSERT(c_p->sig_qs.mq_len >= 0);\n" \
                     "    if (on && proc->sig_qs.mq_len >= limit)\n",
      SIG_QUEUE_C => "        c_p->sig_qs.mq_len++;\n        c_p->sig_qs.mq_len += len;\n" \
                     "    ASSERT(c_p->sig_qs.mq_len == i);\n    if (rp->sig_qs.mq_len != 0)\n",
      PROCESS_C => "    p->sig_qs.mq_len = 0;\n    ASSERT(p->sig_qs.mq_len == 0);\n"
    }
    assert_empty found(allowed)
  end

  # A lowering of another spelling beside a permitted line, in the
  # permitted line's own file, is refused.
  def test_other_lowerings_in_the_permitted_files_are_refused
    { SIG_QUEUE_H => "    c_p->sig_qs.mq_len -= n;\n",
      PROCESS_C => "    p->sig_qs.mq_len = n;\n" }.each do |path, text|
      assert_equal [1], found(path => text), "#{path}: #{text.strip}"
    end
  end

  # The lvalue and operator forms the seeds do not show are refused.
  def test_indexed_lvalues_and_compound_assignments_are_refused
    ["    --procs[i]->sig_qs.mq_len;\n", "    Sint *l = &(*rp).sig_qs.mq_len;\n",
     "    c_p->sig_qs.mq_len >>= 1;\n", "    c_p->sig_qs.mq_len /= 2;\n"].each do |text|
      assert_equal [1], found(SIG_QUEUE_C => text), text.strip
    end
  end
end
