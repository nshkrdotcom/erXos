# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'

# The DMA marks of abi/formats (docs/design-device-dma.md, "What the formats say") and
# the encoders generated from them. On a sample format, the marks become meanings with
# their free and placed places, and each malformed mark is refused with a line naming
# it. On the tree's formats, a device address left for a description to state is
# refused, and each form's encoder, compiled with ERX_CLANG, writes a record equal to
# one checked by hand from the specification, and refuses a value its place cannot hold
# with the record untouched. Seeded faults in the generator, the formats and the
# generated code show that each test catches what it guards.
class AbiMarksTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PATH = 'abi/erx_abi.txt'

  SAMPLE = <<~ABI
    enum sample_type u8
      value plain 1
      value link 6
      value wide 0x40
    enum sample_code u8
      value ok 1
      value short 13
    target sample_ring cpu
    layout erx_sample_trb wire_le 8 16
      field buffer u64 0 device_address
      field status u32 8
        bits length 0 16
        bits aligned 17 23 shift 4
        bits code 24 31
      field control u32 12
        bits cycle 0 0
        bits toggle 1 2
        bits spare 3 3
        bits type 10 15
      selects control.type sample_type.plain
      refers buffer data length status.length
      fixed control.toggle 0
      activates control.cycle
      states status.aligned
      states status.code
      states control.spare
    layout erx_sample_event wire_le 8 16
      field pointer u64 0 device_address
      field status u32 8
        bits code 24 31
      field control u32 12
        bits valid 0 0
      activates control.valid
      releases pointer sample_ring when status.code sample_code.ok sample_code.short
  ABI

  # Each refused mark: the sample's text, its replacement, and the refusal.
  REFUSALS = {
    'an unknown target' => ['refers buffer data', 'refers buffer sample_rings', 'unknown target sample_rings'],
    'a selects value outside its enum' => ['sample_type.plain', 'sample_type.missing', 'missing is not a member of sample_type'],
    'a selects value its bits cannot hold' => ['sample_type.plain', 'sample_type.wide', 'sample_type.wide does not fit control.type'],
    'a fixed value its bits cannot hold' => ['fixed control.toggle 0', 'fixed control.toggle 4', 'fixed value 4 does not fit control.toggle'],
    'a length naming a field of another layout' => ['length status.length', 'length pointer', 'pointer is not a field or bits of this layout'],
    'a field with bits named whole' => ['fixed control.toggle 0', 'fixed control 0', 'control is not a field or bits of this layout'],
    'an activation two bits wide' => ["fixed control.toggle 0\n  activates control.cycle", 'activates control.toggle',
                                     'activates marks one bit, not control.toggle'],
    'a place marked twice' => ['activates control.cycle', "activates control.cycle\n  derived control.cycle", 'control.cycle is marked twice'],
    'a second selector' => ['activates control.cycle', "activates control.cycle\n  selects status.code sample_type.link",
                            'a layout has one selects mark'],
    'a mark outside a wire_le layout' => ['erx_sample_trb wire_le', 'erx_sample_trb native', 'marks belong to a wire_le layout'],
    'an unknown writer' => ['target sample_ring cpu', 'target sample_ring host', 'unknown target writer host'],
    'a malformed reference' => ['refers buffer data length status.length', 'refers buffer data length', 'refers requires'],
    'a release under no code' => ['when status.code sample_code.ok sample_code.short', 'when status.code', 'releases requires'],
    'a release code outside its enum' => ['sample_code.short', 'sample_code.long', 'long is not a member of sample_code'],
    'a second activation' => ['activates control.cycle', "activates control.cycle\n  activates control.spare", 'a layout has one activates mark'],
    'a fixed value below its shift' => ['fixed control.toggle 0', "fixed control.toggle 0\n  fixed status.aligned 8",
                                        'fixed value 8 does not fit status.aligned'],
    'a length unit of zero' => ['length status.length', 'length status.length unit 0', 'a length unit is a positive byte count'],
    'a signed field' => ['field buffer u64 0 device_address', 'field buffer i64 0', 'a marked layout holds unsigned integer fields only'],
    'a place claimed by no mark' => ["\n  states control.spare", '', 'control.spare is claimed by no mark'],
    'a reference to a place that is no device address' => ['field buffer u64 0 device_address', 'field buffer u64 0',
                                                            'refers names a device address, and buffer is not one'],
    'a device address a description states' => ['refers buffer data length status.length',
                                                "states buffer\n  states status.length",
                                                "device address buffer must be a reference's address, derived or released"],
    'a report with a derived place' => ['activates control.valid', "activates control.valid\n  derived control.valid",
                                        'a report, a layout with releases, has no refers or derived mark: the device writes it'],
    'two places of one encoder member' => ["field status u32 8\n    bits code 24 31\n  field control u32 12\n    bits valid",
                                           "field control_valid u32 8\n  field control u32 12\n    bits valid",
                                           'control.valid and control_valid share the encoder member control_valid'],
    'a tail on a marked layout' => ["\n  states control.spare", "\n  states control.spare\n  tail extra u8 status 4",
                                    'a marked layout has no tail: its encoder writes the fixed part only'],
    'a device address on a field with bits' => ["field control u32 12\n    bits valid",
                                                "field control u32 12 device_address\n    bits valid",
                                                'device_address on a field with bits belongs on its bits']
  }.freeze

  # The seeded format: the descriptor's address and length stated by a description, so
  # every place is still claimed and only the device address rule refuses it.
  FREE_ADDRESS = ['abi/formats/virtio.txt', "  refers addr data length len\n", "  states addr\n  states len\n"].freeze

  # Each form's records, encoded and compared with bytes worked out by hand:
  # the descriptor (VIRTIO 1.2, 2.7.5) of a 512-byte buffer the device writes, with
  # NEXT set and next 5; a normal TRB (xHCI 1.2, 6.4.1.1) of 64 bytes with interrupt on
  # completion and the cycle bit set, type 1 at bits 15:10; a link TRB (6.4.4.1) to
  # 0x80002000 with toggle cycle, type 6; a setup stage TRB (6.4.1.2.1) of a GET_DESCRIPTOR
  # (80 06 00 01 00 00 12 00), length 8, immediate data, IN, cycle set, type 2; an ADMA2
  # entry (SD Host Controller 4.20, figure 1-10) of 512 bytes at 0x80001000, valid, end,
  # action transfer (0x23). The refused records are a transfer type of 4 in two bits, a
  # link to an address that is not 16-byte aligned, a normal TRB's length of 0x100000040,
  # whose low 32 bits would fit its 17, and an ADMA2 address above 32 bits; each must
  # leave the record's 0xaa bytes untouched.
  ENCODERS = <<~C
    #include <stdio.h>
    #include <string.h>

    #include "erx/abi.h"

    static int failures;

    static void
    check(const char *name, bool encoded, bool expected, const void *record,
        const unsigned char *want, size_t size)
    {
    	if (encoded != expected || memcmp(record, want, size) != 0) {
    		printf("%s: encoded %d, bytes differ %d\\n", name, encoded,
    		    memcmp(record, want, size) != 0);
    		failures++;
    	}
    }

    int
    main(void)
    {
    	static const unsigned char untouched[16] = {
    		0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa,
    		0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa };
    	static const unsigned char desc_bytes[16] = {
    		0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
    		0x00, 0x02, 0x00, 0x00, 0x03, 0x00, 0x05, 0x00 };
    	static const unsigned char normal_bytes[16] = {
    		0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00,
    		0x40, 0x00, 0x00, 0x00, 0x21, 0x04, 0x00, 0x00 };
    	static const unsigned char link_bytes[16] = {
    		0x00, 0x20, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00,
    		0x00, 0x00, 0x00, 0x00, 0x02, 0x18, 0x00, 0x00 };
    	static const unsigned char setup_bytes[16] = {
    		0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00,
    		0x08, 0x00, 0x00, 0x00, 0x41, 0x08, 0x03, 0x00 };
    	static const unsigned char adma2_bytes[8] = {
    		0x23, 0x00, 0x00, 0x02, 0x00, 0x10, 0x00, 0x80 };
    	erx_virtq_desc_t desc;
    	erx_xhci_trb_normal_t normal;
    	erx_xhci_trb_link_t link;
    	erx_xhci_trb_setup_t setup;
    	erx_sdhci_adma2_entry_t adma2;
    	erx_xhci_trb_setup_free_t setup_free = { .setup = UINT64_C(0x0012000001000680),
    	    .control_transfer_type = 3 };
    	erx_xhci_trb_link_placed_t link_placed = {
    	    .segment_segment_pointer = UINT64_C(0x80002000) };

    	memset(&desc, 0xaa, sizeof(desc));
    	check("virtq_desc", erx_virtq_desc_encode(&desc,
    	    &(erx_virtq_desc_free_t){ .len = 0x200, .flags_write = 1 },
    	    &(erx_virtq_desc_placed_t){ .addr = UINT64_C(0x1122334455667788),
    	    .flags_next = 1, .next = 5 }), true, &desc, desc_bytes, sizeof(desc));
    	memset(&normal, 0xaa, sizeof(normal));
    	check("trb_normal", erx_xhci_trb_normal_encode(&normal,
    	    &(erx_xhci_trb_normal_free_t){ .status_length = 0x40,
    	    .control_interrupt_on_completion = 1 },
    	    &(erx_xhci_trb_normal_placed_t){ .buffer = UINT64_C(0x80001000),
    	    .control_cycle = 1 }), true, &normal, normal_bytes, sizeof(normal));
    	memset(&link, 0xaa, sizeof(link));
    	check("trb_link", erx_xhci_trb_link_encode(&link, &link_placed), true,
    	    &link, link_bytes, sizeof(link));
    	memset(&setup, 0xaa, sizeof(setup));
    	check("trb_setup", erx_xhci_trb_setup_encode(&setup, &setup_free,
    	    &(erx_xhci_trb_setup_placed_t){ .control_cycle = 1 }), true, &setup,
    	    setup_bytes, sizeof(setup));
    	memset(&adma2, 0xaa, sizeof(adma2));
    	check("adma2_entry", erx_sdhci_adma2_entry_encode(&adma2,
    	    &(erx_sdhci_adma2_entry_placed_t){ .attributes_end = 1, .length = 0x200,
    	    .address_data = UINT64_C(0x80001000) }), true, &adma2, adma2_bytes,
    	    sizeof(adma2));

    	setup_free.control_transfer_type = 4;
    	memset(&setup, 0xaa, sizeof(setup));
    	check("trb_setup refused", erx_xhci_trb_setup_encode(&setup, &setup_free,
    	    &(erx_xhci_trb_setup_placed_t){ .control_cycle = 1 }), false, &setup,
    	    untouched, sizeof(setup));
    	link_placed.segment_segment_pointer = UINT64_C(0x80002008);
    	memset(&link, 0xaa, sizeof(link));
    	check("trb_link refused", erx_xhci_trb_link_encode(&link, &link_placed),
    	    false, &link, untouched, sizeof(link));
    	memset(&normal, 0xaa, sizeof(normal));
    	check("trb_normal wide", erx_xhci_trb_normal_encode(&normal,
    	    &(erx_xhci_trb_normal_free_t){ .status_length = UINT64_C(0x100000040) },
    	    &(erx_xhci_trb_normal_placed_t){ .buffer = UINT64_C(0x80001000),
    	    .control_cycle = 1 }), false, &normal, untouched, sizeof(normal));
    	memset(&adma2, 0xaa, sizeof(adma2));
    	check("adma2_entry wide", erx_sdhci_adma2_entry_encode(&adma2,
    	    &(erx_sdhci_adma2_entry_placed_t){ .attributes_end = 1, .length = 0x200,
    	    .address_data = UINT64_C(0x100001000) }), false, &adma2, untouched,
    	    sizeof(adma2));
    	return (failures == 0 ? 0 : 1);
    }
  C

  def test_marks_become_meanings
    trb, event = %w[erx_sample_trb erx_sample_event].map { |name| meaning(sample, name) }
    assert_equal [2, 1], [trb.number, event.number]
    assert_equal 2, sample.constants.fetch('meaning_sample_trb').value
    assert_equal %w[status.length status.aligned status.code control.spare], trb.free.map(&:spelling)
    assert_equal %w[buffer control.cycle], trb.placed.map(&:spelling)
    assert_equal [1, 'data', 'status.length'], [trb.selector.value, trb.references.first.target, trb.references.first.length.spelling]
    assert_equal ['sample_ring', [1, 13]], [event.release.target, event.release.codes]
  end

  REFUSALS.each do |label, (original, replacement, message)|
    define_method("test_refuses_#{label.tr(' ', '_')}") do
      error = assert_raises(Erx::ABI::SchemaError) { sample(edit(SAMPLE, original, replacement)) }
      assert_match(/\A#{Regexp.escape(PATH)}:\d+: #{Regexp.escape(message)}/, error.message)
    end
  end

  def test_refuses_a_target_of_another_file
    other = "target other_ring cpu\n"
    error = assert_raises(Erx::ABI::SchemaError) do
      sample(edit(SAMPLE, 'refers buffer data', 'refers buffer other_ring'), other: other)
    end
    assert_match(%r{\A#{PATH}:\d+: target other_ring belongs to abi/formats/other.txt}, error.message)
  end

  # Seeds in the generator: with each check removed, its malformed mark builds.
  def test_seeded_generator_faults_let_their_marks_through
    {
      'an unknown target' => [Erx::ABI::Marks.singleton_class, :target_name, ->(name, *) { name }],
      'a fixed value its bits cannot hold' => [Erx::ABI::Marks::Place, :holds?, ->(*) { true }],
      'a place claimed by no mark' => [Erx::ABI::Marks.singleton_class, :refuse_unclaimed, ->(*) {}],
      'a device address a description states' => [Erx::ABI::Marks.singleton_class, :refuse_free_address, ->(*) {}]
    }.each do |label, (owner, method, body)|
      original, replacement, = REFUSALS.fetch(label)
      with_fault(owner, method, body) { sample(edit(SAMPLE, original, replacement)) }
    end
  end

  # A seeded fault in the format: the descriptor's address stated by a description.
  def test_a_free_device_address_in_a_format_is_refused
    directory = Dir.mktmpdir('erx-abi-marks-')
    seed(directory, *FREE_ADDRESS)
    error = assert_raises(Erx::ABI::SchemaError) { tree_schema(directory, copied: true) }
    assert_match(%r{\Aabi/formats/virtio.txt:\d+: device address addr must be}, error.message)
  end

  # A seeded fault in the generator: without the device address rule, the same format builds.
  def test_without_the_device_address_rule_the_seeded_format_builds
    directory = Dir.mktmpdir('erx-abi-marks-')
    seed(directory, *FREE_ADDRESS)
    with_fault(Erx::ABI::Marks.singleton_class, :refuse_free_address, ->(*) {}) do
      assert meaning(tree_schema(directory, copied: true), 'erx_virtq_desc').free.map(&:spelling).include?('addr')
    end
  end

  def test_encoders_write_hand_checked_records
    header = Erx::ABI::CEmitter.header(tree_schema(Dir.mktmpdir('erx-abi-marks-')))
    output, status = run_encoders(header)
    assert status.success?, output
  end

  # A seeded fault in the generated code: the link encoder without its toggle cycle bit.
  def test_a_dropped_fixed_value_is_caught
    header = Erx::ABI::CEmitter.header(tree_schema(Dir.mktmpdir('erx-abi-marks-')))
    seeded = edit(header, "out.control |= (uint32_t)(UINT32_C(1) << 1);", "out.control |= (uint32_t)(UINT32_C(0) << 1);")
    output, status = run_encoders(seeded)
    refute status.success?
    assert_equal "trb_link: encoded 1, bytes differ 1\n", output
  end

  # A seeded fault in the generated code: the normal TRB's length without its width
  # check, so a value wider than 17 bits is cut to its low bits and written.
  def test_a_dropped_width_check_is_caught
    header = Erx::ABI::CEmitter.header(tree_schema(Dir.mktmpdir('erx-abi-marks-')))
    normal = header.index('erx_xhci_trb_normal_encode(')
    seeded = header[0...normal] + edit(header[normal..], "\tif (described->status_length > UINT64_C(0x1ffff) ||\n\t    ",
                                       "\tif (")
    output, status = run_encoders(seeded)
    refute status.success?
    assert_equal "trb_normal wide: encoded 1, bytes differ 1\n", output
  end

  # A layout has one encoder: a marked one only its meaning's in abi.h, which alone
  # writes such a record, so abi_reader.h declares no encoder of that name.
  def test_no_encoder_name_is_declared_in_both_headers
    marks, reader = encoder_names(tree_schema(Dir.mktmpdir('erx-abi-marks-')))
    refute_empty marks
    refute_empty reader
    assert_empty marks & reader
  end

  # A seeded fault in the generator: the reader encoding every fixed wire_le layout,
  # marked ones included, declares the marked layouts' encoder names a second time.
  def test_a_reader_encoder_for_a_marked_layout_is_caught
    schema = tree_schema(Dir.mktmpdir('erx-abi-marks-'))
    every_fixed = ->(model) { Erx::ABI::CEmitter.wire_layouts(model).reject(&:tail) }
    with_fault(Erx::ABI::CEmitter.singleton_class, :wire_encoded_layouts, every_fixed) do
      marks, reader = encoder_names(schema)
      refute_empty marks & reader
    end
  end

  private

  # The encoder names abi.h and abi_reader.h each declare at the start of a line.
  def encoder_names(schema)
    [Erx::ABI::CEmitter.header(schema), Erx::ABI::CEmitter.reader_header(schema)]
      .map { |text| text.scan(/^(?:bool )?(erx_\w+_encode)\(/).flatten }
  end

  def sample(text = SAMPLE, other: nil)
    body = "abi 1\n#{text}"
    inputs = { PATH => body.freeze }
    declarations = Erx::ABI::Syntax.parse(body, path: PATH)
    if other
      inputs['abi/formats/other.txt'] = other.freeze
      declarations += Erx::ABI::Syntax.parse(other, path: 'abi/formats/other.txt')
    end
    Erx::ABI::Model.validate(Erx::ABI::SourceSet.new(declarations: declarations.freeze, inputs: inputs.freeze).freeze)
  end

  def meaning(schema, layout) = schema.marks.meanings.find { |item| item.layout.name == layout }

  def edit(text, original, replacement)
    assert_equal 1, text.scan(original).size, "the edit must change exactly one place: #{original}"
    text.sub(original) { replacement }
  end

  # The schema of a copy of the tree's abi/ in directory, copied first unless it is.
  def tree_schema(directory, copied: false)
    FileUtils.cp_r(File.join(ROOT, 'abi'), directory) unless copied
    Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: directory))
  ensure
    FileUtils.remove_entry(directory)
  end

  def seed(directory, relative, original, replacement)
    FileUtils.cp_r(File.join(ROOT, 'abi'), directory)
    path = File.join(directory, relative)
    File.write(path, edit(File.read(path), original, replacement))
  end

  # Runs body with owner's method replaced, and asserts it builds; restores the method.
  def with_fault(owner, method, body)
    original = owner.instance_method(method)
    owner.send(:define_method, method, &body)
    yield
  ensure
    owner.send(:define_method, method, original)
  end

  def run_encoders(header)
    Dir.mktmpdir('erx-abi-encoders-') do |directory|
      FileUtils.mkdir_p(File.join(directory, 'include/erx'))
      File.write(File.join(directory, 'include/erx/abi.h'), header)
      source = File.join(directory, 'encoders.c')
      program = File.join(directory, 'encoders')
      File.write(source, ENCODERS)
      output, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror',
                                       '-pedantic', '-I', File.join(directory, 'include'), '-I', File.join(ROOT, 'include'),
                                       source, '-o', program, stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e(program, stdin_data: '')
    end
  end
end
