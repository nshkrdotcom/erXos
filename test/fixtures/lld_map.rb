# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# A link map as LLD writes it (lld/ELF/MapFile.cpp, writeMapFile, LLVM 23.1.3):
# the header row, then one row per line, each opening with the columns
# "%16llx %16llx %8llx %5lld " and naming an output section at no indent, an
# input section eight spaces in and a symbol sixteen in. It ends as a
# stripped output's map does, with the section-name string table (Writer.cpp
# places non-allocated orphans at the end; SyntheticSections.cpp adds
# .shstrtab after every other table but .strtab, which a stripped output lacks).
module LldMapFixture
  module_function

  HEADER = "             VMA              LMA     Size Align Out     In      Symbol\n"

  def row(address, size, align, name) = format("%16x %16x %8x %5d %s\n", address, address, size, align, name)

  # A map whose .text holds one four-byte input section of each name, in order.
  def text(*inputs)
    rows = inputs.each_with_index.map { |input, index| row(0x10000 + (4 * index), 4, 4, "        #{input}:(.text)") }
    [HEADER, row(0x10000, 4 * inputs.size, 4, '.text'), *rows,
     row(0, 0x10, 1, '.shstrtab'), row(0, 0x10, 1, '        <internal>:(.shstrtab)')].join
  end
end
