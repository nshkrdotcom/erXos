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
# it. On the tree's formats, every address a record holds is placed by the sequencer,
# never free, and each form's encoder, compiled with ERX_CLANG, writes a record equal to
# one checked by hand from the specification, and refuses a value its bits cannot hold
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
      field buffer u64 0
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
    layout erx_sample_event wire_le 8 16
      field pointer u64 0
      field status u32 8
        bits code 24 31
      field control u32 12
        bits cycle 0 0
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
    'a signed field' => ['field buffer u64 0', 'field buffer i64 0', 'a marked layout holds unsigned integer fields only']
  }.freeze

  # The places of the tree's formats that hold a device address; the sequencer writes
  # each from a name or from where it places the record, so none is free once its layout
  # is marked. The command TRBs are marked by the package that moves the TRB form.
  ADDRESSES = {
    'erx_virtq_desc' => %w[addr],
    'erx_xhci_trb_normal' => %w[buffer],
    'erx_xhci_trb_data' => %w[buffer],
    'erx_xhci_trb_link' => %w[segment.segment_pointer],
    'erx_xhci_endpoint_context' => %w[dequeue.dequeue_pointer],
    'erx_xhci_dcbaa_entry' => %w[entry.address],
    'erx_xhci_scratchpad_entry' => %w[entry.page],
    'erx_xhci_segment_table_entry' => %w[base],
    'erx_xhci_trb_command' => %w[parameter.pointer],
    'erx_xhci_trb_set_dequeue' => %w[parameter.pointer]
  }.freeze

  # Each form's records, encoded and compared with bytes worked out by hand:
  # the descriptor (VIRTIO 1.2, 2.7.5) of a 512-byte buffer the device writes, with
  # NEXT set and next 5; a normal TRB (xHCI 1.2, 6.4.1.1) of 64 bytes with interrupt on
  # completion and the cycle bit set, type 1 at bits 15:10; a link TRB (6.4.4.1) to
  # 0x80002000 with toggle cycle, type 6; a setup stage TRB (6.4.1.2.1) of a GET_DESCRIPTOR
  # (80 06 00 01 00 00 12 00), length 8, immediate data, IN, cycle set, type 2. The two
  # refused records are a transfer type of 4 in two bits and a link to an address that is
  # not 16-byte aligned; each must leave the record's 0xaa bytes untouched.
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
    	erx_virtq_desc_t desc;
    	erx_xhci_trb_normal_t normal;
    	erx_xhci_trb_link_t link;
    	erx_xhci_trb_setup_t setup;
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

    	setup_free.control_transfer_type = 4;
    	memset(&setup, 0xaa, sizeof(setup));
    	check("trb_setup refused", erx_xhci_trb_setup_encode(&setup, &setup_free,
    	    &(erx_xhci_trb_setup_placed_t){ .control_cycle = 1 }), false, &setup,
    	    untouched, sizeof(setup));
    	link_placed.segment_segment_pointer = UINT64_C(0x80002008);
    	memset(&link, 0xaa, sizeof(link));
    	check("trb_link refused", erx_xhci_trb_link_encode(&link, &link_placed),
    	    false, &link, untouched, sizeof(link));
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
      'a place marked twice' => [Erx::ABI::Marks.singleton_class, :refuse_twice, ->(*) {}]
    }.each do |label, (owner, method, body)|
      original, replacement, = REFUSALS.fetch(label)
      with_fault(owner, method, body) { sample(edit(SAMPLE, original, replacement)) }
    end
  end

  def test_every_address_is_placed
    assert_empty address_violations(tree_schema(Dir.mktmpdir('erx-abi-marks-')))
  end

  # A seeded fault: the descriptor's address left without its mark, so it is free.
  def test_an_unmarked_address_is_caught
    directory = Dir.mktmpdir('erx-abi-marks-')
    seed(directory, 'abi/formats/virtio.txt', "  refers addr data length len\n", '')
    assert_equal ['erx_virtq_desc addr is free'], address_violations(tree_schema(directory, copied: true))
  end

  def test_encoders_write_hand_checked_records
    header = Erx::ABI::CEmitter.header(tree_schema(Dir.mktmpdir('erx-abi-marks-')))
    output, status = run_encoders(header)
    assert status.success?, output
  end

  # A seeded fault in the generated code: the link encoder without its toggle cycle bit.
  def test_a_dropped_fixed_value_is_caught
    header = Erx::ABI::CEmitter.header(tree_schema(Dir.mktmpdir('erx-abi-marks-')))
    seeded = edit(header, "erx_xhci_trb_link_control_toggle_cycle_set(&out.control,\n\t        UINT32_C(1))",
                  "erx_xhci_trb_link_control_toggle_cycle_set(&out.control,\n\t        UINT32_C(0))")
    output, status = run_encoders(seeded)
    refute status.success?
    assert_equal "trb_link: encoded 1, bytes differ 1\n", output
  end

  private

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

  def address_violations(schema)
    ADDRESSES.flat_map do |layout, spellings|
      marked = meaning(schema, layout)
      next [] unless marked

      placed = marked.placed.map(&:spelling)
      spellings.reject { |spelling| placed.include?(spelling) }.map { |spelling| "#{layout} #{spelling} is free" }
    end
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
