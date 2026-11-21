# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'

# erx_abi_layout, the typed codec of the fixed wire_le layouts (docs/design-abi.md,
# "Layouts in Erlang"), and the name/2 and value/2 of erx_abi_enums it decodes and
# encodes enum and flags fields through, compiled on stock's compiler (ERX_ERLC) and run
# on its emulator (ERX_ERL). A sample schema holds every shape the codec knows; on it the
# module decodes known bytes to the expected map and back, and refuses each value a
# layout does not admit. Then every fixed wire_le layout of the tree's ABI file
# round-trips bytes built from its declaration, and refuses, for each of its fields and
# padding runs, an enum value no member holds, a flags bit its type does not declare, a
# combination its allow line does not list, a scalar past its range, bytes that differ
# from their fixed value, a padding byte that is not zero, and bytes of the wrong size.
# The C reader's encoder writes back, byte for byte, every such layout's sample its
# decoder read.
# Seeded faults in the generated code (the padding check, the enum check, the flags
# mask, the scalar's range and the fixed value's comparison dropped) must each fail the
# sample's expression.
class AbiLayoutTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  ENUMS_PATH = 'erlang/apps/erx/src/generated/erx_abi_enums.erl'

  SAMPLE = <<~ABI
    enum sample_kind u8
      value low 1
      value high 7
    flags sample_flags u8
      bit ready 0
      bit wide 2
    flags sample_mode u16
      bit on 0
      bit locked 1
      allow 0,1,3
    scalar sample_count u32 range 1 9
    bytes sample_magic 4 value 6e616d65
    layout sample_part wire_le 4 8
      field kind sample_kind 0
      padding 1 3
      field value i32 4
    layout sample wire_le 8 40
      field flags sample_flags 0
      field tag i8 1
      field mode sample_mode 2
      field count sample_count 4
      field address u64 8
      field name sample_magic 16
      field words u16 20 count 2
      field parts sample_part 24 count 2
  ABI

  # The sample's bytes and their map; the part's value is -2 and the tag -1.
  SAMPLE_CHECKS = <<~ERLANG
    Part = <<7, 0, 0, 0, 254, 255, 255, 255>>,
    Bytes = <<5, 255, 3, 0, 9, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 128, "name", 1, 2, 3, 4,
              Part/binary, 1, 0, 0, 0, 0, 0, 0, 0>>,
    Map = \#{flags => [ready, wide], tag => -1, mode => [locked, on], count => 9,
            address => 16#8000000000000001, name => <<"name">>, words => [16#201, 16#403],
            parts => [\#{kind => high, value => -2}, \#{kind => low, value => 0}]},
    {ok, Map} = erx_abi_layout:decode(sample, Bytes),
    Bytes = erx_abi_layout:encode(sample, Map),
    Put = fun(Offset, Byte) -> <<Head:Offset/binary, _, Tail/binary>> = Bytes, <<Head/binary, Byte, Tail/binary>> end,
    {error, {sample_flags, 2}} = erx_abi_layout:decode(sample, Put(0, 2)),
    {error, {sample_mode, 2}} = erx_abi_layout:decode(sample, Put(2, 2)),
    {error, {sample_mode, 4}} = erx_abi_layout:decode(sample, Put(2, 4)),
    {error, {sample_kind, 0}} = erx_abi_layout:decode(sample, Put(32, 0)),
    {error, {sample_count, 10}} = erx_abi_layout:decode(sample, Put(4, 10)),
    {error, {sample_count, 0}} = erx_abi_layout:decode(sample, Put(4, 0)),
    {error, {sample_magic, <<"Name">>}} = erx_abi_layout:decode(sample, Put(16, $N)),
    {error, {padding, sample_part}} = erx_abi_layout:decode(sample, Put(26, 1)),
    {error, {size, sample}} = erx_abi_layout:decode(sample, <<Bytes/binary, 0>>),
    {error, {size, sample}} = erx_abi_layout:decode(sample, binary:part(Bytes, 0, 39)),
    Refused = fun(F) -> try F() of _ -> accepted catch _:_ -> refused end end,
    [refused = Refused(fun() -> erx_abi_layout:encode(sample, maps:merge(Map, Bad)) end)
     || Bad <- [\#{flags => [bogus]}, \#{mode => [locked]}, \#{tag => 128}, \#{tag => -129},
                \#{count => 10}, \#{name => <<"Name">>}, \#{words => [1]},
                \#{parts => [\#{kind => middle, value => 0}, \#{kind => low, value => 0}]}]],
    io:format("layout ok~n"), halt(0).
  ERLANG

  # Each seeded fault drops one check from the generated code; the sample's
  # expression must then fail.
  SEEDS = [
    ['padding(sample_part, Padding1),', ''],
    ['coded(sample_kind, Kind)', 'Kind'],
    ['Value band bnot 5 =:= 0', 'true'],
    ['Value =< Maximum', 'true'],
    ['fixed(_Type, Expected, Expected) ->', 'fixed(_Type, Expected, _Bytes) ->']
  ].freeze

  def schema(body)
    text = "abi 1\n#{body}"
    declarations = Erx::ABI::Syntax.parse(text, path: 'abi/erx_abi.txt')
    source = Erx::ABI::SourceSet.new(declarations: declarations.freeze,
                                    inputs: { 'abi/erx_abi.txt' => text.freeze }.freeze).freeze
    Erx::ABI::Model.validate(source)
  end

  def test_the_sample_decodes_encodes_and_refuses
    output, status = run_generated(schema(SAMPLE), SAMPLE_CHECKS)
    assert status.success?, output
    assert_includes output, 'layout ok'
  end

  def test_each_seeded_fault_fails_the_sample
    SEEDS.each do |fault|
      output, status = run_generated(schema(SAMPLE), SAMPLE_CHECKS, fault: fault)
      refute status.success?, "#{fault.first}: the sample passed:\n#{output}"
    end
  end

  def test_generated_output_is_ascii_and_declares_each_layout_as_a_type
    text = layout_module(schema(SAMPLE))
    assert text.ascii_only?
    assert_includes text, "-type sample_part() ::\n    \#{kind := erx_abi_enums:sample_kind(),\n      value := i32()}."
    assert_includes Erx::ABI::ErlangEmitter.outputs(schema(SAMPLE)).fetch(ENUMS_PATH),
                    "-type 'sample_mode'() :: ['locked' | 'on']."
  end

  def test_every_wire_layout_of_the_abi_round_trips_and_refuses_bad_values
    model = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT, architecture: 'aarch64'))
    layouts = model.type_order.map { |name| model.types.fetch(name) }
                   .select { |type| type.is_a?(Erx::ABI::Layout) && type.storage == 'wire_le' && !type.tail }
    cases = layouts.flat_map { |layout| Samples.cases(layout) }
    Dir.mktmpdir('erx-abi-layout-cases-') do |work|
      file = File.join(work, 'cases.terms')
      File.write(file, cases.join)
      expression = <<~ERLANG
        {ok, Cases} = file:consult("#{file}"),
        Wrong = [{Layout, Expected, Got}
                 || {Layout, Bytes, Expected} <- Cases,
                    Got <- [case erx_abi_layout:decode(Layout, Bytes) of
                                {ok, Map} when Expected =:= ok -> erx_abi_layout:encode(Layout, Map) =:= Bytes;
                                Other -> Other
                            end],
                    Got =/= true, Got =/= Expected],
        io:format("~b cases, wrong: ~p~n", [length(Cases), Wrong]),
        halt(case Wrong of [] -> 0; _ -> 1 end).
      ERLANG
      output, status = run_generated(model, expression)
      assert status.success?, output
      assert_match(/#{cases.size} cases, wrong: \[\]/, output)
    end
  end

  # The C reader's encoder is its decoder's inverse: every sample of a layout it encodes
  # (each fixed wire_le layout but the device records), decoded, encodes to the same bytes and
  # no byte past them, and an encode into too short a buffer is refused.
  def test_every_wire_layout_of_the_abi_encodes_in_c_what_it_decodes
    model = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT, architecture: 'aarch64'))
    layouts = Erx::ABI::CEmitter.wire_encoded_layouts(model)
    program = "#include <stdio.h>\n#include <string.h>\n#include \"erx/abi_reader.h\"\n\nint\nmain(void)\n{\n" \
              "\tint wrong = 0;\n\n#{layouts.map { |layout| encode_check(layout) }.join}" \
              "\tprintf(\"%d layouts, %d wrong\\n\", #{layouts.size}, wrong);\n\treturn (wrong != 0);\n}\n"
    Dir.mktmpdir('erx-abi-encode-') do |work|
      include_dir = File.join(work, 'include/erx')
      FileUtils.mkdir_p(include_dir)
      File.write(File.join(include_dir, 'abi.h'), Erx::ABI::CEmitter.header(model))
      File.write(File.join(include_dir, 'abi_reader.h'), Erx::ABI::CEmitter.reader_header(model))
      File.write(File.join(work, 'reader.c'),
                 Erx::ABI::CEmitter.prefix_source(model) + Erx::ABI::CReaderEmitter.source(model))
      File.write(File.join(work, 'main.c'), program)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', 'clang', '-std=c17', '-Wall', '-Wextra',
                                       '-Werror', '-I', File.join(work, 'include'), '-I', File.join(ROOT, 'include'),
                                       '-o', File.join(work, 'encode'), File.join(work, 'reader.c'),
                                       File.join(work, 'main.c'), stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e(File.join(work, 'encode'), stdin_data: '')
      assert status.success?, output
      assert_match(/#{layouts.size} layouts, 0 wrong/, output)
    end
  end

  # One layout's check in the encoder's program: its sample decoded, then encoded into
  # a buffer one byte longer, which must hold the sample and leave the last byte alone.
  def encode_check(layout)
    prefix = Erx::ABI::CEmitter.name(layout.name)
    <<~C
      	{
      		static const uint8_t in[] = { #{Samples.sample(layout).bytes.join(', ')} };
      		uint8_t out[sizeof(in) + 1];
      		#{Erx::ABI::CEmitter.c_type(layout)} value;

      		memset(out, 0xa5, sizeof(out));
      		if (!#{prefix}_decode(in, sizeof(in), &value) || !#{prefix}_encode(&value, out, sizeof(in)) ||
      		    memcmp(in, out, sizeof(in)) != 0 || out[sizeof(in)] != 0xa5 ||
      		    #{prefix}_encode(&value, out, sizeof(in) - 1)) {
      			printf("wrong: %s\\n", "#{layout.name}");
      			wrong++;
      		}
      	}
    C
  end

  # Bytes for one layout built from its declaration: its sample, every field at a value
  # its type admits, and its refused variants, one per enum or flags field and padding run.
  module Samples
    module_function

    def cases(layout)
      bytes = sample(layout)
      refused = layout.fields.filter_map { |field| refused_field(layout, bytes, field) } +
                layout.padding.map { |offset, _size| term(layout, poke(bytes, offset, "\x01"), "{error, {padding, '#{layout.name}'}}") }
      [term(layout, bytes, 'ok'),
       term(layout, bytes + "\x00", "{error, {size, '#{layout.name}'}}"),
       *refused]
    end

    def term(layout, bytes, expected) = "{'#{layout.name}', <<#{bytes.bytes.join(',')}>>, #{expected}}.\n"

    def poke(bytes, offset, value) = bytes.dup.tap { |copy| copy[offset, value.bytesize] = value }

    def sample(layout)
      bytes = "\x00".b * layout.size
      layout.fields.each { |field| bytes = poke(bytes, field.offset, field_bytes(field)) }
      bytes
    end

    def field_bytes(field) = ([element_bytes(field)] * (field.count || 1)).join

    def element_bytes(field)
      case field.type
      in Erx::ABI::Layout then sample(field.type)
      in Erx::ABI::EnumType then integer_bytes(admitted(field.type), field.type.size)
      in Erx::ABI::ScalarType then integer_bytes(field.type.maximum, field.type.size)
      in Erx::ABI::BytesType if field.type.fixed then field.type.fixed.b
      in Erx::ABI::BytesType then (1..field.type.size).map(&:chr).join.b
      else (1..field.type.size).map { |index| ((field.offset + index) % 256).chr }.join.b
      end
    end

    def admitted(type)
      return type.allowed.max if type.allowed

      type.flags ? type.mask : type.members.values.max
    end

    def integer_bytes(value, size) = [value].pack('Q<').byteslice(0, size)

    # The field's first element at a value its type does not admit, with the error
    # decode/2 gives for it; nil for a field whose type admits every value.
    def refused_field(layout, bytes, field)
      type = field.type
      case type
      in Erx::ABI::BytesType if type.fixed
        wrong = (type.fixed.getbyte(0) ^ 0xff).chr + type.fixed.b[1..]
        term(layout, poke(bytes, field.offset, wrong), "{error, {'#{type.name}', <<#{wrong.bytes.join(',')}>>}}")
      in Erx::ABI::EnumType | Erx::ABI::ScalarType
        value = type.is_a?(Erx::ABI::ScalarType) ? type.maximum + 1 : refused_value(type)
        return nil unless value && value < 1 << (type.size * 8)

        term(layout, poke(bytes, field.offset, integer_bytes(value, type.size)), "{error, {'#{type.name}', #{value}}}")
      else nil
      end
    end

    def refused_value(type)
      limit = 1 << (type.size * 8)
      if type.allowed
        (0...limit).find { |value| value & ~type.mask == 0 && !type.allowed.include?(value) } ||
          (0...limit).find { |value| value & ~type.mask != 0 }
      elsif type.flags
        (0...(type.size * 8)).map { |bit| 1 << bit }.find { |bit| (bit & type.mask).zero? }
      else
        (0...limit).find { |value| !type.members.value?(value) }
      end
    end
  end

  private

  def layout_module(model) = Erx::ABI::LayoutEmitter.outputs(model).fetch(Erx::ABI::LayoutEmitter::ERLANG_PATH)

  # Compiles erx_abi_enums and erx_abi_layout of the model, with one text of the layout
  # module replaced when a fault is seeded, and evaluates the expression on them; a crash
  # in the expression halts with a failure status.
  def run_generated(model, expression, fault: nil)
    Dir.mktmpdir('erx-abi-layout-') do |work|
      text = layout_module(model)
      enums = Erx::ABI::ErlangEmitter.outputs(model).fetch(ENUMS_PATH)
      if fault
        assert_includes text + enums, fault.first
        text = text.sub(fault.first, fault.last)
        enums = enums.sub(fault.first, fault.last)
      end
      sources = { 'erx_abi_layout.erl' => text, 'erx_abi_enums.erl' => enums }.map do |name, body|
        File.join(work, name).tap { |path| File.write(path, body) }
      end
      # A seeded fault may leave a helper unused: -Werror holds only for the faultless text.
      flags = fault ? [] : ['-Werror']
      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERLC'), *flags, '-o', work,
                                       *sources, stdin_data: '')
      assert status.success?, output
      guarded = "try begin #{expression.strip.delete_suffix('.')} end catch Class:Reason -> " \
                'io:format("~p~n", [{Class, Reason}]), halt(1) end.'
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', guarded, stdin_data: '')
    end
  end
end
