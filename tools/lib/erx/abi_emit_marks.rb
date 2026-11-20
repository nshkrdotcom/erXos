# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_marks'

module Erx
  module ABI
    # Each meaning's encoder (docs/design-device-dma.md, "What the formats
    # say"), emitted into include/erx/abi.h after the layouts' accessors it
    # calls. For a marked layout L the header holds:
    #
    #   erx_L_free_t     the free places, which a description states;
    #   erx_L_placed_t   each reference's address, the activation and each
    #                    derived place, which the sequencer supplies;
    #   erx_L_encode     writes the whole record from the two, the selector's
    #                    member and every fixed value, and zero in every bit
    #                    the layout does not name.
    #
    # Each struct is left out, with its parameter, when it would be empty.
    # The meaning's number is ERX_MEANING_<L>, a constant of the model.
    module MarksEmitter
      # The encoder's parameter for each input, named apart from free(3).
      PARAMETERS = { 'free' => 'described', 'placed' => 'placed' }.freeze
      SUMMARIES = { 'free' => 'The free places a description states of',
                    'placed' => 'What the sequencer supplies where it places' }.freeze

      module_function

      def encoders(schema)
        schema.marks.meanings.flat_map { |meaning| encoder(meaning) }
      end

      # What the encoder writes at one place: a C expression of the place's type.
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
        assignments = (from_inputs + from_marks).sort_by { |assignment| assignment.place.name }
        wholes, ranges = assignments.partition { |assignment| assignment.place.bits.nil? }
        parameters = ["#{layout}_t *record",
                      *inputs.keys.map { |kind| "const #{layout}_#{kind}_t *#{PARAMETERS.fetch(kind)}" }]
        [*inputs.flat_map { |kind, places| input_struct(layout, kind, places) },
         '/*',
         " * Writes all of *record as #{CEmitter.constant(meaning.constant)}. Returns false, with",
         ' * *record untouched, when a value does not fit its bits.',
         ' */',
         'static inline bool',
         "#{layout}_encode(#{parameters.join(",\n    ")})",
         '{',
         "\t#{layout}_t out = { 0 };", '',
         *wholes.map { |assignment| "\tout.#{assignment.place.field} = #{assignment.expression};" },
         *range_checks(layout, ranges),
         "\t*record = out;",
         "\treturn (true);",
         '}', '']
      end

      def input_struct(layout, kind, places)
        ["/* #{SUMMARIES.fetch(kind)} #{layout}. */",
         "typedef struct #{layout}_#{kind} {",
         *places.map { |place| "\t#{CEmitter.c_type(place.type)}\t#{place.name};" },
         "} #{layout}_#{kind}_t;", '']
      end

      # One condition over every bits range's setter, which refuses a value
      # wider than its bits or with bits below its shift.
      def range_checks(layout, ranges)
        return [] if ranges.empty?

        calls = ranges.map do |assignment|
          place = assignment.place
          "!#{layout}_#{place.field}_#{place.bits}_set(&out.#{place.field},\n\t        #{assignment.expression})"
        end
        ["\tif (#{calls.join(" ||\n\t    ")})", "\t\treturn (false);"]
      end
    end
  end
end
