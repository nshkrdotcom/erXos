# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_marks'

module Erx
  module ABI
    # Each meaning's encoder (docs/design-device-dma.md, "What the formats
    # say"), emitted into include/erx/abi.h after the layouts' accessors. For
    # a marked layout L the header holds:
    #
    #   erx_L_free_t     the free places, which a description states;
    #   erx_L_placed_t   each reference's address, the activation and each
    #                    derived place, which the sequencer supplies;
    #   erx_L_encode     writes the whole record from the two, the selector's
    #                    member and every fixed value, and zero in every bit
    #                    the layout does not name.
    #
    # Each input is a uint64_t, so a caller's value reaches the encoder whole
    # and the encoder alone decides that it fits. Each struct is left out,
    # with its parameter, when it would be empty.
    # The meaning's number is ERX_MEANING_<L>, a constant of the model.
    module MarksEmitter
      # The encoder's parameter for each input, named apart from free(3).
      PARAMETERS = { 'free' => 'described', 'placed' => 'placed' }.freeze
      # The largest value a uint64_t input holds: a place this wide needs no width check.
      WHOLE_U64 = (1 << 64) - 1
      SUMMARIES = { 'free' => 'The free places a description states of',
                    'placed' => 'What the sequencer supplies where it places' }.freeze

      module_function

      def encoders(schema)
        return [] if schema.marks.meanings.empty?

        ['/*',
         ' * The encoders below fill each record as a host struct of its wire_le',
         ' * layout, which is the record\'s byte order only on a little-endian host.',
         ' */',
         '_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,',
         '    "the DMA encoders need a little-endian host");', '',
         *schema.marks.meanings.flat_map { |meaning| encoder(meaning) }]
      end

      # What the encoder writes at one place: a C expression of uint64_t from an
      # input, or a mark's value as a literal.
      Assignment = Data.define(:place, :expression)

      def encoder(meaning)
        layout = CEmitter.name(meaning.layout.name)
        inputs = { 'free' => meaning.free, 'placed' => meaning.placed }.reject { |_kind, places| places.empty? }
        from_inputs = inputs.flat_map do |kind, places|
          places.map { |place| Assignment.new(place: place, expression: "#{PARAMETERS.fetch(kind)}->#{place.name}") }
        end
        from_marks = [meaning.selector, *meaning.fixed].compact.map do |value|
          Assignment.new(place: value.place, expression: CEmitter.unsigned_literal(value.value, value.place.type.bits))
        end
        order = Marks.layout_places(meaning.layout).values.map(&:name)
        parameters = ["#{layout}_t *record",
                      *inputs.keys.map { |kind| "const #{layout}_#{kind}_t *#{PARAMETERS.fetch(kind)}" }]
        [*inputs.flat_map { |kind, places| input_struct(layout, kind, places) },
         '/*',
         " * Writes all of *record as #{CEmitter.constant(meaning.constant)}. Returns false, with",
         ' * *record untouched, when a value is wider than its place or has bits',
         ' * set below its shift.',
         ' */',
         'static inline bool',
         "#{layout}_encode(#{parameters.join(",\n    ")})",
         '{',
         "\t#{layout}_t out = { 0 };", '',
         *refusals(from_inputs),
         *(from_inputs + from_marks).sort_by { |assignment| order.index(assignment.place.name) }
                                    .map { |assignment| store(assignment) },
         "\t*record = out;",
         "\treturn (true);",
         '}', '']
      end

      def input_struct(layout, kind, places)
        ["/* #{SUMMARIES.fetch(kind)} #{layout}. */",
         "typedef struct #{layout}_#{kind} {",
         *places.map { |place| "\tuint64_t\t#{place.name};" },
         "} #{layout}_#{kind}_t;", '']
      end

      # One condition over every input, which refuses a value wider than its
      # place or with bits set below the place's shift, before anything is
      # stored, so no value is cut to fit.
      def refusals(assignments)
        conditions = assignments.flat_map do |assignment|
          place = assignment.place
          [(place.maximum < WHOLE_U64 ? "#{assignment.expression} > #{hex(place.maximum)}" : nil),
           (place.shift.positive? ? "(#{assignment.expression} & #{hex((1 << place.shift) - 1)}) != 0" : nil)]
        end.compact
        return [] if conditions.empty?

        ["\tif (#{conditions.join(" ||\n\t    ")})", "\t\treturn (false);"]
      end

      def hex(value) = format('UINT64_C(0x%x)', value)

      # The store of one value the refusals let through, or a mark's: a whole
      # field takes it, a bits range moves it from its shift to its low bit.
      def store(assignment)
        place = assignment.place
        type = CEmitter.c_type(place.type)
        return "\tout.#{place.field} = (#{type})#{assignment.expression};" unless place.bits

        moved = assignment.expression
        moved = "(#{moved} >> #{place.shift})" if place.shift.positive?
        moved = "(#{moved} << #{place.low})" if place.low.positive?
        "\tout.#{place.field} |= (#{type})#{moved};"
      end
    end
  end
end
