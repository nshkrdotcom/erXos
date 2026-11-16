# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# GPOS and GDEF tables built from their parts, for Erx::Gpos's tests and
# fuzz seeds (docs/design-desktop-programs.md, "Verification and testing",
# "Kerning, on the host"). Each builder returns a table's bytes, big-endian as
# OpenType writes them, with each child laid out after its parent's header
# and named by an offset from the parent's start (OpenType 1.9, "OpenType
# layout common table formats" and "GPOS").
#
# Sample is the design's table: a kern feature of two lookups. Lookup 0 is an
# extension lookup wrapping a format 1 subtable, which pairs A with V, and a
# format 2 subtable; lookup 1 is a format 2 subtable that also kerns A and V,
# so that pair is the two lookups' sum. A followed by O is covered by the
# format 1 subtable without its second glyph, so it reads as the format 2
# subtable's class value, and X is listed by no class definition, so T
# followed by X reads as class 0's value. EXPECTED is every non-zero pair of
# GLYPHS that follows.
module GposTables
  A = 36
  V = 57
  T = 55
  O = 82
  X = 91
  GLYPHS = [A, V, T, O, X].freeze
  EXPECTED = { [A, V] => -80, [A, O] => -20, [T, A] => -15, [T, V] => -9, [T, T] => -15, [T, O] => -25,
               [T, X] => -15 }.freeze
  NO_SET = 0xffff
  ADVANCE = 0x0004
  PAIR = 2
  EXTENSION = 9

  module_function

  def u16(*values) = values.pack('n*')

  def s16(*values) = values.pack('s>*')

  # A table whose header the block builds from its children's offsets; a nil
  # child has offset 0. The header's size does not depend on the offsets.
  def layout(children)
    size = yield(children.map { 0 }).bytesize
    offsets = children.each_with_object([]) do |child, laid|
      laid << (child ? size + children.take(laid.size).compact.sum(&:bytesize) : 0)
    end
    yield(offsets) + children.compact.join
  end

  def coverage(glyphs) = u16(1, glyphs.size, *glyphs)

  def coverage_ranges(ranges) = u16(2, ranges.size, *ranges.flatten)

  # A class definition of format 2 from {glyph => class}, one range a glyph.
  def classes(map) = u16(2, map.size, *map.sort.flat_map { |glyph, value| [glyph, glyph, value] })

  # A format 1 subtable from {first => [[second, value], ...]}.
  def pair_singles(sets, format1: ADVANCE, format2: 0)
    firsts = sets.keys.sort
    children = firsts.map { |first| u16(sets[first].size) + sets[first].map { |second, value| u16(second) + s16(value) }.join }
    layout([coverage(firsts), *children]) do |cover, *offsets|
      u16(1, cover, format1, format2, firsts.size, *offsets)
    end
  end

  # A format 2 subtable over FIRSTS, with class definitions CLASS1 and CLASS2
  # ({glyph => class}) and MATRIX, one row of values a first class; COUNTS
  # are the class counts the subtable states, MATRIX's own unless given.
  def pair_classes(firsts:, class1:, class2:, matrix:, format1: ADVANCE, format2: 0,
                   counts: [matrix.size, matrix.first.size])
    layout([coverage(firsts), classes(class1), classes(class2)]) do |cover, first, second|
      u16(2, cover, format1, format2, first, second, *counts) + s16(*matrix.flatten)
    end
  end

  def extension(subtable, type: PAIR) = u16(1, type) + [8].pack('N') + subtable

  def lookup(type, subtables, flag: 0)
    trailer = (flag & 0x0010).zero? ? '' : u16(0)
    layout(subtables) { |offsets| u16(type, flag, subtables.size, *offsets) + trailer }
  end

  def lookup_list(lookups) = layout(lookups) { |offsets| u16(lookups.size, *offsets) }

  def feature(indices) = u16(0, indices.size, *indices)

  def tagged_list(records)
    layout(records.map(&:last)) do |offsets|
      u16(records.size) + records.map(&:first).zip(offsets).map { |tag, offset| tag.b + u16(offset) }.join
    end
  end

  def language_system(features, required: NO_SET) = u16(0, required, features.size, *features)

  # A script with DEFAULT as its default language system, or none when nil.
  def script(default)
    layout([default]) { |(offset)| u16(offset, 0) }
  end

  def gpos(scripts:, features:, lookups:)
    layout([tagged_list(scripts), tagged_list(features), lookup_list(lookups)]) do |offsets|
      u16(1, 0, *offsets)
    end
  end

  # GDEF version 1.0 with a glyph class definition from {glyph => class}.
  def gdef(glyph_classes)
    layout([classes(glyph_classes)]) { |(offset)| u16(1, 0, offset, 0, 0, 0) }
  end

  # Sample's two lookups, LOOKUP0_FIRST the first subtable of lookup 0 and
  # FLAG lookup 1's flag.
  def lookups(type: EXTENSION, format1: ADVANCE, flag: 0x0010)
    singles = pair_singles({ A => [[V, -50]] }, format1: format1)
    classes0 = pair_classes(firsts: [A, T], class1: { A => 1, T => 2 }, class2: { V => 1, O => 2 },
                            matrix: [[0, 0, 0], [0, -7, -20], [-15, -9, -25]])
    first = type == EXTENSION ? [singles, classes0].map { |subtable| extension(subtable) } : [singles, classes0]
    classes1 = pair_classes(firsts: [A], class1: {}, class2: { V => 1 }, matrix: [[0, -30]])
    [lookup(type, first, flag: 0x0008), lookup(PAIR, [classes1], flag: flag)]
  end

  # The design's table; NAMED is the kern feature's lookup indices, SCRIPTS
  # the script records, each a tag and its default language system or nil.
  def sample(named: [0, 1], scripts: [['DFLT', true], ['latn', true]], lookups: GposTables.lookups)
    gpos(scripts: scripts.map { |tag, default| [tag, script(default ? language_system([0]) : nil)] },
         features: [['kern', feature(named)]], lookups: lookups)
  end

# A lookup of TYPE whose TIMES subtable offsets all name SUBTABLE.
def repeated_lookup(type, subtable, times)
  header = 6 + 2 * times
  u16(type, 0, times, *Array.new(times, header)) + subtable
end

  # A table whose one kern lookup is an extension whose subtable names
  # itself as an extension.
  def self_extension
    looping = u16(1, EXTENSION) + [0].pack('N')
    sample(lookups: [lookup(EXTENSION, [looping])], named: [0])
  end
end
