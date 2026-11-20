# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_marks'

module Erx
  module ABI
    # The encoders and the meaning lists of the DMA marks
    # (docs/design-device-dma.md, "What the formats say"), emitted into
    # include/erx/abi.h after the layouts' accessors. For a marked layout L
    # that is no report the header holds:
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
    # with its parameter, when it would be empty. A report, which the device
    # writes, gets its accessors and none of these, so nothing the device
    # states is an encoder input.
    #
    # For each structure S a format declares, erx_meanings_of_S lists the
    # numbers of the meanings every table of S offers, ERX_MEANING_<L>, each a
    # constant of the model.
    #
    # What the sequencer reads of a report (docs/design-device-dma.md,
    # "Releases"), from the record's bytes as the acquisition took them:
    #
    #   erx_report_meaning   the meaning a record of a structure the device
    #                        writes selects; false for a selector that names
    #                        none of the structure's meanings;
    #   erx_report_releases  the cpu structure whose record a report names and
    #                        its release place's value; false for a meaning
    #                        that releases nothing, or a code its release's
    #                        `when` does not list.
    module MarksEmitter
      # The encoder's parameter for each input, named apart from free(3).
      PARAMETERS = { 'free' => 'described', 'placed' => 'placed' }.freeze
      # The largest value a uint64_t input holds: a place this wide needs no width check.
      WHOLE_U64 = (1 << 64) - 1
      SUMMARIES = { 'free' => 'The free places a description states of',
                    'placed' => 'What the sequencer supplies where it places' }.freeze

      module_function

      def encoders(schema)
        marks = schema.marks
        written = marks.layouts.reject(&:report?)
        targets = marks.targets.values.sort_by(&:name)
        described = marks.meanings.reject(&:report?)
        [*(written.empty? ? [] : little_endian),
         *written.flat_map { |marked| encoder(marked) },
         *targets.flat_map { |target| meaning_list(target, marks.offered(target)) },
         *structures(targets, marks.meanings), *descriptions(described), *reports(targets, marks.meanings)]
      end

      def reports(targets, meanings)
        device = targets.select(&:device?)
        return [] if device.empty?

        arms = device.flat_map do |target|
          offered = meanings.select { |meaning| meaning.structure.name == target.name }
          # A meaning with no selector is its structure's one meaning and always answers.
          fallthrough = offered.all?(&:selector) ? ["\t\treturn (false);"] : []
          ["\tcase #{structure_constant(target.name)}:", *offered.flat_map { |meaning| select_arm(meaning) },
           *fallthrough]
        end
        reported = meanings.select(&:report?)
        releasing = reported.select(&:release)
        ["/* A report as the acquisition took it: its bytes, read as its meaning's layout. */",
         'typedef union erx_report_record {',
         *reported.map { |meaning| "\t#{CEmitter.name(meaning.layout.name)}_t\t#{Names.stem(meaning.layout.name)};" },
         "\tuint8_t\tbytes[#{reported.map { |meaning| meaning.layout.size }.max}];",
         '} erx_report_record_t;', '',
         '/*',
         ' * The meaning a record of structure, which the device writes, selects, into',
         ' * *meaning; false for a selector that names no meaning of the structure, or a',
         ' * structure the device does not write.',
         ' */',
         'static inline bool',
         'erx_report_meaning(uint32_t structure, const erx_report_record_t *record, uint32_t *meaning)',
         '{', "\t(void)record;", "\tswitch (structure) {", *arms, "\tdefault:", "\t\treturn (false);", "\t}", '}', '',
         '/*',
         ' * The cpu structure whose record a report of meaning names, into *structure,',
         " * and its release place's value, into *value; false for a meaning that",
         ' * releases nothing, or a code its release does not list.',
         ' */',
         'static inline bool',
         'erx_report_releases(uint32_t meaning, const erx_report_record_t *record, uint32_t *structure, uint64_t *value)',
         '{', "\tswitch (meaning) {", *releasing.flat_map { |meaning| release_arm(meaning) },
         "\tdefault:", "\t\t(void)record;", "\t\t(void)structure;", "\t\t(void)value;", "\t\treturn (false);", "\t}", '}', '']
      end

      # One meaning's test in erx_report_meaning: its selector's value, or none
      # where the structure has that one meaning.
      def select_arm(meaning)
        found = ["\t\t*meaning = #{CEmitter.constant(meaning.constant)};", "\t\treturn (true);"]
        return found unless meaning.selector

        ["\t\tif (#{place_value(meaning, meaning.selector.place, raw: true)} == #{hex(meaning.selector.raw)}) {",
         *found.map { |line| "\t#{line}" }, "\t\t}"]
      end

      def release_arm(meaning)
        release = meaning.release
        codes = (release.codes || []).map { |code| "#{place_value(meaning, release.condition, raw: false)} == #{hex(code)}" }
        ["\tcase #{CEmitter.constant(meaning.constant)}:",
         *(codes.empty? ? [] : ["\t\tif (!(#{codes.join(" ||\n\t\t    ")}))", "\t\t\treturn (false);"]),
         "\t\t*structure = #{structure_constant(release.target)};",
         "\t\t*value = #{place_value(meaning, release.place, raw: false)};",
         "\t\treturn (true);"]
      end

      # A place's value in a record of meaning's layout: its bits as the field
      # holds them (raw), or shifted by the place's shift, as its accessor
      # gives it, read through the report union's member of the layout.
      def place_value(meaning, place, raw:)
        record = "record->#{Names.stem(meaning.layout.name)}.#{place.field}"
        bits = "(((uint64_t)#{record} >> #{place.low}) & #{hex((1 << (place.high - place.low + 1)) - 1)})"
        raw || place.shift.zero? ? bits : "(#{bits} << #{place.shift})"
      end

      # The structures, numbered in name order from 1, so 0 is free to name a
      # buffer's data; which of them the device writes; the size of a record
      # of each, the size its meanings share (check_meanings), which a table's
      # stride must be; and the structure each meaning belongs to. The check
      # reads these, never a copy of the formats.
      def structures(targets, meanings)
        return [] if targets.empty?

        numbers = targets.each_with_index.map do |target, index|
          "#define #{structure_constant(target.name)} UINT32_C(#{index + 1})"
        end
        sizes = targets.filter_map do |target|
          offered = meanings.find { |meaning| meaning.structure.name == target.name }
          offered && [structure_constant(target.name), "UINT32_C(#{offered.layout.size})"]
        end
        ['/* The structures the formats declare; 0 names a buffer\'s data, which no structure is. */',
         '#define ERX_REFERS_DATA UINT32_C(0)', *numbers, '',
         *switch_function('Whether the device writes structure, as its format declares; false for one the CPU writes or none.',
                          'bool', 'erx_structure_device_writes(uint32_t structure)', 'structure',
                          targets.select(&:device?).map { |target| [structure_constant(target.name), 'true'] }, 'false'),
         *switch_function('The size of a record of structure, which its meanings share; 0 for one no meaning belongs to, or none.',
                          'uint32_t', 'erx_structure_record_size(uint32_t structure)', 'structure', sizes, '0'),
         *switch_function('The structure whose tables offer meaning, or 0 for a number that is no meaning.',
                          'uint32_t', 'erx_meaning_structure(uint32_t meaning)', 'meaning',
                          meanings.map { |meaning| [CEmitter.constant(meaning.constant), structure_constant(meaning.structure.name)] },
                          '0')]
      end

      def structure_constant(name) = CEmitter.constant("structure_#{name}")

      # One switch from value to result, the cases with one result sharing it.
      def switch_function(summary, type, signature, value, cases, otherwise)
        arms = cases.group_by(&:last).flat_map do |result, group|
          [*group.map { |label, _| "\tcase #{label}:" }, "\t\treturn (#{result});"]
        end
        ["/* #{summary} */", "static inline #{type}", signature, '{',
         "\tswitch (#{value}) {", *arms, "\tdefault:", "\t\treturn (#{otherwise});", "\t}", '}', '']
      end

      # What the check judges of a description (docs/design-device-dma.md,
      # "The rules", meanings and lengths): the union of every described
      # meaning's free places, and one function that refuses a value its
      # encoder would refuse and gives each reference's target and its length
      # in bytes, its length place's value times its unit.
      def descriptions(described)
        stated = described.reject { |marked| marked.free.empty? }
        return [] if stated.empty?

        most = [described.map { |marked| marked.references.size }.max, 1].max
        cases = described.flat_map { |marked| description_case(marked) }
        ['/* The free places of a description, by its meaning: one member per meaning that has any. */',
         'typedef union erx_meaning_free {',
         *stated.map { |marked| "\t#{CEmitter.name(marked.layout.name)}_free_t\t#{Names.stem(marked.layout.name)};" },
         '} erx_meaning_free_t;', '',
         '/*',
         ' * One reference of a description: the structure its record is of, or',
         ' * ERX_REFERS_DATA for a buffer, and the bytes it reaches from its name, or',
         ' * 0 where the format gives it no length place (a record of the target).',
         ' */',
         'typedef struct erx_meaning_reference {',
         "\tuint32_t\ttarget;",
         "\tuint64_t\tlength;",
         '} erx_meaning_reference_t;', '',
         '/* The most references one description names. */',
         "#define ERX_MEANING_REFERENCES_MAX #{most}u", '',
         '/*',
         ' * Judges a description of meaning as its encoder would: false when meaning',
         ' * is no meaning a description states, or a free value is wider than its',
         ' * place or has bits set below its shift. Otherwise *count references, in',
         ' * the order of their address places, are written into references.',
         ' */',
         'static inline bool',
         'erx_meaning_describes(uint32_t meaning, const erx_meaning_free_t *described,',
         '    erx_meaning_reference_t references[ERX_MEANING_REFERENCES_MAX], size_t *count)',
         '{',
         "\tswitch (meaning) {", *cases, "\tdefault:", "\t\treturn (false);", "\t}", '}', '']
      end

      def description_case(marked)
        member = "described->#{Names.stem(marked.layout.name)}"
        checks = refusals(marked.free.map { |place| Assignment.new(place: place, expression: "#{member}.#{place.name}") })
        references = marked.references.each_with_index.map do |reference, index|
          "\t\treferences[#{index}] = (erx_meaning_reference_t){ #{reference_target(reference)}, #{reference_length(reference, member)} };"
        end
        ["\tcase #{CEmitter.constant(marked.constant)}:",
         *checks.map { |line| "\t#{line.gsub("\n\t", "\n\t\t")}" },
         *references,
         "\t\t*count = #{marked.references.size};",
         "\t\treturn (true);"]
      end

      def reference_target(reference)
        reference.target == Marks::DATA ? 'ERX_REFERS_DATA' : structure_constant(reference.target)
      end

      # The length in bytes, which a uint64_t holds for every value the
      # place's width check lets through: the model refuses a unit that
      # could make the product wrap.
      def reference_length(reference, member)
        return '0' unless reference.length

        length = "#{member}.#{reference.length.name}"
        reference.unit == 1 ? length : "#{length} * #{reference.unit}u"
      end

      def little_endian
        ['/*',
         ' * The encoders below fill each record as a host struct of its wire_le',
         ' * layout, which is the record\'s byte order only on a little-endian host.',
         ' */',
         '_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,',
         '    "the DMA encoders need a little-endian host");', '']
      end

      # The meanings every table of target offers, in number order: the list
      # the check's meanings rule reads.
      def meaning_list(target, meanings)
        writer = target.device? ? 'the device writes them' : 'descriptions state them'
        body = if meanings.empty?
                 ["\t*count = 0;", "\treturn (NULL);"]
               else
                 ["\tstatic const uint32_t table[] = {",
                  *meanings.map { |meaning| "\t\t#{CEmitter.constant(meaning.constant)}," },
                  "\t};", '',
                  "\t*count = sizeof(table) / sizeof(table[0]);",
                  "\treturn (table);"]
               end
        ['/*',
         " * The meanings every table of #{target.name} offers, in number",
         " * order, *count of them from the result: #{writer}.",
         ' */',
         'static inline const uint32_t *',
         "erx_meanings_of_#{target.name}(size_t *count)",
         '{', *body, '}', '']
      end

      # What the encoder writes at one place: a C expression of uint64_t from an
      # input, or a mark's value as a literal.
      Assignment = Data.define(:place, :expression)

      def encoder(marked)
        layout = CEmitter.name(marked.layout.name)
        inputs = { 'free' => marked.free, 'placed' => marked.placed }.reject { |_kind, places| places.empty? }
        from_inputs = inputs.flat_map do |kind, places|
          places.map { |place| Assignment.new(place: place, expression: "#{PARAMETERS.fetch(kind)}->#{place.name}") }
        end
        from_marks = [marked.selector, *marked.fixed].compact.map do |value|
          Assignment.new(place: value.place, expression: CEmitter.unsigned_literal(value.value, value.place.type.bits))
        end
        order = Marks.layout_places(marked.layout).values.map(&:name)
        parameters = ["#{layout}_t *record",
                      *inputs.keys.map { |kind| "const #{layout}_#{kind}_t *#{PARAMETERS.fetch(kind)}" }]
        [*inputs.flat_map { |kind, places| input_struct(layout, kind, places) },
         '/*',
         " * Writes all of *record as #{marked.meaning? ? CEmitter.constant(marked.constant) : layout}. Returns false, with",
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
