# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Raw-byte ELF oracle, independent of the production declaration codec.
module ElfFixture
  module_function

  def program(type:, flags: 4, offset:, address:, file_size:, memory_size: file_size, alignment: 4)
    [type, flags, offset, address, address, file_size, memory_size, alignment].pack('V2Q<6')
  end

  def valid(extra: [], dynamic: false, origin: 0x10000, source_offset: 0, alignment: 4096)
    note_offset = source_offset + 512
    programs = [program(type: 1, flags: 5, offset: source_offset, address: origin,
                        file_size: 4096, alignment: alignment),
                program(type: 4, offset: note_offset, address: origin + 512,
                        file_size: 24)] + extra
    phoff = source_offset + 64
    bytes = "\0".b * (source_offset + 4096)
    identity = "\x7fELF\x02\x01\x01".b.ljust(16, "\0")
    bytes[0, 64] = [identity, dynamic ? 3 : 2, 183, 1, origin + 1024,
                    phoff, 0, 0, 64, 56, programs.size, 0, 0, 0].pack('a16vvVQ<3Vv6')
    programs.each_with_index { |record, index| bytes[phoff + index * 56, 56] = record }
    bytes[note_offset, 24] = [6, 4, 1].pack('V3') + "erXos\0\0\0".b + [1].pack('V')
    bytes
  end

  # AArch64's relative relocation, R_AARCH64_RELATIVE.
  RELATIVE = 1027
  # Where pie puts its relocation table, in the read-execute segment, and its dynamic
  # section, at the start of the read-write segment.
  RELA_OFFSET = 2048
  DYNAMIC_OFFSET = 4096

  def relocation(target, addend, type: RELATIVE, symbol: 0)
    [target, (symbol << 32) | type, addend].pack('Q<2q<')
  end

  # Where pie(dynamic: :readonly) puts its dynamic section: in the read-execute page,
  # after the relocation table.
  READONLY_DYNAMIC_OFFSET = 3072

  # The tags a static position-independent link may carry beside the DT_RELA table's
  # three (abi/formats/elf64.txt, elf_dt), by name, each with its number and a value.
  LISTED_TAGS = { relacount: [0x6ffffff9, 3], flags: [30, 8], flags_1: [0x6ffffffb, 0x8000001],
                  debug: [21, 0], symtab: [6, 1024], syment: [11, 24], strtab: [5, 1536],
                  strsz: [10, 16], hash: [4, 1600], gnu_hash: [0x6ffffef5, 1700], init: [12, 1024],
                  fini: [13, 1024], init_array: [25, 4096], init_arraysz: [27, 8],
                  fini_array: [26, 4104], fini_arraysz: [28, 8] }.freeze
  
  # Where every fixture's program headers start, and the size of one.
  PHOFF = 64
  PHENT = 56
  
  # The DT_RELA, DT_RELASZ and DT_RELAENT entries of pie's default relocations.
  def rela_tags = [[7, RELA_OFFSET], [8, 3 * 24], [9, 24]]

  # A static position-independent executable linked at 0: valid's read-execute page,
  # then a read-write segment of one file page and one page of zeros, whose first
  # bytes are the dynamic section. tags default to the one DT_RELA table holding
  # relocations; a test passes its own to change the dynamic section. dynamic places
  # the section and its PT_DYNAMIC header: :writable as above, :readonly in the
  # read-execute page, :empty a header of no bytes at address 0, :none no header.
  def pie(relocations: [relocation(4352, 1024), relocation(4360, 6144), relocation(8200, 16)],
          tags: nil, extra: [], dynamic: :writable)
    tags ||= [[7, RELA_OFFSET], [8, relocations.sum(&:bytesize)], [9, 24]]
    entries = [*tags, [0, 0]]
    section = { writable: DYNAMIC_OFFSET, readonly: READONLY_DYNAMIC_OFFSET }[dynamic]
    writable = program(type: 1, flags: 6, offset: 4096, address: 4096, file_size: 4096,
                       memory_size: 8192, alignment: 4096)
    header = case dynamic
             in :writable | :readonly
               [program(type: 2, flags: 6, offset: section, address: section,
                        file_size: entries.size * 16, alignment: 8)]
             in :empty then [empty_dynamic]
             in :none then []
             end
    bytes = valid(dynamic: true, origin: 0, extra: [writable, *header, *extra]) + ("\0".b * 4096)
    table = relocations.join
    bytes[RELA_OFFSET, table.bytesize] = table
    entries.each_with_index { |(tag, value), index| bytes[section + index * 16, 16] = [tag, value].pack('q<Q<') } if section
    bytes
  end

  # The PT_DYNAMIC header a fixed link writes, having no dynamic section: no bytes, at 0.
  def empty_dynamic = program(type: 2, flags: 6, offset: 0, address: 0, file_size: 0, alignment: 8)

  def integer(bytes, offset, value, width: 8)
    format = { 1 => 'C', 2 => 'v', 4 => 'V', 8 => 'Q<' }.fetch(width)
    bytes[offset, width] = [value].pack(format)
  end
end
