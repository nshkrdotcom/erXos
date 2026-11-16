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

  # A static position-independent executable linked at 0: valid's read-execute page,
  # then a read-write segment of one file page and one page of zeros, whose first
  # bytes are the dynamic section. tags default to the one DT_RELA table holding
  # relocations; a test passes its own to change the dynamic section.
  def pie(relocations: [relocation(4352, 1024), relocation(4360, 6144), relocation(8200, 16)],
          tags: nil, extra: [])
    tags ||= [[7, RELA_OFFSET], [8, relocations.sum(&:bytesize)], [9, 24]]
    entries = [*tags, [0, 0]]
    writable = program(type: 1, flags: 6, offset: 4096, address: 4096, file_size: 4096,
                       memory_size: 8192, alignment: 4096)
    dynamic = program(type: 2, flags: 6, offset: DYNAMIC_OFFSET, address: DYNAMIC_OFFSET,
                      file_size: entries.size * 16, alignment: 8)
    bytes = valid(dynamic: true, origin: 0, extra: [writable, dynamic, *extra]) + ("\0".b * 4096)
    table = relocations.join
    bytes[RELA_OFFSET, table.bytesize] = table
    entries.each_with_index { |(tag, value), index| bytes[DYNAMIC_OFFSET + index * 16, 16] = [tag, value].pack('q<Q<') }
    bytes
  end

  def integer(bytes, offset, value, width: 8)
    format = { 1 => 'C', 2 => 'v', 4 => 'V', 8 => 'Q<' }.fetch(width)
    bytes[offset, width] = [value].pack(format)
  end
end
