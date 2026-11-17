# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/elf_fixture'

# The parser of ELF executable headers, and a static position-independent executable's
# relocation table: one valid of each, each header's prefixes, a table naming a symbol,
# a position-independent file linked away from 0, one whose executable segment has a
# zero tail, one carrying every listed dynamic tag and one adding an unlisted tag, one
# whose dynamic header is missing, empty or in the read-execute load, and a fixed file
# with the empty dynamic header a fixed link writes. An accepted position-independent
# plan is laid out as erx_exec lays it out (liberx/exec/load_plan.h), and each step must
# stay in the span and never write code.
rela = ElfFixture.rela_tags
zero_tail = ElfFixture.pie.tap { |bytes| ElfFixture.integer(bytes, 64 + 40, 8192) }
seeds = Erx::PackFuzz.prefix_seeds(ElfFixture.valid)
                     .merge(Erx::PackFuzz.prefix_seeds(ElfFixture.pie).transform_keys { |name| "pie-#{name}" })
                     .merge('pie-symbol' => ElfFixture.pie(relocations: [ElfFixture.relocation(4352, 0, symbol: 1)]),
                            'pie-origin' => ElfFixture.valid(dynamic: true, origin: 0x10000),
                            'pie-zero-tail' => zero_tail,
                            'pie-listed-tags' => ElfFixture.pie(tags: [*rela, *ElfFixture::LISTED_TAGS.values]),
                            'pie-unlisted-tag' => ElfFixture.pie(tags: [*rela, [0x6000000d, 0]]),
                            'pie-no-dynamic' => ElfFixture.pie(dynamic: :none),
                            'pie-empty-dynamic' => ElfFixture.pie(dynamic: :empty),
                            'pie-readonly-dynamic' => ElfFixture.pie(dynamic: :readonly),
                            'fixed-empty-dynamic' => ElfFixture.valid(extra: [ElfFixture.empty_dynamic]))
Erx::PackFuzz.declare_target(sources: ['liberx/elf_plan.c', 'liberx/exec/load_plan.c'], seeds: seeds,
                              includes: [*Erx::PackFuzz::INCLUDES, '.'])
