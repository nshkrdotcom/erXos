# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_model'
require_relative 'abi_emit_inspection'

module Erx
  module ABI
    # Emits erx_abi_packed, the reader and writer of every packed layout and
    # element sequence (docs/design-abi.md, "Packed layouts" and "Element
    # sequences").
    #
    # Each layout is one clause of decode/2, a binary pattern of exactly its
    # size whose segments have its fields' widths in its byte order, so a read
    # never runs past the bytes it is given, and one clause of encode/2, which
    # builds those bytes from a map of the same fields and refuses a value
    # wider than its field. The model (Model.validate_packed) admits only
    # fields this module can express: unsigned integers, bytes and packed
    # layouts, alone or in arrays.
    #
    # Each element sequence is a clause of header/2, its tag and length, of
    # body/3 per known element, its length bounds and decoding, and of
    # encoded/2 and frame/3, the same in reverse; one loop, elements/4,
    # walks every sequence, so the loop's bounds are written once.
    module PackedEmitter
      ERLANG_PATH = 'erlang/apps/erx/src/generated/erx_abi_packed.erl'
      COLUMNS = 80
      # The variable each array comprehension binds; no field's variable may be it.
      ELEMENT = 'Element'

      module_function

      def outputs(schema)
        layouts = schema.type_order.map { |name| schema.types.fetch(name) }
                        .select { |type| type.is_a?(Layout) && type.packed? }
        sequences = schema.elements || []
        return {} if layouts.empty? && sequences.empty?

        { ERLANG_PATH => erlang(layouts, sequences) }.freeze
      end

      def atom(name) = InspectionEmitter.atom(name)

      # A field's variable: its name in CamelCase, unique within its layout.
      def variable(field) = field.name.split('_').map(&:capitalize).join

      def check_variables(layout)
        names = layout.fields.map { |field| variable(field) }
        clash = names.tally.find { |name, count| count > 1 || name == ELEMENT }
        raise SchemaError, "packed layout #{layout.name}: fields share the variable #{clash.first}" if clash
      end

      # How a field is held in the map: an integer, a list of integers, a
      # binary (a byte array or a bytes field), a list of binaries (an array of
      # a bytes type), a nested map, or a list of maps.
      def shape(field)
        case field.type
        when IntegerType
          return :integer unless field.array?

          field.type.size == 1 ? :bytes : :integers
        when BytesType then field.array? ? :binaries : :bytes
        when Layout then field.array? ? :layouts : :layout
        end
      end

      def bits(field) = field.type.size * 8

      def layout_atom(field) = field.type.is_a?(Layout) ? atom(field.type.name) : nil

      # An unsigned integer segment of a byte order, little or big; a byte has none.
      def integer_segment(value, bits, order)
        bits == 8 ? "#{value}:8" : "#{value}:#{bits}/#{order}"
      end

      # The segment of a field in decode/2's pattern: the integer itself, or the
      # field's whole run of bytes, which the clause's body takes apart.
      def pattern_segment(field, order)
        return integer_segment(variable(field), bits(field), order) if shape(field) == :integer

        "#{variable(field)}:#{field.size}/binary"
      end

      # The value a field takes in decode/2's map.
      def decoded_value(field, order)
        name = variable(field)
        layout = layout_atom(field)
        case shape(field)
        in :integer | :bytes then name
        in :integers then "[#{ELEMENT} || <<#{integer_segment(ELEMENT, bits(field), order)}>> <= #{name}]"
        in :binaries then "[#{ELEMENT} || <<#{ELEMENT}:#{field.type.size}/binary>> <= #{name}]"
        in :layout then "decode(#{layout}, #{name})"
        in :layouts
          "[decode(#{layout}, #{ELEMENT})\n          || <<#{ELEMENT}:#{field.type.size}/binary>> <= #{name}]"
        end
      end

      # The segment of a field in encode/2's binary. An integer array is a
      # comprehension here rather than a helper, since bit syntax takes its
      # byte order only as a literal.
      def encoded_segment(field, order)
        name = variable(field)
        layout = layout_atom(field)
        case shape(field)
        in :integer then integer_segment("(uint(#{name}, #{bits(field)}))", bits(field), order)
        in :integers
          element = integer_segment("(uint(#{ELEMENT}, #{bits(field)}))", bits(field), order)
          "(<< <<#{element}>>\n         || #{ELEMENT} <- count(#{name}, #{field.count}) >>)/binary"
        in :bytes then "(bytes(#{name}, #{field.size}))/binary"
        in :binaries then "(binaries(#{name}, #{field.count}, #{field.type.size}))/binary"
        in :layout then "(encode(#{layout}, #{name}))/binary"
        in :layouts then "(layouts(#{layout}, #{name}, #{field.count}))/binary"
        end
      end

      # Every field and padding run in offset order, a padding run as its byte
      # count, an Integer.
      def members(layout)
        runs = layout.fields.map { |field| [field.offset, field] } +
               layout.padding.map { |offset, bytes| [offset, bytes] }
        runs.sort_by(&:first).map(&:last)
      end

      # The parts joined at ", " and wrapped at an indent, each line short
      # enough to leave room for the closing text the last line carries.
      def wrapped(parts, indent, closing: 0)
        lines = parts.each_with_object([+'']) do |part, result|
          piece = result.last.empty? ? part : ", #{part}"
          if !result.last.empty? && indent + result.last.size + piece.size + 1 + closing > COLUMNS
            result.last << ','
            result << part.dup
          else
            result.last << piece
          end
        end
        lines.join("\n#{' ' * indent}")
      end

      def decode_clause(layout)
        segments = members(layout).map do |member|
          member.is_a?(Integer) ? "_:#{member}/binary" : pattern_segment(member, layout.byte_order)
        end
        values = layout.fields.map { |field| "#{atom(field.name)} => #{decoded_value(field, layout.byte_order)}" }
        "decode(#{atom(layout.name)},\n       <<#{wrapped(segments, 9, closing: 6)}>>) ->\n" \
          "    #\{#{values.join(",\n      ")}}"
      end

      def encode_clause(layout)
        keys = layout.fields.map { |field| "#{atom(field.name)} := #{variable(field)}" }
        segments = members(layout).map do |member|
          member.is_a?(Integer) ? "0:#{member * 8}" : encoded_segment(member, layout.byte_order)
        end
        "encode(#{atom(layout.name)},\n       #\{#{wrapped(keys, 9, closing: 5)}}) ->\n" \
          "    <<#{segments.join(",\n      ")}>>"
      end

      # The tag and length segments of a sequence's element header.
      def header_segments(sequence, tag, length)
        [integer_segment(tag, sequence.tag_type.base.bits, sequence.byte_order),
         integer_segment(length, sequence.length_type.bits, sequence.byte_order)]
      end

      # The guard bounding a known element's body by its length bounds, or nil
      # when every length the header can carry is one it accepts.
      def length_guard(sequence, element)
        return "byte_size(Body) =:= #{element.minimum}" if element.minimum == element.maximum

        # The end marker's element never has an empty body: that header stops the walk.
        floor = sequence.end_marker.equal?(element) ? 1 : 0
        bounds = []
        bounds << "byte_size(Body) >= #{element.minimum}" if element.minimum > floor
        bounds << "byte_size(Body) =< #{element.maximum}" if element.maximum < sequence.length_type.maximum
        bounds.empty? ? nil : bounds.join(', ')
      end

      # A known element's clauses of body/3: the element when its body's length
      # is within its bounds, the length error otherwise. An element whose
      # bounds every length meets has no error clause, which could not match.
      def body_clauses(sequence, element)
        head = "body(#{atom(sequence.name)}, #{element.tag}, "
        name = atom(element.name)
        value = element.layout ? "decode(#{atom(element.layout.name)}, Body)" : 'Body'
        guard = length_guard(sequence, element)
        accepted = "#{head}Body)#{guard ? " when #{guard}" : ''} ->\n    {element, #{name}, #{value}}"
        guard ? [accepted, "#{head}_) ->\n    {error, {length, #{name}}}"] : [accepted]
      end

      def encoded_clause(sequence, element)
        body = if element.layout
                 "encode(#{atom(element.layout.name)}, Body)"
               else
                 "sized(Body, #{element.minimum}, #{element.maximum})"
               end
        "encoded(#{atom(sequence.name)}, {#{atom(element.name)}, Body}) ->\n" \
          "    frame(#{atom(sequence.name)}, #{element.tag}, #{body})"
      end

      # A sequence's clauses of header/2: with an end marker, its tag alone at the
      # end of the bytes and its header with length zero stop the walk, ahead of
      # the clause that reads any header.
      def header_clauses(sequence)
        name = atom(sequence.name)
        read = "header(#{name}, <<#{header_segments(sequence, 'Tag', 'Length').join(', ')}, Rest/binary>>) ->\n" \
               '    {Tag, Length, Rest}'
        return [read] unless sequence.end_marker

        tag, zero = header_segments(sequence, sequence.end_marker.tag, 0)
        ["header(#{name}, <<#{tag}>>) ->\n    stop",
         "header(#{name}, <<#{tag}, #{zero}, _/binary>>) ->\n    stop", read]
      end

      def frame_clause(sequence)
        "frame(#{atom(sequence.name)}, Tag, Body) ->\n" \
          "    <<#{header_segments(sequence, 'Tag', '(byte_size(Body))').join(', ')}, Body/binary>>"
      end

      def repeats_clause(sequence, element)
        "repeats(#{atom(sequence.name)}, #{atom(element.name)}) -> #{element.repeat}"
      end

      # The clauses the block makes of each known element, in sequence and tag order.
      def element_clauses(sequences, &clauses)
        sequences.flat_map { |sequence| sequence.elements.flat_map { |element| clauses.call(sequence, element) } }
      end

      def sequence_functions(sequences)
        headers = sequences.flat_map { |sequence| header_clauses(sequence) }
        frames = sequences.map { |sequence| frame_clause(sequence) }
        bodies = element_clauses(sequences) { |sequence, element| body_clauses(sequence, element) }
        repeats = element_clauses(sequences) { |sequence, element| repeats_clause(sequence, element) }
        encoded = element_clauses(sequences) { |sequence, element| encoded_clause(sequence, element) }
        <<~ERLANG
          %% A sequence's element header: its tag, its length and the bytes after
          %% them; stop at its end marker; or truncated when the bytes end inside it.
          #{(headers + ["header(_Sequence, _Bytes) ->\n    truncated"]).join(";\n")}.

          %% A known element from its tag and body, the body's length checked
          %% against the element's bounds; skip for a tag the sequence does not know.
          #{(bodies + ["body(_Sequence, _Tag, _Body) ->\n    skip"]).join(";\n")}.

          %% Whether a known element may appear more than once.
          #{repeats.join(";\n")}.

          %% A known element's header and body.
          #{encoded.join(";\n")}.

          %% An element's tag and length, written before its body.
          #{frames.join(";\n")}.
        ERLANG
      end

      # The loop every sequence's reader runs: each step reads one header,
      # bounds its length by the bytes that remain before it forms the body,
      # and consumes at least the header, so the walk ends within the bytes
      # and runs in constant stack, its calls all tail calls.
      SEQUENCE_LOOP = <<~'ERLANG'
        elements(_Sequence, <<>>, _Seen, Elements) ->
            {ok, lists:reverse(Elements)};
        elements(Sequence, Bytes, Seen, Elements) ->
            case header(Sequence, Bytes) of
                {Tag, Length, Rest} when Length =< byte_size(Rest) ->
                    <<Body:Length/binary, Next/binary>> = Rest,
                    next(Sequence, body(Sequence, Tag, Body), Next, Seen, Elements);
                {_Tag, _Length, _Rest} ->
                    {error, overrun};
                stop ->
                    {ok, lists:reverse(Elements)};
                truncated ->
                    {error, truncated}
            end.

        %% Seen holds each element that appears once and has appeared.
        next(Sequence, skip, Next, Seen, Elements) ->
            elements(Sequence, Next, Seen, Elements);
        next(_Sequence, {error, _} = Error, _Next, _Seen, _Elements) ->
            Error;
        next(Sequence, {element, Name, Value}, Next, Seen, Elements) ->
            case repeats(Sequence, Name) of
                once when is_map_key(Name, Seen) ->
                    {error, {duplicate, Name}};
                once ->
                    elements(Sequence, Next, Seen#{Name => true}, [{Name, Value} | Elements]);
                many ->
                    elements(Sequence, Next, Seen, [{Name, Value} | Elements])
            end.

        %% The elements' bytes in order; a second element that appears once is
        %% a badmatch error.
        frames(Sequence, Elements) ->
            Once = [Name || {Name, _} <- Elements, repeats(Sequence, Name) =:= once],
            true = length(Once) =:= length(lists:usort(Once)),
            << <<(encoded(Sequence, Element))/binary>> || Element <- Elements >>.
      ERLANG

      HELPERS = {
        'uint' => <<~ERLANG,
          uint(Value, Bits) when is_integer(Value), Value >= 0, Value bsr Bits =:= 0 ->
              Value.
        ERLANG
        'count' => <<~ERLANG,
          count(Values, Count) when length(Values) =:= Count -> Values.
        ERLANG
        'bytes' => <<~ERLANG,
          bytes(Bytes, Size) when is_binary(Bytes), byte_size(Bytes) =:= Size -> Bytes.
        ERLANG
        'binaries' => <<~ERLANG,
          binaries(Values, Count, Size) when length(Values) =:= Count ->
              << <<(bytes(Value, Size))/binary>> || Value <- Values >>.
        ERLANG
        'layouts' => <<~ERLANG,
          layouts(Layout, Values, Count) when length(Values) =:= Count ->
              << <<(encode(Layout, Value))/binary>> || Value <- Values >>.
        ERLANG
        'sized' => <<~ERLANG
          sized(Bytes, Minimum, Maximum)
            when is_binary(Bytes), byte_size(Bytes) >= Minimum, byte_size(Bytes) =< Maximum ->
              Bytes.
        ERLANG
      }.freeze

      # The helpers encode/2 calls for a field of each shape, with those they call
      # in turn: only those are emitted, since an unused function fails the build.
      SHAPE_HELPERS = { integer: %w[uint], integers: %w[uint count], bytes: %w[bytes],
                        binaries: %w[binaries bytes], layout: [], layouts: %w[layouts] }.freeze

      def helpers(layouts, sequences)
        used = layouts.flat_map(&:fields).flat_map { |field| SHAPE_HELPERS.fetch(shape(field)) }
        used << 'sized' if sequences.flat_map(&:elements).any? { |element| element.layout.nil? }
        HELPERS.select { |name, _text| used.include?(name) }.values
      end

      def type(name, atoms) = "-type #{name}() :: #{atoms.join("\n#{' ' * (name.size + 10)}| ")}."

      def layout_functions(layouts)
        layouts.each { |layout| check_variables(layout) }
        <<~ERLANG
          -doc """
          The fields of a layout's bytes, which must be exactly the layout's size;
          any other binary is a function_clause error.
          """.
          -spec decode(layout(), binary()) -> \#{atom() => term()}.
          #{layouts.map { |layout| decode_clause(layout) }.join(";\n")}.

          -doc """
          A layout's bytes from a map holding each of its fields; a missing field,
          or a value wider than its field or of the wrong length, is an error.
          """.
          -spec encode(layout(), \#{atom() => term()}) -> binary().
          #{layouts.map { |layout| encode_clause(layout) }.join(";\n")}.
        ERLANG
      end

      def sequence_entries(sequences)
        decoders = sequences.map do |sequence|
          "decode_elements(#{atom(sequence.name)}, Bytes) when is_binary(Bytes) ->\n" \
            "    elements(#{atom(sequence.name)}, Bytes, \#{}, [])"
        end
        encoders = sequences.map do |sequence|
          "encode_elements(#{atom(sequence.name)}, Elements) ->\n    frames(#{atom(sequence.name)}, Elements)"
        end
        <<~ERLANG
          -doc """
          The known elements of a sequence's bytes, in order, each {Name, Body},
          with every element of a tag the sequence does not know skipped. A body
          is a binary, or the map of its packed layout. A sequence with an end
          marker ends at it, and nothing after it is read. The error is truncated
          when the bytes end inside a tag and length, overrun when a length runs
          past them, {length, Name} when a known element's body has a length its
          declaration refuses, and {duplicate, Name} when an element that appears
          once appears again.
          """.
          -spec decode_elements(sequence(), binary()) ->
                    {ok, [{atom(), binary() | \#{atom() => term()}}]} | {error, element_error()}.
          #{decoders.join(";\n")}.

          -doc """
          A sequence's bytes from its elements, in the order given; an unknown
          element, a body its element refuses, or a second element that appears
          once, is an error.
          """.
          -spec encode_elements(sequence(), [{atom(), term()}]) -> binary().
          #{encoders.join(";\n")}.
        ERLANG
      end

      def erlang(layouts, sequences)
        exports = []
        types = []
        sections = []
        unless layouts.empty?
          exports.push('decode/2', 'encode/2')
          types << type('layout', layouts.map { |layout| atom(layout.name) })
          sections << layout_functions(layouts)
        end
        unless sequences.empty?
          exports.push('decode_elements/2', 'encode_elements/2')
          types << type('sequence', sequences.map { |sequence| atom(sequence.name) })
          types << '-type element_error() :: truncated | overrun | {length, atom()} | {duplicate, atom()}.'
          sections.push(sequence_entries(sequences), sequence_functions(sequences), SEQUENCE_LOOP)
        end
        exported_types = types.map { |line| line[/\A-type (\w+)\(\)/, 1] + '/0' }
        <<~ERLANG
          %% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
          %% SPDX-License-Identifier: BSD-2-Clause
          %% Generated by tools/gen_abi.rb from the packed layouts and element
          %% sequences of abi/erx_abi.txt. Do not edit this file.

          -module(erx_abi_packed).
          -moduledoc """
          The ABI's packed layouts and element sequences (docs/design-abi.md,
          "Packed layouts" and "Element sequences").

          A packed layout is a record of a medium whose fields sit at any byte
          offset, little- or big-endian as its storage says. decode/2 turns a
          layout's bytes into a map of its fields and encode/2 a map back into
          bytes. An integer field is an integer, a byte array or a bytes field a
          binary, a layout field a map, and any other array a list; padding is
          ignored on decode and zeros on encode. Neither checks a value against
          anything but its width: a layout's bounds belong to its reader.

          An element sequence is tag, length and body records repeated to the end
          of its bytes. decode_elements/2 reads its known elements, refusing a
          length that overruns the bytes, and encode_elements/2 writes them.
          """.
          -export([#{exports.join(', ')}]).
          -export_type([#{exported_types.join(', ')}]).

          #{types.join("\n")}

          #{sections.join("\n")}
          #{helpers(layouts, sequences).join("\n")}
        ERLANG
      end
    end
  end
end
