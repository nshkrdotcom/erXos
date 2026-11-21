# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ABI
    # The DMA marks of a descriptor format (docs/design-device-dma.md, "What
    # the formats say"): each format file declares the structures its regions
    # hold (`target NAME cpu|device [needs_binding]`), and each layout a
    # device reads or writes as a record marks what its fields mean to the
    # DMA check. A cpu structure marked needs_binding, a transfer ring, takes
    # runs only while a binding command has bound its table to an endpoint.
    #
    # A layout's meaning line names the one structure whose tables offer it,
    # and that structure's writer is the layout's: a meaning of a `device`
    # structure is a report, which the device writes and the trusted side only
    # reads, so it gets accessors and no encoder; every other marked layout,
    # a meaning a description states or a record of the sequencer's own, is
    # written only by the encoder generated from its marks. A marked layout
    # with no meaning line is the CPU's and has no meaning number.
    #
    # A mark names a place: a field that has no bits lines, written FIELD, or
    # one bits range of a field, written FIELD.BITS. Every place of a marked
    # layout is claimed by exactly one mark, so a place is free only where a
    # states mark, a reference's length or a release says so: a description
    # states it, or, on a report, the device. A place whose field or bits line
    # ends in device_address holds an address the device follows; in a marked
    # layout the sequencer writes it (a reference or a derived place), or the
    # device reports it (a release's place). Build_layout leaves the mark
    # lines to this module, which reads them from the layout declarations
    # once every type is resolved, since a mark may name an enum declared
    # after its layout.
    module Marks
      # What a command's success or failure does to the endpoints it names
      # (docs/design-usb.md, "What the DMA check judges"), the reach the ledger
      # derives from its meaning: address binds EP0's ring; configure adds
      # endpoints, binding their rings, and may drop others; stop leaves its running endpoint stopped; reset
      # leaves its halted endpoint stopped; restart moves its stopped endpoint's ring past every transfer on it;
      # disable ends its slot; evaluate holds EP0 idle while it rewrites EP0's context.
      REACHES = %w[address configure stop reset restart disable evaluate].freeze
      # Each mark's spelling, as a refusal states it.
      SYNTAX = {
        'meaning' => 'TARGET',
        'selects' => 'FIELD.BITS ENUM.MEMBER',
        'fixed' => 'FIELD.BITS VALUE',
        'refers' => 'FIELD.BITS TARGET [length FIELD.BITS [unit N]]',
        'activates' => 'FIELD.BITS',
        'derived' => 'FIELD.BITS',
        'states' => 'FIELD.BITS',
        'releases' => 'FIELD.BITS TARGET [when FIELD.BITS ENUM.MEMBER...]',
        'reach' => REACHES.join('|')
      }.freeze
      KEYWORDS = SYNTAX.keys.freeze
      WRITERS = %w[cpu device].freeze
      NEEDS_BINDING = 'needs_binding'
      DATA = 'data'
      # The roles a mark gives a place. A free place is one a description
      # states, or, on a report, the device; a placed one the sequencer
      # supplies; a written one the encoder takes from the mark.
      FREE = %i[stated reported code].freeze
      # The roles a device address may take: the sequencer writes it, or the
      # device reports it.
      ADDRESS_ROLES = %i[placed reported].freeze

      # A structure a region may hold, its writer, and whether its tables
      # need a binding.
      Target = Struct.new(:name, :writer, :needs_binding, :line, keyword_init: true) do
        def device? = writer == 'device'
        def needs_binding? = needs_binding
      end

      # One place of a marked layout, with the field or bits line that declares
      # it and its field's byte offset. A bits range keeps the accessor's view:
      # the value it takes is shifted left by shift, so its low shift bits are
      # zero.
      Place = Struct.new(:field, :bits, :type, :offset, :low, :high, :shift, :device_address, :line,
                         keyword_init: true) do
        def name = bits ? "#{field}_#{bits}" : field
        def spelling = bits ? "#{field}.#{bits}" : field
        def maximum = ((1 << (high - low + 1)) - 1) << shift
        def holds?(value) = value.between?(0, maximum) && (value & ((1 << shift) - 1)).zero?
        # Where the place lies in its record: the field's offset and width and
        # the bits it covers, the same for two places only if they read the
        # same bits of a record.
        def position = [offset, type.bits, low, high]
      end

      # A value the encoder writes itself, from its mark's line: the
      # selector's member, with the enum it is of, or a fixed value, whose
      # enum is nil. raw is what the place's bits hold, the value without
      # its shift.
      Value = Struct.new(:place, :value, :enum, :line, keyword_init: true) do
        def raw = value >> place.shift
      end
      # A reference given as a name: the place that holds its address, the
      # structure it names (a target or data), and the place that holds its
      # length, counted in units of unit bytes, or nil.
      Reference = Struct.new(:place, :target, :length, :unit, keyword_init: true)
      # On a report: the place that names the holding the report ends, the
      # cpu structure that holding is of, and the codes it ends it under, nil
      # for every code.
      Release = Struct.new(:place, :target, :condition, :codes, keyword_init: true)
      Reach = Struct.new(:kind, :line, keyword_init: true)

      # One marked layout. structure is the target its meaning line names and
      # meaning_line that line, both nil for a layout that is no meaning (the
      # sequencer's own record, or a part of a composed one); number is its
      # meaning's, nil when it is none. free and placed are the encoder's two
      # inputs, in the layout's field order: what a description states, and
      # what the sequencer supplies where it places the record (each
      # reference's address, the activation and each derived field). A report
      # has no encoder, and its free places are what the device states.
      MarkedLayout = Data.define(:layout, :structure, :meaning_line, :number, :selector, :fixed,
                                 :references, :activation, :derived, :release, :reach, :free, :placed) do
        def meaning? = !structure.nil?
        def report? = meaning? && structure.device?
        def constant = "meaning_#{Names.stem(layout.name)}"
      end

      # One mark line of a layout and its parsed value.
      Mark = Struct.new(:keyword, :line, :value, keyword_init: true)

      # The structures, by name, and the marked layouts, in the order of their
      # layouts' names.
      Schema = Struct.new(:targets, :layouts, keyword_init: true) do
        # The layouts with a meaning line, each with its number.
        def meanings = layouts.select(&:meaning?)
        # What every table of target offers: the meanings whose line names it.
        def offered(target) = meanings.select { |meaning| meaning.structure.name == target.name }
        # The descriptor formats: each source file that holds a marked layout. Every
        # layout of one is a device record: a record of a ring or table a device
        # follows, or payload a driver posts in a buffer. The C reader encodes none,
        # and only the sequencer calls a generated C encoder of one
        # (docs/design-device-dma.md#descriptions).
        def descriptor_formats = layouts.to_set { |marked| marked.layout.line.path }
        def device_record?(layout) = descriptor_formats.include?(layout.line.path)
      end

      module_function

      def validate(target_declarations, layout_declarations, types, constants)
        targets = validate_targets(target_declarations).freeze
        layouts = layout_declarations.select { |declaration| declaration.members.any? { |line| mark?(line) } }
                                     .sort_by { |declaration| declaration.args.first }.map do |declaration|
          marked_layout(declaration, types.fetch(declaration.args.first),
                        targets: targets, types: types, constants: constants)
        end
        refuse_reused_selectors(layouts)
        schema = Schema.new(targets: targets, layouts: number(layouts).freeze).freeze
        targets.each_value { |target| check_meanings(target, schema.offered(target)) }
        schema
      end

      def mark?(line) = line.indent == 2 && KEYWORDS.include?(line.words.first)

      def validate_targets(declarations)
        declarations.each_with_object({}) do |declaration, targets|
          name, writer, *rest = declaration.args
          declaration.fail!("target requires NAME cpu|device [#{NEEDS_BINDING}]") unless writer && rest.size <= 1
          declaration.fail!('a target has no members') unless declaration.members.empty?
          Names.local(name, line: declaration.line)
          declaration.fail!("target #{DATA} is the buffers' own name") if name == DATA
          declaration.fail!("unknown target writer #{writer}") unless WRITERS.include?(writer)
          mark = rest.first
          declaration.fail!("unknown target mark #{mark}") unless mark.nil? || mark == NEEDS_BINDING
          needs_binding = mark == NEEDS_BINDING
          # A binding gives the CPU's runs a ring; the device writes its reports in order.
          declaration.fail!('a structure the device writes needs no binding') if needs_binding && writer == 'device'
          targets[name] = Target.new(name: name, writer: writer, needs_binding: needs_binding,
                                     line: declaration.line).freeze
        end
      end

      def marked_layout(declaration, layout, targets:, types:, constants:)
        declaration.fail!('marks belong to a wire_le layout') unless layout.storage == 'wire_le'
        layout.tail&.line&.fail!('a marked layout has no tail: its encoder writes the fixed part only')
        layout.fields.reject { |field| field.type.is_a?(IntegerType) && !field.type.signed && !field.array? }
              .each { |field| field.line.fail!('a marked layout holds unsigned integer fields only') }
        places = layout_places(layout)
        marks = declaration.members.select { |line| mark?(line) }.map do |line|
          Mark.new(keyword: line.words.first, line: line,
                   value: parse_mark(line, places, targets: targets, types: types, constants: constants)).freeze
        end
        structure, selector, activation, release = %w[meaning selects activates releases].map { |keyword| one(marks, keyword) }
        fixed, references, derived = %w[fixed refers derived].map do |keyword|
          marks.select { |mark| mark.keyword == keyword }.map(&:value).freeze
        end
        refuse_writer_marks(declaration, marks, report: structure&.device?)
        reach = one(marks, 'reach')
        refuse_misplaced_reach(reach, structure)
        roles = claim_once(marks, places)
        MarkedLayout.new(layout: layout, structure: structure, number: nil,
                         meaning_line: marks.find { |mark| mark.keyword == 'meaning' }&.line,
                         selector: selector, fixed: fixed, references: references, activation: activation,
                         derived: derived, release: release, reach: reach&.kind,
                         free: places.values.select { |place| FREE.include?(roles[place.spelling]) }.freeze,
                         placed: places.values.select { |place| roles[place.spelling] == :placed }.freeze)
      end

      # The layouts with each meaning numbered, from 1 in the layouts' order.
      def number(layouts)
        numbers = layouts.select(&:meaning?).each.with_index(1).to_h { |marked, number| [marked.layout.name, number] }
        layouts.map { |marked| marked.with(number: numbers[marked.layout.name]) }
      end

      # A report is written by the device, so it has no reference or derived
      # place for the sequencer to supply; and only a report ends a holding.
      # A reach belongs to a command: a meaning of a structure the CPU writes
      # that needs no binding, the command ring. On a transfer ring or a report
      # it would let a run that is no command close or bind an endpoint.
      def refuse_misplaced_reach(reach, structure)
        return if reach.nil? || (structure && !structure.device? && !structure.needs_binding?)

        reach.line.fail!('a reach belongs to a command: a meaning of a cpu structure that needs no binding')
      end

      def refuse_writer_marks(declaration, marks, report:)
        keywords = marks.map(&:keyword)
        if report && (keywords & %w[refers derived]).any?
          declaration.fail!('a report, a meaning of a device structure, has no refers or derived mark: the device writes it')
        end
        return if report

        marks.find { |mark| mark.keyword == 'releases' }&.line
             &.fail!('releases belongs to a report, a meaning of a device structure')
      end

      # A selector value names one layout of its file, a meaning or not: no
      # two layouts of a file select one enum member, nor the same bits on the
      # same place of a record, whatever enum or shift spells them. Each
      # refusal names the second layout's selects line.
      SELECTOR_KEYS = {
        'the enum member' => ->(selector) { [selector.enum, selector.value] },
        'the bits' => ->(selector) { [selector.place.position, selector.raw] }
      }.freeze

      def refuse_reused_selectors(layouts)
        selected = layouts.select(&:selector)
        SELECTOR_KEYS.each do |what, key|
          selected.group_by { |marked| [marked.layout.line.path, key.call(marked.selector)] }.each_value do |first, second, *|
            next unless second

            second.selector.line.fail!("#{second.layout.name} selects #{what} #{first.layout.name} selects: " \
                                       'a selector value names one layout of its file')
          end
        end
      end

      # What placement and acquisition need of one structure's meanings, each
      # the same in all of them: the size, the table's stride; where the
      # selector lies; and where the activation lies, or that none has one.
      MEANINGS_ALIKE = {
        'size' => ->(meaning) { meaning.layout.size },
        'where their selector lies' => ->(meaning) { meaning.selector.place.position },
        'their activation: every meaning of a structure has it on the same bit, or none has one' =>
          ->(meaning) { meaning.activation&.position }
      }.freeze

      # A structure with more than one meaning has a selector in each, and its
      # meanings are alike in MEANINGS_ALIKE. Each refusal names the meaning
      # line of a meaning that departs from the first.
      def check_meanings(target, meanings)
        return if meanings.size < 2

        meanings.reject(&:selector).each do |unselected|
          unselected.meaning_line.fail!("#{unselected.layout.name} has no selects mark, and " \
                                        "#{target.name} has more than one meaning")
        end
        first, *others = meanings
        others.each do |meaning|
          what, = MEANINGS_ALIKE.find { |_what, of| of.call(meaning) != of.call(first) }
          next unless what

          meaning.meaning_line.fail!("#{meaning.layout.name} and #{first.layout.name}, meanings of " \
                                     "#{target.name}, differ in #{what}")
        end
      end

      # One mark line's value: the Target for meaning, a Value for selects and
      # fixed, a Reference, a Place for activates, derived and states, or a
      # Release.
      def parse_mark(line, places, targets:, types:, constants:)
        keyword, *words = line.words
        case [keyword, words.size]
        in ['meaning', 1]
          line.fail!("a meaning names a structure, not #{DATA}") if words[0] == DATA
          targets.fetch(target_name(words[0], targets, line))
        in ['selects', 2]
          place = fetch_place(places, words[0], line)
          enum, value = member(words[1], place, types, line)
          Value.new(place: place, value: value, enum: enum, line: line).freeze
        in ['fixed', 2]
          place = fetch_place(places, words[0], line)
          value = Model.numeric(words[1], constants, line)
          line.fail!("fixed value #{words[1]} does not fit #{place.spelling}") unless place.holds?(value)
          Value.new(place: place, value: value, enum: nil, line: line).freeze
        in ['refers', _] then parse_reference(words, places, targets, line)
        in ['activates', 1]
          place = fetch_place(places, words[0], line)
          line.fail!("activates marks one bit, not #{place.spelling}") unless place.maximum == 1
          place
        in ['derived' | 'states', 1] then fetch_place(places, words[0], line)
        in ['releases', _] then parse_release(words, places, targets, types, line)
        in ['reach', 1]
          line.fail!("reach is one of #{REACHES.join(', ')}, not #{words[0]}") unless REACHES.include?(words[0])
          Reach.new(kind: words[0], line: line).freeze
        else line.fail!("#{keyword} requires #{SYNTAX.fetch(keyword)}")
        end
      end

      # Each place a mark claims, with its role: a reference claims its address,
      # placed, and its length, stated; a release the place it names and the
      # code it is read under, reported and a code; activates and derived a placed
      # place; selects and fixed a written one; states a stated one. A meaning
      # line claims none.
      def claims(mark)
        case mark.value
        in Target then []
        in Reference => reference then [[reference.place, :placed], [reference.length, :stated]].select(&:first)
        in Release => release then [[release.place, :reported], [release.condition, :code]].select(&:first)
        in Reach then []
        in Value => value then [[value.place, :written]]
        in Place => place then [[place, mark.keyword == 'states' ? :stated : :placed]]
        end
      end

      # Each place's role, by its spelling. Every place is claimed by exactly
      # one mark, so a place is free only where a mark says so, and a device
      # address is placed by the sequencer or reported by the device, never
      # stated by a description or fixed by the format. Each refusal names
      # the line at fault.
      def claim_once(marks, places)
        roles = marks.each_with_object({}) do |mark, claimed|
          claims(mark).each do |place, role|
            mark.line.fail!("#{place.spelling} is marked twice") if claimed.key?(place.spelling)
            refuse_free_address(place, role, mark.line)
            claimed[place.spelling] = role
          end
        end
        refuse_unclaimed(places, roles)
        roles.freeze
      end

      def refuse_free_address(place, role, line)
        return if !place.device_address || ADDRESS_ROLES.include?(role)

        line.fail!("device address #{place.spelling} must be a reference's address, derived or released")
      end

      def refuse_unclaimed(places, roles)
        places.each_value do |place|
          place.line.fail!("#{place.spelling} is claimed by no mark") unless roles.key?(place.spelling)
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
        place = fetch_place(places, words[0], line)
        line.fail!("refers names a device address, and #{place.spelling} is not one") unless place.device_address
        length &&= fetch_place(places, length, line)
        # The check reads a reference's bytes as one uint64_t, the length's value times its unit.
        if length && length.maximum * unit > (1 << 64) - 1
          line.fail!("#{length.spelling} times #{unit} can exceed 64 bits")
        end
        Reference.new(place: place, target: target_name(target, targets, line), length: length, unit: unit).freeze
      end

      # releases FIELD.BITS TARGET [when FIELD.BITS ENUM.MEMBER...]
      def parse_release(words, places, targets, types, line)
        line.fail!("releases requires #{SYNTAX.fetch('releases')}") unless words.size == 2 || (words.size >= 5 && words[2] == 'when')
        condition = words.size > 2 ? fetch_place(places, words[3], line) : nil
        codes = condition && words.drop(4).map { |code| member(code, condition, types, line).last }
        line.fail!('releases when lists each code once') if codes && codes.uniq.size != codes.size
        target = target_name(words[1], targets, line)
        unless targets[target] && !targets[target].device?
          line.fail!("releases names #{target}, which is no cpu structure: a holding is of records the CPU wrote")
        end
        Release.new(place: fetch_place(places, words[0], line), target: target,
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

      # ENUM.MEMBER, a member of an enum (not flags) whose value fits the
      # place: the enum's name and the member's value.
      def member(spelling, place, types, line)
        enum_name, _, member_name = spelling.rpartition('.')
        enum = types[enum_name]
        line.fail!("#{spelling} is not ENUM.MEMBER of an enum") unless enum.is_a?(EnumType) && !enum.flags
        line.fail!("#{member_name} is not a member of #{enum_name}") unless enum.members.key?(member_name)
        value = enum.members.fetch(member_name)
        line.fail!("#{spelling} does not fit #{place.spelling}") unless place.holds?(value)
        [enum_name, value]
      end

      def fetch_place(places, spelling, line)
        places[spelling] || line.fail!("#{spelling} is not a field or bits of this layout")
      end

      # Every place of the layout, by spelling, in field order: a field
      # without bits whole, otherwise each of its bits ranges.
      def layout_places(layout)
        layout.fields.flat_map do |field|
          if field.bits.empty?
            [Place.new(field: field.name, bits: nil, type: field.type, offset: field.offset, low: 0,
                       high: field.type.bits - 1, shift: 0, device_address: field.device_address,
                       line: field.line).freeze]
          else
            field.bits.map do |bits|
              Place.new(field: field.name, bits: bits.fetch(:name), type: field.type, offset: field.offset,
                        low: bits.fetch(:low), high: bits.fetch(:high), shift: bits.fetch(:shift),
                        device_address: bits.fetch(:device_address), line: bits.fetch(:line)).freeze
            end
          end
        end.each_with_object({}) do |place, places|
          other = places.values.find { |earlier| earlier.name == place.name }
          place.line.fail!("#{place.spelling} and #{other.spelling} share the encoder member #{place.name}") if other
          places[place.spelling] = place
        end
      end
    end
  end
end
