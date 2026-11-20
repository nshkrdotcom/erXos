# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ABI
    # The DMA marks of a descriptor format (docs/design-device-dma.md, "What
    # the formats say"): each format file declares the structures its regions
    # hold (`target NAME cpu|device`), and each layout a device reads or
    # writes as a record marks what its fields mean to the DMA check, so that
    # a record is written only by the encoder generated from those marks.
    #
    # A mark names a place: a field that has no bits lines, written FIELD, or
    # one bits range of a field, written FIELD.BITS. A place no mark claims is
    # free: a description states its value. Build_layout leaves the mark lines
    # to this module, which reads them from the layout declarations once every
    # type is resolved, since a mark may name an enum declared after its layout.
    module Marks
      # Each mark's spelling, as a refusal states it.
      SYNTAX = {
        'selects' => 'FIELD.BITS ENUM.MEMBER',
        'fixed' => 'FIELD.BITS VALUE',
        'refers' => 'FIELD.BITS TARGET [length FIELD.BITS [unit N]]',
        'activates' => 'FIELD.BITS',
        'derived' => 'FIELD.BITS',
        'releases' => 'FIELD.BITS TARGET [when FIELD.BITS ENUM.MEMBER...]'
      }.freeze
      KEYWORDS = SYNTAX.keys.freeze
      WRITERS = %w[cpu device].freeze
      DATA = 'data'

      Target = Struct.new(:name, :writer, :line, keyword_init: true)

      # One place of a marked layout. A bits range keeps the accessor's view:
      # the value it takes is shifted left by shift, so its low shift bits
      # are zero.
      Place = Struct.new(:field, :bits, :type, :low, :high, :shift, keyword_init: true) do
        def name = bits ? "#{field}_#{bits}" : field
        def spelling = bits ? "#{field}.#{bits}" : field
        def maximum = ((1 << (high - low + 1)) - 1) << shift
        def holds?(value) = value.between?(0, maximum) && (value & ((1 << shift) - 1)).zero?
      end

      # A value the encoder writes itself: the selector's member or a fixed value.
      Value = Struct.new(:place, :value, keyword_init: true)
      # A reference given as a name: the place that holds its address, the
      # structure it names (a target or data), and the place that holds its
      # length, counted in units of unit bytes, or nil.
      Reference = Struct.new(:place, :target, :length, :unit, keyword_init: true)
      # On a report: the place that names the holding the report ends, the
      # structure that holding is of, and the codes it ends it under, nil for
      # every code.
      Release = Struct.new(:place, :target, :condition, :codes, keyword_init: true)

      # One marked layout as a meaning. free and placed are the encoder's two
      # inputs, in the layout's field order: what a description states, and
      # what the sequencer supplies where it places the record (each
      # reference's address, the activation and each derived field).
      Meaning = Struct.new(:layout, :number, :selector, :fixed, :references, :activation,
                           :derived, :release, :free, :placed, keyword_init: true) do
        def constant = "meaning_#{Names.stem(layout.name)}"
      end

      # One mark line of a layout and its parsed value.
      Mark = Struct.new(:keyword, :line, :value, keyword_init: true)
      Schema = Struct.new(:targets, :meanings, keyword_init: true)

      module_function

      # The targets and the meanings, each meaning numbered from 1 in the
      # order of its layout's name, so 0 is no meaning.
      def validate(target_declarations, layout_declarations, types, constants)
        targets = validate_targets(target_declarations)
        marked = layout_declarations.select { |declaration| declaration.members.any? { |line| mark?(line) } }
        meanings = marked.sort_by { |declaration| declaration.args.first }.each_with_index.map do |declaration, index|
          meaning(declaration, types.fetch(declaration.args.first), index + 1,
                  targets: targets, types: types, constants: constants)
        end
        Schema.new(targets: targets.freeze, meanings: meanings.freeze).freeze
      end

      def mark?(line) = line.indent == 2 && KEYWORDS.include?(line.words.first)

      def validate_targets(declarations)
        declarations.each_with_object({}) do |declaration, targets|
          declaration.fail!('target requires NAME cpu|device') unless declaration.args.size == 2
          declaration.fail!('a target has no members') unless declaration.members.empty?
          name, writer = declaration.args
          Names.local(name, line: declaration.line)
          declaration.fail!("target #{DATA} is the buffers' own name") if name == DATA
          declaration.fail!("unknown target writer #{writer}") unless WRITERS.include?(writer)
          targets[name] = Target.new(name: name, writer: writer, line: declaration.line).freeze
        end
      end

      def meaning(declaration, layout, number, targets:, types:, constants:)
        declaration.fail!('marks belong to a wire_le layout') unless layout.storage == 'wire_le'
        layout.fields.reject { |field| field.type.is_a?(IntegerType) && !field.type.signed && !field.array? }
              .each { |field| field.line.fail!('a marked layout holds unsigned integer fields only') }
        places = layout_places(layout)
        marks = declaration.members.select { |line| mark?(line) }.map do |line|
          Mark.new(keyword: line.words.first, line: line,
                   value: parse_mark(line, places, targets: targets, types: types, constants: constants)).freeze
        end
        refuse_twice(marks)
        selector, activation, release = %w[selects activates releases].map { |keyword| one(marks, keyword) }
        fixed, references, derived = %w[fixed refers derived].map do |keyword|
          marks.select { |mark| mark.keyword == keyword }.map(&:value).freeze
        end
        # Placed: what the sequencer supplies. Written: what the encoder writes
        # from the marks. Free: every other place. Each keeps field order.
        placed = references.map(&:place) + [activation].compact + derived
        written = [selector, *fixed].compact.map(&:place)
        Meaning.new(layout: layout, number: number, selector: selector, fixed: fixed,
                    references: references, activation: activation, derived: derived, release: release,
                    free: places.values.reject { |place| placed.include?(place) || written.include?(place) }.freeze,
                    placed: places.values.select { |place| placed.include?(place) }.freeze).freeze
      end

      # One mark line's value: a Value for selects and fixed, a Reference, a
      # Place for activates and derived, or a Release.
      def parse_mark(line, places, targets:, types:, constants:)
        keyword, *words = line.words
        case [keyword, words.size]
        in ['selects', 2]
          place = fetch_place(places, words[0], line)
          Value.new(place: place, value: member(words[1], place, types, line)).freeze
        in ['fixed', 2]
          place = fetch_place(places, words[0], line)
          value = Model.numeric(words[1], constants, line)
          line.fail!("fixed value #{words[1]} does not fit #{place.spelling}") unless place.holds?(value)
          Value.new(place: place, value: value).freeze
        in ['refers', _] then parse_reference(words, places, targets, line)
        in ['activates', 1]
          place = fetch_place(places, words[0], line)
          line.fail!("activates marks one bit, not #{place.spelling}") unless place.maximum == 1
          place
        in ['derived', 1] then fetch_place(places, words[0], line)
        in ['releases', _] then parse_release(words, places, targets, types, line)
        else line.fail!("#{keyword} requires #{SYNTAX.fetch(keyword)}")
        end
      end

      # The places a mark claims; no place is claimed twice in a layout.
      def claims(value)
        case value
        in Reference then [value.place, value.length].compact
        in Value | Release then [value.place]
        in Place then [value]
        end
      end

      def refuse_twice(marks)
        marks.each_with_object({}) do |mark, claimed|
          claims(mark.value).each do |place|
            mark.line.fail!("#{place.spelling} is marked twice") if claimed.key?(place.name)
            claimed[place.name] = true
          end
        end
      end

      # The value of the layout's one mark of this keyword, or nil.
      def one(marks, keyword)
        found = marks.select { |mark| mark.keyword == keyword }
        found[1]&.line&.fail!("a layout has one #{keyword} mark")
        found.first&.value
      end

      # refers FIELD.BITS TARGET [length FIELD.BITS [unit N]]
      def parse_reference(words, places, targets, line)
        target, length, unit = case words
                               in [_, target] then [target, nil, 1]
                               in [_, target, 'length', length] then [target, length, 1]
                               in [_, target, 'length', length, 'unit', unit] then [target, length, Syntax.integer(unit, line: line)]
                               else line.fail!("refers requires #{SYNTAX.fetch('refers')}")
                               end
        line.fail!('a length unit is a positive byte count') unless unit.positive?
        Reference.new(place: fetch_place(places, words[0], line), target: target_name(target, targets, line),
                      length: length && fetch_place(places, length, line), unit: unit).freeze
      end

      # releases FIELD.BITS TARGET [when FIELD.BITS ENUM.MEMBER...]
      def parse_release(words, places, targets, types, line)
        line.fail!("releases requires #{SYNTAX.fetch('releases')}") unless words.size == 2 || (words.size >= 5 && words[2] == 'when')
        condition = words.size > 2 ? fetch_place(places, words[3], line) : nil
        codes = condition && words.drop(4).map { |code| member(code, condition, types, line) }
        line.fail!('releases when lists each code once') if codes && codes.uniq.size != codes.size
        Release.new(place: fetch_place(places, words[0], line), target: target_name(words[1], targets, line),
                    condition: condition, codes: codes&.freeze).freeze
      end

      # A target of the mark's own file, or data.
      def target_name(name, targets, line)
        return name if name == DATA

        target = targets[name]
        line.fail!("unknown target #{name}") unless target
        line.fail!("target #{name} belongs to #{target.line.path}") unless target.line.path == line.path
        name
      end

      # ENUM.MEMBER, a member of an enum (not flags) whose value fits the place.
      def member(spelling, place, types, line)
        enum_name, _, member_name = spelling.rpartition('.')
        enum = types[enum_name]
        line.fail!("#{spelling} is not ENUM.MEMBER of an enum") unless enum.is_a?(EnumType) && !enum.flags
        line.fail!("#{member_name} is not a member of #{enum_name}") unless enum.members.key?(member_name)
        value = enum.members.fetch(member_name)
        line.fail!("#{spelling} does not fit #{place.spelling}") unless place.holds?(value)
        value
      end

      def fetch_place(places, spelling, line)
        places[spelling] || line.fail!("#{spelling} is not a field or bits of this layout")
      end

      # Every place of the layout, by spelling, in field order: a field
      # without bits whole, otherwise each of its bits ranges.
      def layout_places(layout)
        layout.fields.flat_map do |field|
          if field.bits.empty?
            [Place.new(field: field.name, bits: nil, type: field.type, low: 0,
                       high: field.type.bits - 1, shift: 0).freeze]
          else
            field.bits.map do |bits|
              Place.new(field: field.name, bits: bits.fetch(:name), type: field.type, low: bits.fetch(:low),
                        high: bits.fetch(:high), shift: bits.fetch(:shift)).freeze
            end
          end
        end.to_h { |place| [place.spelling, place] }
      end
    end
  end
end
