# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/elf_fixture'

# The parser of ELF executable headers, and a static position-independent executable's
# relocation table: one valid of each, each header's prefixes, a table naming a symbol,
# a position-independent file linked away from 0, and one whose executable segment has
# a zero tail. An accepted position-independent plan is laid out as erx_exec lays it out
# (liberx/exec/load_plan.h), and each step must stay in the span and never write code.
zero_tail = ElfFixture.pie.tap { |bytes| ElfFixture.integer(bytes, 64 + 40, 8192) }
seeds = Erx::PackFuzz.prefix_seeds(ElfFixture.valid)
                     .merge(Erx::PackFuzz.prefix_seeds(ElfFixture.pie).transform_keys { |name| "pie-#{name}" })
                     .merge('pie-symbol' => ElfFixture.pie(relocations: [ElfFixture.relocation(4352, 0, symbol: 1)]),
                            'pie-origin' => ElfFixture.valid(dynamic: true, origin: 0x10000),
                            'pie-zero-tail' => zero_tail)
Erx::PackFuzz.declare_target(sources: ['liberx/elf_plan.c', 'liberx/exec/load_plan.c'], seeds: seeds,
                              includes: [*Erx::PackFuzz::INCLUDES, '.'])
