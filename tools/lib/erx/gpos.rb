# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'set'
require_relative 'error'

module Erx
  # The glyph step's kerning reader (docs/design-desktop-programs.md,
  # "Kerning"): the kerning of every ordered pair of a role's drawn glyphs,
  # in font units, from the font's GPOS table as the OpenType specification
  # applies its kern feature (OpenType 1.9, "GPOS" and "OpenType layout
  # common table formats"):
  #
  # * the kern features of the default language system of the latn script,
  #   or of DFLT when the font has no latn; a font with neither has no
  #   pairs, and a chosen script without a default language system is
  #   refused;
  # * the union of those features' lookups, each applied once, in the order
  #   of the lookup list, each adding its value to the pair's;
  # * within a lookup, the first subtable that matches gives its value: a
  #   format 1 subtable when its coverage holds the first glyph and that
  #   glyph's pair set the second, a format 2 subtable when its coverage
  #   holds the first glyph, a glyph its class definition does not list
  #   being of class 0;
  # * an extension lookup is read as the pair adjustment it wraps, and an
  #   extension never wraps another, so the reader follows no cycle;
  # * only the lookup flags that skip marks alone are accepted, and a role
  #   one of whose glyphs the GDEF table classes a mark is refused, so no
  #   accepted flag skips a glyph of the role.
  #
  # The tables are a third-party font's bytes, untrusted. Every read goes
  # through View, whose one bound check refuses an offset or count reaching
  # past the table before anything is read, so every input ends in pairs or
  # in Refused. Time is bounded by the table too: Reader parses each table
  # once however many offsets name it, a lookup's repeated subtable can
  # match nothing new and is skipped, and a coverage or class definition
  # must list its glyphs in ascending order without overlap, as the
  # specification requires, so each glyph is found by halving. A pair set
  # naming a glyph twice gives its first record. tools/fuzz/gpos_fuzz.rb is
  # the reader's fuzz target.
  module Gpos
    class Refused < Error; end

    KERN = 'kern'
    # The scripts read, the first the font has.
    SCRIPTS = %w[latn DFLT].freeze
    NO_FEATURE = 0xffff
    PAIR = 2
    EXTENSION = 9
    # The lookup flags that skip only marks: ignore marks, use a mark
    # filtering set and a mark attachment type.
    MARK_FLAGS = 0x0008 | 0x0010 | 0xff00
    # The value formats accepted: an advance of the first glyph, one int16,
    # and nothing of the second.
    VALUE_FORMATS = [0x0004, 0].freeze
    # GDEF's glyph class of a mark.
    MARK = 3

    # An entry of a coverage or class definition: glyphs FIRST to LAST hold
    # VALUE, the coverage index of FIRST or the class of each.
    Span = Data.define(:first, :last, :value)
    # A format 1 subtable's matches among the role's glyphs: {[first,
    # second] => value}, a value of 0 included, since it still matches.
    Singles = Data.define(:pairs)
    # A format 2 subtable over the role's glyphs: FIRSTS, the glyphs its
    # coverage holds, each matching every second glyph; CLASS1, {glyph =>
    # class} of its first class definition; SECONDS, the role's glyphs by
    # their class in the second; and MATRIX, COUNT2 values a first class.
    Classes = Data.define(:firsts, :class1, :seconds, :matrix, :count2) do
      # {second => value} of FIRST, only the values that are not 0.
      def row(first)
        values = matrix[class1.fetch(first, 0) * count2, count2].each_with_index.reject { |value, _| value.zero? }
        values.flat_map { |value, number| seconds.fetch(number, []).product([value]) }.to_h
      end
    end

    module_function

    # {[first, second] => units} for the ordered pairs of GLYPHS (font glyph
    # indices) whose kerning is not 0, in ascending order. GPOS and GDEF are
    # the tables' bytes, each empty when the font has none.
    def pairs(gpos:, gdef:, glyphs:)
      reader = Reader.new(glyphs.uniq.sort.freeze)
      reader.refuse_marks(View.new(gdef.b)) unless gdef.empty?
      gpos.empty? ? {} : reader.pairs(View.new(gpos.b))
    end

    def refuse(reason) = raise(Refused, reason)

    # The reading of one font's tables for one set of glyphs, DRAWN, sorted.
    # It keeps each table it has parsed by where the table starts.
    class Reader
      def initialize(drawn)
        @drawn = drawn
        @parsed = {}
      end

      def pairs(root)
        major, _minor, script_list, feature_list, lookup_list = root.u16s(0, 5)
        Gpos.refuse("GPOS version #{major} is not 1") unless major == 1
        totals = Hash.new(0)
        # A lookup named by two indices is two lookups: its values count twice.
        kern_lookups(root.at(script_list), root.at(feature_list))
          .map { |index| lookup(root.at(lookup_list), index) }.group_by { |view, _| view.start }
          .each_value do |named|
            view, where = named.first
            times = named.size
            lookup_values(view, where: where).each { |pair, value| totals[pair] += times * value }
          end
        totals.reject { |_, value| value.zero? }.sort.to_h.freeze
      end

      def refuse_marks(gdef)
        major, _minor, glyph_class_definition = gdef.u16s(0, 3)
        Gpos.refuse("GDEF version #{major} is not 1") unless major == 1
        return if glyph_class_definition.zero?

        marks = class_of(gdef.at(glyph_class_definition), count: nil).select { |_, value| value == MARK }
        Gpos.refuse("glyph #{marks.keys.min} is classed a mark in GDEF") unless marks.empty?
      end

      private

      # The indices of the chosen script's kern features' lookups, each
      # once, ascending.
      def kern_lookups(scripts, features)
        found = SCRIPTS.lazy.filter_map { |tag| tagged(scripts, tag) }.first
        return [] if found.nil?

        tag, script = found
        default = script.u16(0)
        Gpos.refuse("script #{tag} has no default language system") if default.zero?
        _order, required, count = script.at(default).u16s(0, 3)
        indices = script.at(default).u16s(6, count)
        named = required == NO_FEATURE ? indices : [required, *indices]
        named.map { |index| feature(features, index) }
             .select { |feature_tag, _| feature_tag == KERN }
             .flat_map { |feature| lookup_indices(feature) }.uniq.sort
      end

      # The first record of a script list named TAG, as [tag, its table], or nil.
      def tagged(list, tag)
        list.records(2, list.u16(0)).find { |name, _| name == tag }&.then { |name, offset| [name, list.at(offset)] }
      end

      # Feature INDEX of the feature list, as [tag, its table].
      def feature(features, index)
        count = features.u16(0)
        Gpos.refuse("feature index #{index} is at or past the feature count #{count}") unless index < count
        tag, offset = features.records(2 + 6 * index, 1).first
        [tag, features.at(offset)]
      end

      def lookup_indices((_, table)) = table.u16s(4, table.u16(2))

      # Lookup INDEX, as its table and the name refusals give it.
      def lookup(lookups, index)
        count = lookups.u16(0)
        Gpos.refuse("lookup index #{index} is at or past the lookup count #{count}") unless index < count
        [lookups.at(lookups.u16(2 + 2 * index)), "lookup #{index}"]
      end

      # {[first, second] => value} of one lookup, values of 0 left out: each
      # pair's value from the first of the lookup's subtables that matches it.
      def lookup_values(lookup, where:)
        type, flag, count = lookup.u16s(0, 3)
        Gpos.refuse("#{where}: lookup type #{type} is not a pair adjustment") unless [PAIR, EXTENSION].include?(type)
        Gpos.refuse(format('%s: lookup flag 0x%04X is not a mark flag', where, flag)) unless (flag & ~MARK_FLAGS).zero?

        values = {}
        matched_pairs = Set.new
        matched_firsts = Set.new
        subtables = lookup.u16s(6, count).each_with_index.map do |offset, number|
          labelled("#{where} subtable #{number}") { subtable(lookup.at(offset), type) }
        end
        subtables.uniq.each do |matches|
          case matches
          in Singles(pairs: singles)
            fresh = singles.reject { |pair, _| matched_firsts.include?(pair.first) || matched_pairs.include?(pair) }
            values.merge!(fresh)
            matched_pairs.merge(fresh.keys)
          in Classes => classes
            (classes.firsts - matched_firsts.to_a).each do |first|
              classes.row(first).each { |second, value| values[[first, second]] = value unless matched_pairs.include?([first, second]) }
              matched_firsts << first
            end
          end
        end
        values.reject { |_, value| value.zero? }
      end

      # The block's value, a refusal inside it named by WHERE.
      def labelled(where)
        yield
      rescue Refused => e
        raise Refused, "#{where}: #{e.message}"
      end

      # The matches of the subtable of a lookup of TYPE at VIEW, read
      # through an extension.
      def subtable(view, type)
        case type
        when PAIR then parsed(view, :subtable) { pair_adjustment(view) }
        when EXTENSION
          format, inner = view.u16s(0, 2)
          Gpos.refuse("extension format #{format} is not 1") unless format == 1
          Gpos.refuse('an extension wraps another extension') if inner == EXTENSION
          subtable(view.at(view.u32(4)), inner)
        else Gpos.refuse("lookup type #{type} is not a pair adjustment")
        end
      end

      def pair_adjustment(view)
        format, coverage_offset, *value_formats = view.u16s(0, 4)
        unless value_formats == VALUE_FORMATS
          Gpos.refuse(format('value formats 0x%04X and 0x%04X are not an advance of the first glyph alone', *value_formats))
        end
        covered = coverage(view.at(coverage_offset))
        case format
        when 1 then singles(view, covered)
        when 2 then classes(view, covered)
        else Gpos.refuse("pair adjustment format #{format} is not 1 or 2")
        end
      end

      # Format 1: each covered first glyph's pair set, records of a second
      # glyph and its value.
      def singles(view, covered)
        count = view.u16(8)
        pairs = covered.each_with_object({}) do |(first, index), found|
          Gpos.refuse("coverage index #{index} is at or past the pair set count #{count}") unless index < count
          pair_set(view.at(view.u16(10 + 2 * index))).each { |second, value| found[[first, second]] = value }
        end
        Singles.new(pairs: pairs)
      end

      # {second => value} of a pair set, for the drawn second glyphs.
      def pair_set(view)
        parsed(view, :pair_set) do
          records = view.glyph_values(2, view.u16(0)).select { |second, _| drawn?(second) }
          records.reverse.to_h
        end
      end

      # Format 2: the covered first glyphs and their values by the second
      # glyph's class; each class definition's class 0 must lie below its
      # count, as every glyph it does not list is of class 0.
      def classes(view, covered)
        first_definition, second_definition, count1, count2 = view.u16s(8, 4)
        Gpos.refuse("class counts #{count1} and #{count2} leave no class 0") if count1.zero? || count2.zero?
        class1 = labelled('first class definition') { class_of(view.at(first_definition), count: count1) }
        class2 = labelled('second class definition') { class_of(view.at(second_definition), count: count2) }
        Classes.new(firsts: covered.keys, class1: class1, seconds: @drawn.group_by { |glyph| class2.fetch(glyph, 0) },
                    matrix: view.s16s(16, count1 * count2), count2: count2)
      end

      # {glyph => coverage index} for the drawn glyphs the coverage holds.
      def coverage(view)
        parsed(view, :coverage) do
          format, count = view.u16s(0, 2)
          spans = case format
                  when 1 then view.u16s(4, count).each_with_index.map { |glyph, index| Span.new(glyph, glyph, index) }
                  when 2 then view.u16s(4, 3 * count).each_slice(3).map { |first, last, index| Span.new(first, last, index) }
                  else Gpos.refuse("coverage format #{format} is not 1 or 2")
                  end
          held(spans, 'coverage') { |span, glyph| span.value + glyph - span.first }
        end
      end

      # {glyph => class} for the drawn glyphs a class definition lists;
      # every class it lists must lie below COUNT, unless COUNT is nil.
      def class_of(view, count:)
        parsed(view, [:classes, count]) do
          format = view.u16(0)
          spans = case format
                  when 1
                    start, length = view.u16s(2, 2)
                    view.u16s(6, length).each_with_index.map { |value, index| Span.new(start + index, start + index, value) }
                  when 2 then view.u16s(4, 3 * view.u16(2)).each_slice(3).map { |first, last, value| Span.new(first, last, value) }
                  else Gpos.refuse("class definition format #{format} is not 1 or 2")
                  end
          large = spans.find { |span| count && span.value >= count }
          Gpos.refuse("class #{large.value} at or past the class count #{count}") if large
          held(spans, 'class definition') { |span, _| span.value }
        end
      end

      # {glyph => the block's value of its span} for each drawn glyph that
      # SPANS, which must ascend without overlap, hold.
      def held(spans, what)
        ordered = spans.all? { |span| span.first <= span.last } && spans.each_cons(2).all? { |before, after| before.last < after.first }
        Gpos.refuse("#{what} lists its glyphs out of ascending order or more than once") unless ordered

        @drawn.each_with_object({}) do |glyph, found|
          span = spans.bsearch { |each| each.last >= glyph }
          found[glyph] = yield(span, glyph) if span && span.first <= glyph
        end
      end

      def drawn?(glyph) = @drawn.bsearch { |each| each >= glyph } == glyph

      # The block's value for the table of KIND at VIEW, computed once: a
      # table named by many offsets costs one parse.
      def parsed(view, kind) = @parsed.fetch([view.start, kind]) { |key| @parsed[key] = yield }
    end

    # A table at START of BYTES, a binary string, read big-endian. Every
    # read names an offset from START and a size, and the one check in take
    # refuses it when it reaches past the bytes, before anything is read.
    class View
      attr_reader :start

      def initialize(bytes, start = 0)
        @bytes = bytes
        @start = start
        take(0, 0)
      end

      def at(offset) = View.new(@bytes, @start + offset)

      def u16(offset) = take(offset, 2).unpack1('n')

      def u32(offset) = take(offset, 4).unpack1('N')

      def u16s(offset, count) = take(offset, 2 * count).unpack('n*')

      def s16s(offset, count) = take(offset, 2 * count).unpack('s>*')

      # COUNT records of a glyph and a signed value, as a pair set holds them.
      def glyph_values(offset, count) = take(offset, 4 * count).unpack('ns>' * count).each_slice(2).to_a

      # COUNT records of a tag and an offset, as a script or feature list
      # holds them.
      def records(offset, count) = take(offset, 6 * count).unpack('a4n' * count).each_slice(2).to_a

      private

      def take(offset, size)
        start = @start + offset
        Gpos.refuse("offset #{start} and #{size} bytes reach past the table of #{@bytes.bytesize}") if start + size > @bytes.bytesize
        @bytes.byteslice(start, size)
      end
    end
  end
end
