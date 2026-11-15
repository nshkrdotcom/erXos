# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_model'
require_relative 'abi_emit_inspection'

module Erx
  module ABI
    # Emits erx_abi_packed, the reader and writer of every packed layout
    # (docs/design-abi.md, "Packed layouts"). Each layout is one clause of
    # decode/2, a binary pattern of exactly its size whose segments have its
    # fields' widths, little-endian, so a read never runs past the bytes it is
    # given, and one clause of encode/2, which builds those bytes from a map of
    # the same fields and refuses a value wider than its field. The model
    # (Model.validate_packed) admits only fields this module can express:
    # unsigned integers, bytes and packed layouts, alone or in arrays.
    module PackedEmitter
      ERLANG_PATH = 'erlang/apps/erx/src/generated/erx_abi_packed.erl'
      COLUMNS = 80
      # The variable each array comprehension binds; no field's variable may be it.
      ELEMENT = 'Element'

      module_function

      def outputs(schema)
        layouts = schema.type_order.map { |name| schema.types.fetch(name) }
                        .select { |type| type.is_a?(Layout) && type.storage == Model::PACKED }
        return {} if layouts.empty?

        { ERLANG_PATH => erlang(layouts) }.freeze
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

      def integer_segment(value, bits)
        bits == 8 ? "#{value}:8" : "#{value}:#{bits}/little"
      end

      # The segment of a field in decode/2's pattern: the integer itself, or the
      # field's whole run of bytes, which the clause's body takes apart.
      def pattern_segment(field)
        return integer_segment(variable(field), bits(field)) if shape(field) == :integer

        "#{variable(field)}:#{field.size}/binary"
      end

      # The value a field takes in decode/2's map.
      def decoded_value(field)
        name = variable(field)
        layout = layout_atom(field)
        case shape(field)
        in :integer | :bytes then name
        in :integers then "[#{ELEMENT} || <<#{integer_segment(ELEMENT, bits(field))}>> <= #{name}]"
        in :binaries then "[#{ELEMENT} || <<#{ELEMENT}:#{field.type.size}/binary>> <= #{name}]"
        in :layout then "decode(#{layout}, #{name})"
        in :layouts
          "[decode(#{layout}, #{ELEMENT})\n          || <<#{ELEMENT}:#{field.type.size}/binary>> <= #{name}]"
        end
      end

      # The segment of a field in encode/2's binary.
      def encoded_segment(field)
        name = variable(field)
        layout = layout_atom(field)
        case shape(field)
        in :integer then integer_segment("(uint(#{name}, #{bits(field)}))", bits(field))
        in :integers then "(uints(#{name}, #{field.count}, #{bits(field)}))/binary"
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
          member.is_a?(Integer) ? "_:#{member}/binary" : pattern_segment(member)
        end
        values = layout.fields.map { |field| "#{atom(field.name)} => #{decoded_value(field)}" }
        "decode(#{atom(layout.name)},\n       <<#{wrapped(segments, 9, closing: 6)}>>) ->\n" \
          "    #\{#{values.join(",\n      ")}}"
      end

      def encode_clause(layout)
        keys = layout.fields.map { |field| "#{atom(field.name)} := #{variable(field)}" }
        segments = members(layout).map do |member|
          member.is_a?(Integer) ? "0:#{member * 8}" : encoded_segment(member)
        end
        "encode(#{atom(layout.name)},\n       #\{#{wrapped(keys, 9, closing: 5)}}) ->\n" \
          "    <<#{segments.join(",\n      ")}>>"
      end

      HELPERS = {
        'uint' => <<~ERLANG,
          uint(Value, Bits) when is_integer(Value), Value >= 0, Value bsr Bits =:= 0 ->
              Value.
        ERLANG
        'uints' => <<~ERLANG,
          uints(Values, Count, Bits) when length(Values) =:= Count ->
              << <<(uint(Value, Bits)):Bits/little>> || Value <- Values >>.
        ERLANG
        'bytes' => <<~ERLANG,
          bytes(Bytes, Size) when is_binary(Bytes), byte_size(Bytes) =:= Size -> Bytes.
        ERLANG
        'binaries' => <<~ERLANG,
          binaries(Values, Count, Size) when length(Values) =:= Count ->
              << <<(bytes(Value, Size))/binary>> || Value <- Values >>.
        ERLANG
        'layouts' => <<~ERLANG
          layouts(Layout, Values, Count) when length(Values) =:= Count ->
              << <<(encode(Layout, Value))/binary>> || Value <- Values >>.
        ERLANG
      }.freeze

      # The helpers encode/2 calls for a field of each shape, with those they call
      # in turn: only those are emitted, since an unused function fails the build.
      SHAPE_HELPERS = { integer: %w[uint], integers: %w[uints uint], bytes: %w[bytes],
                        binaries: %w[binaries bytes], layout: [], layouts: %w[layouts] }.freeze

      def helpers(layouts)
        used = layouts.flat_map(&:fields).flat_map { |field| SHAPE_HELPERS.fetch(shape(field)) }
        HELPERS.select { |name, _text| used.include?(name) }.values
      end

      def erlang(layouts)
        layouts.each { |layout| check_variables(layout) }
        names = layouts.map { |layout| atom(layout.name) }
        <<~ERLANG
          %% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
          %% SPDX-License-Identifier: BSD-2-Clause
          %% Generated by tools/gen_abi.rb from the packed layouts of abi/erx_abi.txt.
          %% Do not edit this file.

          -module(erx_abi_packed).
          -moduledoc """
          The ABI's packed layouts (docs/design-abi.md, "Packed layouts"):
          records of a medium whose fields sit at any byte offset, little-endian.
          decode/2 turns a layout's bytes into a map of its fields and encode/2 a
          map back into bytes. An integer field is an integer, a byte array or a
          bytes field a binary, a layout field a map, and any other array a list;
          padding is ignored on decode and zeros on encode. Neither checks a value
          against anything but its width: a layout's bounds belong to its reader.
          """.
          -export([decode/2, encode/2]).
          -export_type([layout/0]).

          -type layout() :: #{names.join("\n                | ")}.

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

          #{helpers(layouts).join("\n")}
        ERLANG
      end
    end
  end
end
