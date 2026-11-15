# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'crash_frame'

module Erx
  # A root task's fault as the stopgap records it in a crash frame (docs/design-stopgap.md,
  # "Faults, and the fault of the root task"): the cause fault, the space the root task's,
  # the thread unknown, since a fault names the task and not the thread, and for a page
  # fault the address with Fiasco's fault word in cause, whose bit 1 says the access was
  # a write. The suites that end the machine by a root fault hold their records to it.
  module RootFault
    THREAD_UNKNOWN = (1 << 64) - 1
    ROOT_TASK = 0
    WRITE_BIT = 2
    FAULT = CrashFrame::CODEC.member('crash_cause', 'fault')
    MEMORY = CrashFrame::CODEC.member('fault_kind', 'memory')
    UNDEFINED = CrashFrame::CODEC.member('fault_kind', 'undefined')

    module_function

    # The names of the fields of record, a valid crash frame's, that disagree with a root
    # task's fault of kind, which for a memory fault touched address, writing or not.
    def disagreements(record, kind:, address: nil, write: nil)
      fault = record.fetch('fault')
      memory = kind == MEMORY
      {
        'cause' => record.fetch('cause') == FAULT,
        'kind' => fault.fetch('kind') == kind,
        'address' => !memory || fault.fetch('addr') == address,
        'access' => !memory || (fault.fetch('cause') & WRITE_BIT != 0) == write,
        'thread' => fault.fetch('thread') == THREAD_UNKNOWN,
        'space' => fault.fetch('space') == ROOT_TASK
      }.reject { |_name, agrees| agrees }.keys
    end
  end
end
