# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The spawn planner against its model, in tools/fuzz/spawn_plan_fuzz.c's format: a flags
# byte (0x01 SETSIGMASK, 0x02 SETSIGDEF, all of 0x1c a process group, 0x20 a full table,
# 0x40 a chosen executable path, 0x80 without 0x08 a NULL argv), a count of table slots
# and a (number, object) pair for each, the ignored signals, the umask, the working
# directory, the attributes' and the thread's masks, the path, then a count of file
# actions, each (op, fd, src, path), and argv's and env's counts and lengths. Seeds: an
# empty spawn, a full table that an addopen finds no room in, a dup2 onto a descriptor
# with FD_CLOEXEC, an addchdir before a relative addopen, and argv at E2BIG's bound.
signals = [0, 0, 0, 0].pack('C*')
spawn = lambda do |flags: 0, slots: [], actions: [], argv: [], cwd: 1|
  [flags, slots.size].pack('CC') + slots.flatten.pack('C*') + signals + [0x12, 0, cwd].pack('CCC') +
    signals * 3 + [actions.size].pack('C') + actions.flatten.pack('C*') +
    [argv.size].pack('C') + argv.pack('C*') + [0].pack('C')
end
close, dup2, open, chdir = 0, 1, 2, 3
Erx::PackFuzz.declare_target(
  sources: %w[liberx/program/spawn_plan.c],
  includes: [*Erx::PackFuzz::INCLUDES, '.'],
  seeds: {
    'empty' => spawn.call,
    'full-table' => spawn.call(flags: 0x20, actions: [[open, 3, 0, 1]]),
    'dup2-cloexec' => spawn.call(slots: [[3, 0x81], [1, 2]], actions: [[dup2, 3, 3, 0], [dup2, 5, 1, 0], [close, 9, 0, 0]]),
    'chdir-open' => spawn.call(actions: [[chdir, 0, 0, 5], [open, 0, 0, 4]]),
    'args-bound' => spawn.call(argv: [2, 2, 0])
  }
)
