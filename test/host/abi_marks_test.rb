# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'

# The DMA marks of abi/formats (docs/design-device-dma.md, "What the formats say") and
# the encoders generated from them. On a sample format, the layouts with a meaning line
# become numbered meanings of their structure, a meaning of a device structure a report,
# and each malformed mark, and each set of meanings placement or acquisition could not
# tell apart, is refused with a line naming it. On the tree's formats, a device address
# left for a description to state is refused, a report has accessors and no encoder,
# and each form's encoder, compiled with ERX_CLANG, writes a record equal to one
# checked by hand from the specification, and refuses a value its place cannot hold
# with the record untouched. Seeded faults in the generator, the formats and the
# generated code show that each test catches what it guards.
class AbiMarksTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PATH = 'abi/erx_abi.txt'

  SAMPLE = <<~ABI
    enum sample_type u8
      value plain 1
      value noop 2
      value link 6
      value wide 0x40
    enum sample_code u8
      value ok 1
      value short 13
    enum sample_alias u8
      value link 1
    target sample_ring cpu
    target sample_events device
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
      meaning sample_ring
      selects control.type sample_type.plain
      refers buffer data length status.length
      fixed control.toggle 0
      activates control.cycle
      states status.aligned
      states status.code
      states control.spare
    layout erx_sample_noop wire_le 8 16
      padding 0 12
      field control u32 12
        bits live 0 0
        bits kind 10 15
      meaning sample_ring
      selects control.kind sample_type.noop
      activates control.live
    layout erx_sample_link wire_le 8 16
      field segment u64 0
        bits pointer 4 63 shift 4 device_address
      padding 8 4
      field control u32 12
        bits owner 0 0
        bits type 10 15
      selects control.type sample_type.link
      derived segment.pointer
      activates control.owner
    layout erx_sample_event wire_le 8 16
      field pointer u64 0 device_address
      field status u32 8
        bits code 24 31
      field control u32 12
        bits valid 0 0
      meaning sample_events
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
    'a length whose bytes exceed 64 bits' => ['length status.length', 'length status.length unit 281474976710656',
                                              'status.length times 281474976710656 can exceed 64 bits'],
    'a signed field' => ['field buffer u64 0 device_address', 'field buffer i64 0', 'a marked layout holds unsigned integer fields only'],
    'a place claimed by no mark' => ["\n  states control.spare", '', 'control.spare is claimed by no mark'],
    'a reference to a place that is no device address' => ['field buffer u64 0 device_address', 'field buffer u64 0',
                                                            'refers names a device address, and buffer is not one'],
    'a device address a description states' => ['refers buffer data length status.length',
                                                "states buffer\n  states status.length",
                                                "device address buffer must be a reference's address, derived or released"],
    'a report with a derived place' => ['releases pointer sample_ring when status.code sample_code.ok sample_code.short',
                                        "derived pointer\n  states status.code",
                                        'a report, a meaning of a device structure, has no refers or derived mark: the device writes it'],
    'a report with a reference' => ['releases pointer sample_ring when status.code sample_code.ok sample_code.short',
                                    'refers pointer data length status.code',
                                    'a report, a meaning of a device structure, has no refers or derived mark: the device writes it'],
    'a meaning line naming two structures' => ['meaning sample_events', 'meaning sample_events sample_ring', 'meaning requires TARGET'],
    'a second meaning line' => ['meaning sample_events', "meaning sample_events\n  meaning sample_events",
                                'a layout has one meaning mark'],
    'a meaning of the buffers' => ['meaning sample_events', 'meaning data', 'a meaning names a structure, not data'],
    'a meaning of an unknown structure' => ['meaning sample_events', 'meaning sample_rings', 'unknown target sample_rings'],
    'a release on a layout that is no meaning' => ["\n  meaning sample_events", '',
                                                   'releases belongs to a report, a meaning of a device structure'],
    'a release on a meaning of a cpu structure' => ['target sample_events device', 'target sample_events cpu',
                                                    'releases belongs to a report, a meaning of a device structure'],
    'a release naming a device structure' => ['releases pointer sample_ring', 'releases pointer sample_events',
                                              'releases names sample_events, which is no cpu structure: ' \
                                              'a holding is of records the CPU wrote'],
    'a release naming the buffers' => ['releases pointer sample_ring', 'releases pointer data',
                                       'releases names data, which is no cpu structure: a holding is of records the CPU wrote'],
    'meanings of one structure in two sizes' => ["layout erx_sample_noop wire_le 8 16\n  padding 0 12",
                                                 "layout erx_sample_noop wire_le 8 24\n  padding 0 12\n  padding 16 8",
                                                 'erx_sample_trb and erx_sample_noop, meanings of sample_ring, differ in size'],
    'a meaning without a selector beside another' => ['selects control.kind sample_type.noop', 'fixed control.kind 2',
                                                      'erx_sample_noop has no selects mark, and sample_ring has more than one meaning'],
    'selectors on different bits' => ['bits kind 10 15', 'bits kind 9 14',
                                      'erx_sample_trb and erx_sample_noop, meanings of sample_ring, differ in where their selector lies'],
    'activations on different bits' => ['bits live 0 0', 'bits live 1 1',
                                        'erx_sample_trb and erx_sample_noop, meanings of sample_ring, differ in their activation'],
    'an activation in one meaning only' => ['activates control.live', 'fixed control.live 0',
                                            'erx_sample_trb and erx_sample_noop, meanings of sample_ring, differ in their activation'],
    'a selector value two layouts select' => ['sample_type.noop', 'sample_type.link',
                                              'erx_sample_noop selects the enum member erx_sample_link selects: ' \
                                              'a selector value names one layout of its file'],
    'one selector value spelled by two enums' => ['selects control.type sample_type.link', 'selects control.type sample_alias.link',
                                                  'erx_sample_trb selects the bits erx_sample_link selects: ' \
                                                  'a selector value names one layout of its file'],
    'one selector value under another shift' => ['    bits kind 10 15', '    bits kind 10 15 shift 1',
                                                 'erx_sample_trb selects the bits erx_sample_noop selects: ' \
                                                 'a selector value names one layout of its file'],
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
  # action transfer (0x23); a virtio-gpu region entry (VIRTIO 1.2, 5.7.6) of a 4 KiB
  # region at 0x80001000, its padding 0. The refused records are a transfer type of 4 in
  # two bits, a link to an address that is not 16-byte aligned, a normal TRB's length of
  # 0x100000040, whose low 32 bits would fit its 17, an ADMA2 address above 32 bits and a
  # region entry's length of 4 GiB; each must leave the record's 0xaa bytes untouched.
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
    	static const unsigned char mem_entry_bytes[16] = {
    		0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00,
    		0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    	erx_virtq_desc_t desc;
    	erx_xhci_trb_normal_t normal;
    	erx_xhci_trb_link_t link;
    	erx_xhci_trb_setup_t setup;
    	erx_sdhci_adma2_entry_t adma2;
    	erx_virtio_gpu_mem_entry_t mem_entry;
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
    	memset(&mem_entry, 0xaa, sizeof(mem_entry));
    	check("mem_entry", erx_virtio_gpu_mem_entry_encode(&mem_entry,
    	    &(erx_virtio_gpu_mem_entry_placed_t){ .addr = UINT64_C(0x80001000),
    	    .length = 0x1000 }), true, &mem_entry, mem_entry_bytes,
    	    sizeof(mem_entry));

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
    	memset(&mem_entry, 0xaa, sizeof(mem_entry));
    	check("mem_entry wide", erx_virtio_gpu_mem_entry_encode(&mem_entry,
    	    &(erx_virtio_gpu_mem_entry_placed_t){ .addr = UINT64_C(0x80001000),
    	    .length = UINT64_C(0x100000000) }), false, &mem_entry, untouched,
    	    sizeof(mem_entry));
    	return (failures == 0 ? 0 : 1);
    }
  C

  # A call of an encoder of the port status change event, a report, with the input
  # structs an encoder of its places would take; it must not build.
  DESCRIBES = <<~C
    #include <stdio.h>
    #include "erx/abi.h"

    int
    main(void)
    {
    	erx_meaning_free_t described = { .virtq_desc = { .len = 300, .flags_write = 1 } };
    	erx_meaning_reference_t references[ERX_MEANING_REFERENCES_MAX];
    	size_t count = 9;
    	int right = erx_meaning_describes(ERX_MEANING_VIRTQ_DESC, &described, references, &count) &&
    	    count == 1 && references[0].target == ERX_REFERS_DATA && references[0].length == 300;

    	described.virtq_desc.len = UINT64_C(1) << 32;
    	right = right && !erx_meaning_describes(ERX_MEANING_VIRTQ_DESC, &described, references, &count);
    	right = right && !erx_meaning_describes(ERX_MEANING_VIRTQ_USED_ELEM, &described, references, &count);
    	right = right && erx_meaning_structure(ERX_MEANING_XHCI_TRB_NORMAL) == ERX_STRUCTURE_XHCI_TRANSFER_RING &&
    	    erx_meaning_structure(0) == 0;
    	right = right && erx_structure_device_writes(ERX_STRUCTURE_VIRTQ_USED) &&
    	    !erx_structure_device_writes(ERX_STRUCTURE_VIRTQ_AVAIL);
    	printf("%s\\n", right ? "described" : "wrong");
    	return (right ? 0 : 1);
    }
  C

  ENCODE_A_REPORT = <<~C
    #include "erx/abi.h"

    int
    main(void)
    {
    	erx_xhci_trb_port_event_t event;

    	return (erx_xhci_trb_port_event_encode(&event,
    	    &(erx_xhci_trb_port_event_free_t){ .parameter_port = 1 },
    	    &(erx_xhci_trb_port_event_placed_t){ .control_cycle = 1 }) ? 0 : 1);
    }
  C

  # Only a layout with a meaning line is a meaning, numbered in the order of the layouts'
  # names; a meaning of a device structure is a report; a structure offers the meanings
  # whose line names it.
  def test_marks_become_meanings
    schema = sample
    trb, noop, link, event = %w[erx_sample_trb erx_sample_noop erx_sample_link erx_sample_event].map { |name| meaning(schema, name) }
    assert_equal [3, 2, nil, 1], [trb, noop, link, event].map(&:number)
    assert_equal 3, schema.constants.fetch('meaning_sample_trb').value
    refute schema.constants.key?('meaning_sample_link')
    assert_equal [false, false, false, true], [trb, noop, link, event].map(&:report?)
    assert_equal({ 'sample_ring' => %w[erx_sample_noop erx_sample_trb], 'sample_events' => %w[erx_sample_event] },
                 schema.marks.targets.transform_values { |target| schema.marks.offered(target).map { |item| item.layout.name } })
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
    [['refers buffer data', 'refers buffer other_ring'],
     ["meaning sample_ring\n  selects control.type", "meaning other_ring\n  selects control.type"]].each do |original, replacement|
      error = assert_raises(Erx::ABI::SchemaError) { sample(edit(SAMPLE, original, replacement), other: other) }
      assert_match(%r{\A#{PATH}:\d+: target other_ring belongs to abi/formats/other.txt}, error.message)
    end
  end

  # Seeds in the generator: with each check removed, its malformed mark builds.
  def test_seeded_generator_faults_let_their_marks_through
    {
      'an unknown target' => [Erx::ABI::Marks.singleton_class, :target_name, ->(name, *) { name }],
      'a fixed value its bits cannot hold' => [Erx::ABI::Marks::Place, :holds?, ->(*) { true }],
      'a place claimed by no mark' => [Erx::ABI::Marks.singleton_class, :refuse_unclaimed, ->(*) {}],
      'a device address a description states' => [Erx::ABI::Marks.singleton_class, :refuse_free_address, ->(*) {}],
      'a selector value two layouts select' => [Erx::ABI::Marks.singleton_class, :refuse_reused_selectors, ->(*) {}],
      'meanings of one structure in two sizes' => [Erx::ABI::Marks.singleton_class, :check_meanings, ->(*) {}],
      'a release on a layout that is no meaning' => [Erx::ABI::Marks.singleton_class, :refuse_writer_marks, ->(*) {}]
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

  # A report gets its accessors and nothing that writes it. The xHCI port status change
  # event releases nothing, and is a report only because its structure, the event ring,
  # is the device's; the used element is the used ring's.
  def test_a_report_has_accessors_and_no_encoder
    header = Erx::ABI::CEmitter.header(tree_schema(Dir.mktmpdir('erx-abi-marks-')))
    assert header.include?('erx_xhci_trb_port_event_status_code_get('), 'erx_xhci_trb_port_event_status_code_get('
    assert header.include?('erx_virtq_used_elem_t'), 'erx_virtq_used_elem_t'
    %w[erx_xhci_trb_port_event_encode erx_xhci_trb_port_event_free_t erx_xhci_trb_port_event_placed_t
       erx_virtq_used_elem_encode erx_virtq_used_elem_free_t].each { |name| refute header.include?(name), name }
  end

  # A seeded fault in the generator: with no layout a report, the port status change
  # event gets an encoder, which the test above refuses.
  def test_without_reports_the_port_event_gets_an_encoder
    with_fault(Erx::ABI::Marks::MarkedLayout, :report?, ->(*) { false }) do
      header = Erx::ABI::CEmitter.header(tree_schema(Dir.mktmpdir('erx-abi-marks-')))
      assert header.include?('erx_xhci_trb_port_event_encode('), 'no encoder for the port event'
    end
  end

  # The meanings each structure offers, as the header lists them: the event ring's three
  # events, and none for the command ring, whose commands have no marks.
  def test_each_structure_lists_its_meanings
    header = Erx::ABI::CEmitter.header(tree_schema(Dir.mktmpdir('erx-abi-marks-')))
    event_ring = header[/^erx_meanings_of_xhci_event_ring\(size_t \*count\)\n\{\n(.*?)^\}/m, 1]
    assert_equal %w[ERX_MEANING_XHCI_TRB_COMMAND_EVENT ERX_MEANING_XHCI_TRB_PORT_EVENT ERX_MEANING_XHCI_TRB_TRANSFER_EVENT],
                 event_ring.scan(/ERX_MEANING_\w+/)
    assert_match(/^erx_meanings_of_xhci_command_ring\(size_t \*count\)\n\{\n\t\*count = 0;\n\treturn \(NULL\);\n\}/, header)
    refute header.include?('ERX_MEANING_XHCI_TRB_LINK'), 'the link TRB, no meaning, has a number'
  end

  # Encoding a report does not build: nothing the device states is an encoder input.
  def test_encoding_a_report_does_not_build
    header = Erx::ABI::CEmitter.header(tree_schema(Dir.mktmpdir('erx-abi-marks-')))
    output, status = compile(header, ENCODE_A_REPORT)
    refute status.success?, 'a call of a report\'s encoder built'
    assert_match(/erx_xhci_trb_port_event_encode/, output)
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

  # What the check reads of a description, generated from the marks: the meaning's
  # structure, which structures the device writes, and each reference's length from the
  # free places, refused where a free value is wider than its place.
  def test_descriptions_give_their_structure_and_reference_lengths
    header = Erx::ABI::CEmitter.header(tree_schema(Dir.mktmpdir('erx-abi-marks-')))
    output, status = compile(header, DESCRIBES) { |program| Open3.capture2e(program, stdin_data: '') }
    assert status.success?, output
    assert_equal "described\n", output
  end

  # A seeded fault in the generated code: the descriptor's length without its width
  # check in erx_meaning_describes, so a length wider than 32 bits is judged whole.
  def test_a_dropped_description_width_check_is_caught
    header = Erx::ABI::CEmitter.header(tree_schema(Dir.mktmpdir('erx-abi-marks-')))
    seeded = edit(header, "\t\tif (described->virtq_desc.len > UINT64_C(0xffffffff) ||\n\t\t    ", "\t\tif (")
    output, status = compile(seeded, DESCRIBES) { |program| Open3.capture2e(program, stdin_data: '') }
    refute status.success?
    assert_equal "wrong\n", output
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

  def meaning(schema, layout) = schema.marks.layouts.find { |item| item.layout.name == layout }

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
    compile(header, ENCODERS) do |program|
      Open3.capture2e(program, stdin_data: '')
    end
  end

  # Compiles source against header with ERX_CLANG; the compiler's output and status, or,
  # once it builds and a block is given, the block's result for the program.
  def compile(header, text)
    Dir.mktmpdir('erx-abi-encoders-') do |directory|
      FileUtils.mkdir_p(File.join(directory, 'include/erx'))
      File.write(File.join(directory, 'include/erx/abi.h'), header)
      source = File.join(directory, 'source.c')
      program = File.join(directory, 'program')
      File.write(source, text)
      output, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror',
                                       '-pedantic', '-I', File.join(directory, 'include'), '-I', File.join(ROOT, 'include'),
                                       source, '-o', program, stdin_data: '')
      return [output, status] unless status.success? && block_given?

      yield program
    end
  end
end
