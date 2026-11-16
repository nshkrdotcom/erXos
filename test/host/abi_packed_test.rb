# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi_model'
require_relative '../../tools/lib/erx/abi_emit_c'
require_relative '../../tools/lib/erx/abi_emit_packed'

# The layout language's packed storages and element sequences (docs/design-abi.md,
# "Packed layouts" and "Element sequences"): the model admits fields at any byte offset
# only in a packed_le or packed_be layout and still checks every offset against the
# widths, refuses each member a packed layout cannot hold, C declares nothing for one,
# and validates every element sequence row; erx_abi_packed, compiled on stock's
# compiler (ERX_ERLC) and run on its emulator (ERX_ERL), reads and writes the samples'
# bytes in each byte order, walks element sequences to the end of their bytes, and
# refuses a value wider than its field, a length overrunning the bytes, a truncated
# header and a second element that appears once.
class AbiPackedTest < Minitest::Test
  # A u64 at offset 1 and a u32 at offset 9: misaligned in any other storage. Each array
  # shape decode/2 distinguishes is here: integers, bytes, a bytes type and a layout.
  SAMPLE = <<~ABI
    bytes sample_tag 2
    layout sample_part packed_le 1 3
      field kind u8 0
      field size u16 1
    layout sample packed_le 1 32
      field first u8 0
      field wide u64 1
      field odd u32 9
      field words u16 13 count 2
      field name u8 17 count 3
      field tags sample_tag 20 count 2
      field part sample_part 24
      field parts sample_part 27 count 1
      padding 30 2
  ABI

  # The same shapes big-endian: every integer wider than a byte, in arrays and in an
  # embedded layout, is read most significant byte first.
  BIG_SAMPLE = <<~ABI
    layout big_part packed_be 1 3
      field kind u8 0
      field size u16 1
    layout big packed_be 1 20
      field first u8 0
      field wide u64 1
      field odd u32 9
      field words u16 13 count 2
      field part big_part 17
  ABI

  # One sequence of each byte order. ies has a body of each kind: bounded bytes once
  # (name), a packed layout once (part), bytes of at least one byte that repeat
  # (vendor), and bytes whose every length its u8 can count is accepted (any). tlv has
  # 16-bit big-endian tags and lengths.
  ELEMENTS_SAMPLE = <<~ABI
    enum ie_tag u8
      value name 0
      value part 1
      value any 2
      value vendor 221
    layout ie_part packed_le 1 3
      field kind u8 0
      field size u16 1
    elements ies packed_le ie_tag u8
      element name once bytes 0 4
      element part once ie_part
      element any many bytes 0 255
      element vendor many bytes 1 255
    enum tlv_tag u16
      value word 0x1000
      value text 0x1001
    layout tlv_word packed_be 1 2
      field value u16 0
    elements tlv packed_be tlv_tag u16
      element word once tlv_word
      element text once bytes 0 8
    enum kd_tag u8
      value data 1
      value pad 221
    elements kd packed_le kd_tag u8 end pad
      element data many bytes 0 255
      element pad many bytes 1 255
  ABI

  def schema(body)
    text = "abi 1\n#{body}"
    declarations = Erx::ABI::Syntax.parse(text, path: 'abi/erx_abi.txt')
    source = Erx::ABI::SourceSet.new(declarations: declarations.freeze,
                                    inputs: { 'abi/erx_abi.txt' => text.freeze }.freeze).freeze
    Erx::ABI::Model.validate(source)
  end

  def refused(body)
    assert_raises(Erx::ABI::SchemaError) { schema(body) }.message
  end

  def test_a_packed_layout_keeps_its_misaligned_offsets
    layout = schema(SAMPLE).types.fetch('sample')
    assert_equal [0, 1, 9, 13, 17, 20, 24, 27], layout.fields.map(&:offset)
    assert_equal 32, layout.size
  end

  def test_every_other_storage_keeps_the_alignment_rule
    assert_match(/misaligned field/, refused("layout sample wire_le 8 16\n  field first u8 0\n  field wide u64 1\n  padding 9 7\n"))
  end

  def test_offsets_are_still_checked_against_the_widths
    assert_match(/fields overlap/, refused(SAMPLE.sub('field odd u32 9', 'field odd u32 10')))
  end

  def test_each_member_a_packed_layout_cannot_hold_is_refused
    {
      'an alignment other than 1' => ['layout sample packed_le 1 32', 'layout sample packed_le 4 32', /alignment 1/],
      'a bit range' => ['field odd u32 9', "field odd u32 9\n    bits low 0 3", /only fields and padding/],
      'a tail' => ['padding 30 2', "padding 30 2\n  tail rest u8 first 4", /only fields and padding/],
      'a signed integer' => ['field odd u32 9', 'field odd i32 9', /unsigned integer, bytes or a packed layout/],
      'fixed bytes' => ['bytes sample_tag 2', 'bytes sample_tag 2 value 0102', /unsigned integer, bytes or a packed layout/],
      'a wire layout inside' => ["layout sample_part packed_le 1 3\n  field kind u8 0\n  field size u16 1",
                                 "layout sample_part wire_le 1 3\n  field kind u8 0\n  field size u8 1\n  padding 2 1",
                                 /storage differs/]
    }.each do |label, (text, broken, message)|
      assert_includes SAMPLE, text, label
      assert_match message, refused(SAMPLE.sub(text, broken)), label
    end
  end

  def test_a_wire_layout_cannot_embed_a_packed_one
    body = "layout part packed_le 1 1\n  field kind u8 0\nlayout whole wire_le 1 1\n  field part part 0\n"
    assert_match(/storage differs/, refused(body))
  end

  def test_c_declares_nothing_for_a_packed_layout
    header = Erx::ABI::CEmitter.header(schema(SAMPLE))
    refute_match(/erx_sample|ERX_SAMPLE/i, header.lines.grep_v(/sample_tag/).join)
  end

  def test_fields_whose_variables_clash_are_refused
    clash = "layout clash packed_le 1 2\n  field a_b u8 0\n  field a__b u8 1\n"
    error = assert_raises(Erx::ABI::SchemaError) { Erx::ABI::PackedEmitter.outputs(schema(clash)) }
    assert_match(/share the variable AB/, error.message)
  end

  # The sample's bytes, written out field by field, against the module's decode/2 and
  # encode/2; decode/2 refuses bytes one short or one over the layout's size, and
  # encode/2 a value one bit too wide or negative, an array of the wrong length and a
  # byte field of the wrong size.
  def test_the_generated_module_reads_and_writes_the_sample
    expression = <<~ERLANG.tr("\n", ' ')
      Bytes = <<1, 2,3,4,5,6,7,8,9, 10,11,12,13, 14,15,16,17, "abc", "deFG",
                1,2,0, 3,4,0, 0,0>>,
      Map = \#{first => 1, wide => 16#0908070605040302, odd => 16#0d0c0b0a,
              words => [16#0f0e, 16#1110], name => <<"abc">>, tags => [<<"de">>, <<"FG">>],
              part => \#{kind => 1, size => 2}, parts => [\#{kind => 3, size => 4}]},
      Map = erx_abi_packed:decode(sample, Bytes),
      Bytes = erx_abi_packed:encode(sample, Map),
      Refused = fun(F) -> try F() of _ -> accepted catch error:_ -> refused end end,
      <<Short:31/binary, _>> = Bytes,
      refused = Refused(fun() -> erx_abi_packed:decode(sample, Short) end),
      refused = Refused(fun() -> erx_abi_packed:decode(sample, <<Bytes/binary, 0>>) end),
      [refused = Refused(fun() -> erx_abi_packed:encode(sample, maps:merge(Map, Bad)) end)
       || Bad <- [\#{odd => 1 bsl 32}, \#{odd => -1}, \#{words => [1]}, \#{words => [1, 2, 3]},
                  \#{name => <<"ab">>}, \#{tags => [<<"de">>]}, \#{parts => []}]],
      io:format("packed ok~n"), halt(0).
    ERLANG
    output, status = run_generated(schema(SAMPLE), expression)
    assert status.success?, output
    assert_includes output, 'packed ok'
  end

  def test_a_big_endian_layout_keeps_its_misaligned_offsets
    layout = schema(BIG_SAMPLE).types.fetch('big')
    assert_equal [0, 1, 9, 13, 17], layout.fields.map(&:offset)
    assert_equal 'big', layout.byte_order
  end

  def test_a_packed_layout_embeds_only_its_own_byte_order
    mixed = BIG_SAMPLE.sub('layout big_part packed_be 1 3', 'layout big_part packed_le 1 3')
    assert_match(/storage differs/, refused(mixed))
  end

  def test_c_declares_nothing_for_a_big_endian_layout
    refute_match(/erx_big|ERX_BIG/i, Erx::ABI::CEmitter.header(schema(BIG_SAMPLE)))
  end

  # The bytes, written out most significant byte first.
  BIG_EXPRESSION = <<~ERLANG.tr("\n", ' ')
    Bytes = <<1, 2,3,4,5,6,7,8,9, 10,11,12,13, 14,15,16,17, 1,2,3>>,
    Map = \#{first => 1, wide => 16#0203040506070809, odd => 16#0a0b0c0d,
            words => [16#0e0f, 16#1011], part => \#{kind => 1, size => 16#0203}},
    Map = erx_abi_packed:decode(big, Bytes),
    Bytes = erx_abi_packed:encode(big, Map),
    io:format("big ok~n"), halt(0).
  ERLANG

  def test_the_generated_module_reads_and_writes_big_endian_fields
    output, status = run_generated(schema(BIG_SAMPLE), BIG_EXPRESSION)
    assert status.success?, output
    assert_includes output, 'big ok'
  end

  def test_an_element_sequence_is_validated_row_by_row
    sequence = schema(ELEMENTS_SAMPLE).elements.find { |item| item.name == 'ies' }
    assert_equal [%w[name once], %w[part once], %w[any many], %w[vendor many]],
                 sequence.elements.map { |element| [element.name, element.repeat] }
    assert_equal [[0, 4], [3, 3], [0, 255], [1, 255]], sequence.elements.map { |element| [element.minimum, element.maximum] }
    {
      'a storage that is not packed' => ['elements ies packed_le', 'elements ies wire_le', /packed storage/],
      'tags that are not an enum' => ['elements ies packed_le ie_tag u8', 'elements ies packed_le u8 u8', /enum over an unsigned/],
      'a signed length' => ['elements ies packed_le ie_tag u8', 'elements ies packed_le ie_tag i8', /length is an unsigned/],
      'a member with no element' => ["  element any many bytes 0 255\n", '', /tag any has no element/],
      'a duplicate element' => ["  element any many bytes 0 255\n", "  element any many bytes 0 255\n" * 2, /duplicate element/],
      'tags out of order' => ["  element name once bytes 0 4\n  element part once ie_part\n",
                              "  element part once ie_part\n  element name once bytes 0 4\n", /ascending tag order/],
      'an unknown member' => ['element vendor many', 'element vendors many', /not a member of ie_tag/],
      'an unknown repeat' => ['element vendor many', 'element vendor twice', /once or many/],
      'a body of another byte order' => ['element word once tlv_word', 'element word once ie_part', /not a layout of storage/],
      'a body its length cannot count' => ['element vendor many bytes 1 255', 'element vendor many bytes 1 256', /outside 0..255/],
      'bounds out of order' => ['element name once bytes 0 4', 'element name once bytes 5 4', /minimum exceeds/],
      'a malformed body' => ['element name once bytes 0 4', 'element name once range 0 4', /expected bytes MIN MAX/],
      'a malformed end marker' => ['u8 end pad', 'u8 until pad', /\[end MEMBER\]/],
      'an end marker of no member' => ['end pad', 'end pads', /end marker pads is not a member of kd_tag/],
      'an end marker that is also an empty element' => ['element pad many bytes 1 255', 'element pad many bytes 0 255', /at least one byte/]
    }.each do |label, (text, broken, message)|
      assert_includes ELEMENTS_SAMPLE, text, label
      assert_match message, refused(ELEMENTS_SAMPLE.sub(text, broken)), label
    end
  end

  def test_a_layout_body_its_length_cannot_count_is_refused
    body = "enum t u8\n  value big 0\nlayout wide packed_le 1 256\n  padding 0 256\nelements s packed_le t u8\n  element big once wide\n"
    assert_match(/longer than its length can count/, refused(body))
  end

  # The ies bytes hold an element of every kind and one of an unknown tag, 9, which
  # decoding skips and encoding cannot write back. Each refusal is one malformed
  # sequence: a header cut short, a length one past the bytes, a body each kind of bound
  # refuses, and a second name; encode_elements/2 refuses each wrong input.
  ELEMENTS_EXPRESSION = <<~ERLANG.tr("\n", ' ')
    Known = <<0,3,"abc", 1,3,1,2,0, 221,1,"v", 2,0, 221,2,"ww">>,
    <<Name:5/binary, Rest/binary>> = Known,
    Elements = [{name, <<"abc">>}, {part, \#{kind => 1, size => 2}}, {vendor, <<"v">>},
                {any, <<>>}, {vendor, <<"ww">>}],
    {ok, Elements} = erx_abi_packed:decode_elements(ies, <<Name/binary, 9,2,"zz", Rest/binary>>),
    Known = erx_abi_packed:encode_elements(ies, Elements),
    {ok, []} = erx_abi_packed:decode_elements(ies, <<>>),
    {error, truncated} = erx_abi_packed:decode_elements(ies, <<Known/binary, 0>>),
    {error, overrun} = erx_abi_packed:decode_elements(ies, <<0,4,"abc">>),
    {error, {length, part}} = erx_abi_packed:decode_elements(ies, <<1,2,1,2>>),
    {error, {length, name}} = erx_abi_packed:decode_elements(ies, <<0,5,"abcde">>),
    {error, {length, vendor}} = erx_abi_packed:decode_elements(ies, <<221,0>>),
    {error, {duplicate, name}} = erx_abi_packed:decode_elements(ies, <<0,0, 0,0>>),
    Tlv = <<16#10,0, 0,2, 16#ab,16#cd, 16#10,1, 0,2, "hi">>,
    {ok, [{word, \#{value := 16#abcd}}, {text, <<"hi">>}] = Words} =
        erx_abi_packed:decode_elements(tlv, <<Tlv/binary, 16#20,0, 0,1, 0>>),
    Tlv = erx_abi_packed:encode_elements(tlv, Words),
    {error, truncated} = erx_abi_packed:decode_elements(tlv, <<16#10,0, 0>>),
    {error, overrun} = erx_abi_packed:decode_elements(tlv, <<16#10,1, 0,3, "hi">>),
    Refused = fun(F) -> try F() of _ -> accepted catch error:_ -> refused end end,
    [refused = Refused(fun() -> erx_abi_packed:encode_elements(ies, Bad) end)
     || Bad <- [[{name, <<>>}, {name, <<>>}], [{name, <<"abcde">>}], [{vendor, <<>>}],
                [{other, <<>>}], [{part, \#{kind => 1}}], [not_a_pair]]],
    {ok, [{data, <<"a">>}]} = erx_abi_packed:decode_elements(kd, <<1,1,"a", 221,0, 7,9>>),
    {ok, [{data, <<"a">>}]} = erx_abi_packed:decode_elements(kd, <<1,1,"a", 221>>),
    {ok, [{pad, <<"p">>}, {data, <<>>}]} = erx_abi_packed:decode_elements(kd, <<221,1,"p", 1,0, 221,0,0>>),
    {error, truncated} = erx_abi_packed:decode_elements(kd, <<1,1,"a", 0>>),
    <<221,1,"p", 1,0>> = erx_abi_packed:encode_elements(kd, [{pad, <<"p">>}, {data, <<>>}]),
    refused = Refused(fun() -> erx_abi_packed:encode_elements(kd, [{pad, <<>>}]) end),
    io:format("elements ok~n"), halt(0).
  ERLANG

  def test_the_generated_module_reads_and_writes_element_sequences
    output, status = run_generated(schema(ELEMENTS_SAMPLE), ELEMENTS_EXPRESSION)
    assert status.success?, output
    assert_includes output, 'elements ok'
  end

  # Seeded faults: the expressions above fail on a generated module whose walk admits a
  # length one byte past what remains, or whose big-endian segments are read
  # little-endian.
  def test_the_element_expression_catches_a_length_bound_off_by_one
    fault = ['when Length =< byte_size(Rest) ->', 'when Length =< byte_size(Rest) + 1 ->']
    output, status = run_generated(schema(ELEMENTS_SAMPLE), ELEMENTS_EXPRESSION, fault: fault)
    refute status.success?, output
  end

  # The end marker's two clauses, each seeded away: a length-zero header read as an
  # element, and a lone trailing tag read as a truncated header.
  def test_the_element_expression_catches_a_missing_end_marker
    [["header(kd, <<221:8, 0:8, _/binary>>) ->", "header(kd, <<221:8, 1:8, _/binary>>) ->"],
     ["header(kd, <<221:8>>) ->", "header(kd, <<222:8>>) ->"]].each do |fault|
      output, status = run_generated(schema(ELEMENTS_SAMPLE), ELEMENTS_EXPRESSION, fault: fault)
      refute status.success?, output
    end
  end

  def test_the_big_endian_expression_catches_a_flipped_byte_order
    output, status = run_generated(schema(BIG_SAMPLE), BIG_EXPRESSION, fault: ['/big', '/little'])
    refute status.success?, output
  end

  private

  # Compiles the generated module, with one text replaced by another when a fault is
  # seeded, and evaluates the expression on it; a crash in the expression halts with a
  # failure status rather than leaving the emulator waiting.
  def run_generated(model, expression, fault: nil)
    Dir.mktmpdir('erx-abi-packed-') do |work|
      source = File.join(work, 'erx_abi_packed.erl')
      text = Erx::ABI::PackedEmitter.outputs(model).fetch(Erx::ABI::PackedEmitter::ERLANG_PATH)
      if fault
        assert_includes text, fault.first
        text = text.gsub(fault.first, fault.last)
      end
      File.write(source, text)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, source,
                                       stdin_data: '')
      assert status.success?, output
      guarded = "try begin #{expression.strip.delete_suffix('.')} end catch Class:Reason -> io:format(\"~p~n\", [{Class, Reason}]), halt(1) end."
      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', guarded, stdin_data: '')
    end
  end
end
