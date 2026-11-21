# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # A process's message queue length, sig_qs.mq_len, goes down only in
    # erts_msgq_count_removed, which every unlink of a message calls: beside
    # the length it clears the prim_eval frames that hold the message before
    # the message can be freed (edit 78). An unlink that lowers the length on
    # its own leaves a frame naming a freed message. The pattern takes the
    # whole line, so each permitted site names its own line: a decrement
    # (mq_len--, --...mq_len), every compound assignment but += and a plain
    # assignment, the field's address and an offsetof that a store at an
    # offset could use. Raising it (++, +=) is free, on stock's invariant
    # that every += operand is positive (the ASSERTs in
    # inc_converted_msgs_len and on mlenoffs). An operand of -- or & is
    # matched only through lvalue characters, so "i--; ... mq_len" on one
    # line is no decrement of it. What gets past: a name a macro pastes
    # together or a macro that expands to the field, a C++ reference bound
    # to it, a write split across lines, a write of the whole sig_qs, a copy
    # of a permitted line elsewhere in its file, and the C bodies of the
    # emulator's .tab instruction files, which no text rule reads.
    LVALUE = /[\w.>()\[\]*\s-]*?/
    MQ_LEN_LOWERED = /
      .*(?:
        --#{LVALUE}\bmq_len\b
        | \bmq_len\s*(?:--|(?:[-*\/%&|^]|<<|>>)?=(?!=))
        | (?<!&)&(?!&)\s*\(?#{LVALUE}\bmq_len\b
        | \boffsetof\s*\([^)]*\bmq_len\b
      ).*
    /x
    MSGQ_HEADER = 'otp/erts/emulator/beam/erl_proc_sig_queue.h'
    # The one decrement, in erts_msgq_count_removed, and the stock
    # initializations of an empty queue in erl_create_process and
    # erts_init_empty_process. A copy of a permitted line elsewhere in its
    # file gets past, as for every line-permitted site.
    MQ_LEN_SITES = {
      MSGQ_HEADER => /\A\s*c_p->sig_qs\.mq_len--;\s*\z/,
      'otp/erts/emulator/beam/erl_process.c' => /\A\s*p->sig_qs\.mq_len = 0;\s*\z/
    }.freeze

    declare_group(
      rules: [
        Chokepoints::Forbidden.new(
          name: 'msgq-length',
          rule: 'only erts_msgq_count_removed lowers a process\'s sig_qs.mq_len, so every unlink of a message ' \
                'also clears the prim_eval frames that hold it; the other lines listed initialize an empty queue',
          design: 'docs/design-runtime.md#the-edits-outside-syserxos',
          scope: Chokepoints::Scope.new(own: false, extra: %w[otp/erts/**/*],
                                        except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: MQ_LEN_LOWERED,
          sites: MQ_LEN_SITES.map { |path, line| Chokepoints::Site.new(glob: path, permits: line) },
          seed: { 'otp/erts/emulator/beam/erl_proc_sig_queue.c' => "        c_p->sig_qs.mq_len--;\n",
                  'otp/erts/emulator/beam/erl_message.c' => "    --proc->sig_qs.mq_len;\n",
                  'otp/erts/emulator/beam/erl_process.c' => "    p->sig_qs.mq_len -= 1;\n",
                  'otp/erts/emulator/beam/jit/beam_jit_common.cpp' => "    c_p->sig_qs.mq_len = len - 1;\n",
                  'otp/erts/emulator/beam/bif.c' => "    Sint *len = &c_p->sig_qs.mq_len;\n",
                  'otp/erts/emulator/beam/jit/arm/instr_msg.cpp' =>
                    "    a.ldr(TMP1, arm::Mem(c_p, offsetof(Process, sig_qs.mq_len)));\n",
                  MSGQ_HEADER => "    proc->sig_qs.mq_len--;\n" }
        )
      ]
    )
  end
end
