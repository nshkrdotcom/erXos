# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi_model'
require_relative '../../tools/lib/erx/abi_emit_c'
require_relative '../../tools/lib/erx/abi_emit_packed'

# The layout language's packed storage (docs/design-abi.md, "Packed layouts"): the model
# admits fields at any byte offset only in a packed_le layout and still checks every
# offset against the widths, refuses each member a packed layout cannot hold, C declares
# nothing for one, and erx_abi_packed, compiled on stock's compiler (ERX_ERLC) and run on
# its emulator (ERX_ERL), reads and writes the sample's bytes and refuses a value wider
# than its field.
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
    output = run_generated(schema(SAMPLE), expression)
    assert_includes output, 'packed ok'
  end

  private

  def run_generated(model, expression)
    Dir.mktmpdir('erx-abi-packed-') do |work|
      source = File.join(work, 'erx_abi_packed.erl')
      File.write(source, Erx::ABI::PackedEmitter.outputs(model).fetch(Erx::ABI::PackedEmitter::ERLANG_PATH))
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, source,
                                       stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', expression, stdin_data: '')
      assert status.success?, output
      output
    end
  end
end
