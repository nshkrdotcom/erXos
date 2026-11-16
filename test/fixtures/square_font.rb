# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# A TrueType font of two square glyphs, for tests of the glyph step whose
# expected coverage follows from geometry alone. Its em is 1024 units, so at
# 16 pixels per em a pixel is 64 units: U+0041 is the square from (1, 0) to
# (5, 4) pixels, on whole pixels, and U+0042 the same square moved half a
# pixel right and up; each advances 6 pixels. U+0043 is the square from
# (-1, -2) to (3, 2), left of the pen and half below the baseline, and
# advances 6.5 pixels; the ascender is 13 pixels and
# the descender 3. Each left side bearing is its square's left edge, as
# FreeType places a glyph by it. It has the tables FreeType's TrueType driver reads
# (OpenType 1.9, "Font file" and the head, hhea, maxp, hmtx, loca, glyf,
# cmap and post chapters) and no glyph names (post version 3.0).
module SquareFont
  UNITS_PER_EM = 1024
  PIXEL = 64
  ASCENDER = 13 * PIXEL
  DESCENDER = -3 * PIXEL
  ADVANCE = 6 * PIXEL
  # Each square's lower-left corner and its advance, in font units, by
  # character.
  SQUARES = { 0x41 => [PIXEL, 0, ADVANCE], 0x42 => [PIXEL + PIXEL / 2, PIXEL / 2, ADVANCE],
              0x43 => [-PIXEL, -2 * PIXEL, ADVANCE + PIXEL / 2] }.freeze
  SIDE = 4 * PIXEL

  module_function

  def bytes
    glyphs = ['', *SQUARES.values.map { |x, y, _| square(x, y) }]
    offsets = glyphs.each_with_object([0]) { |glyph, ends| ends << (ends.last + glyph.bytesize) }
    tables = {
      'cmap' => cmap,
      'glyf' => glyphs.join,
      'head' => head,
      'hhea' => [0x00010000, ASCENDER, DESCENDER, 0, ADVANCE, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, glyphs.size]
        .pack('Nn*'),
      'hmtx' => [[ADVANCE, 0], *SQUARES.values.map { |x, _, advance| [advance, x] }].map { |metric| metric.pack('nn') }.join,
      'loca' => offsets.map { |offset| offset / 2 }.pack('n*'),
      'maxp' => [0x00010000, glyphs.size, 4, 1, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0].pack('Nn*'),
      'post' => [0x00030000, 0, 0, 0, 0, 0, 0, 0].pack('N*')
    }
    directory(tables)
  end

  # One closed contour through the square's four corners, on-curve points
  # with 16-bit coordinate deltas (flag 1 alone).
  def square(x, y)
    xs = [x, x, x + SIDE, x + SIDE]
    ys = [y, y + SIDE, y + SIDE, y]
    deltas = ->(values) { values.each_cons(2).map { |a, b| b - a }.unshift(values.first) }
    [1, x, y, x + SIDE, y + SIDE, 3, 0].pack('s>*') + ([1] * 4).pack('C*') +
      (deltas.call(xs) + deltas.call(ys)).pack('s>*')
  end

  # A format 4 map of the squares' characters to glyphs 1 and 2, then the
  # closing segment.
  def cmap
    low, high = SQUARES.keys.minmax
    segments = [[low, high, (1 - low) & 0xffff], [0xffff, 0xffff, 1]]
    subtable = [segments.size * 2, 4, 1, 0].pack('n*') + segments.map { |segment| segment[1] }.pack('n*') +
               [0].pack('n') + segments.map(&:first).pack('n*') + segments.map(&:last).pack('n*') +
               [0, 0].pack('n*')
    format4 = [4, 6 + subtable.bytesize, 0].pack('n*') + subtable
    [0, 1, 3, 1, 12].pack('nnnnN') + format4
  end

  def head
    [0x00010000, 0x00010000, 0, 0x5F0F3CF5, 0, UNITS_PER_EM].pack('NNNNnn') + [0, 0].pack('q>q>') +
      [PIXEL, 0, 6 * PIXEL, 5 * PIXEL, 0, 8, 2, 0, 0].pack('s>*')
  end

  # The offset table, then each table on a four-byte boundary, tags in order.
  def directory(tables)
    header_size = 12 + 16 * tables.size
    padded = tables.transform_values { |table| table + ("\0" * (-table.bytesize % 4)) }
    offsets = padded.values.each_with_object([header_size]) { |table, ends| ends << (ends.last + table.bytesize) }
    entries = tables.keys.each_with_index.map do |tag, index|
      checksum = padded.fetch(tag).unpack('N*').sum & 0xffffffff
      tag.b + [checksum, offsets.fetch(index), tables.fetch(tag).bytesize].pack('NNN')
    end
    [0x00010000, tables.size, 128, 3, 16 * tables.size - 128].pack('Nn*') + entries.join + padded.values.join
  end
end
