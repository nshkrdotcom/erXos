# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require_relative '../../tools/lib/erx/hardware'
require_relative '../fixtures/sanitizer_environment'

class HardwareTest < Minitest::Test
  def setup
    @repository = File.expand_path('../..', __dir__)
    @source = File.binread(File.join(@repository, 'hw/svd/pl011/pl011.svd'))
    @root = Dir.mktmpdir('erx-hardware-')
    FileUtils.mkdir_p(File.join(@root, 'hw/svd/pl011'))
    File.binwrite(File.join(@root, 'hw/svd/pl011/pl011.svd'), @source)
  end

  def teardown
    FileUtils.remove_entry(@root) if passed?
  end

  def test_register_facts_and_side_effects
    device = Erx::Hardware.parse_svd(@source)
    assert_equal [0, 4, 0x18, 0x20, 0x24, 0x28, 0x2c, 0x30, 0x34, 0x38, 0x3c, 0x40, 0x44, 0x48], device.registers.map(&:offset)
    assert_equal 0x200, device.size
    assert_equal [32], device.registers.map(&:width).uniq
    assert_equal 'modify', device.registers.first.read_action
    icr = device.registers.find { |register| register.name == 'ICR' }
    assert_equal 'write-only', icr.access
    assert icr.fields.all?(&:clear)
    output = Erx::Hardware.device_header(device)
    assert_includes output, 'erx_pl011_icr_rtic_clear'
    refute_includes output, 'erx_pl011_icr_read'
    refute_includes output, 'erx_pl011_icr_rtic_set'
    refute_includes output, 'erx_pl011_dr_modify'
  end

  def test_rsr_is_written_whole_and_its_errors_are_not_one_to_clear
    rsr = Erx::Hardware.parse_svd(@source).registers.find { |register| register.name == 'RSR' }
    assert_equal 'read-write', rsr.access
    assert_equal %w[FE PE BE OE], rsr.fields.map(&:name)
    assert rsr.fields.none?(&:clear)
    assert rsr.fields.all? { |field| field.access == 'read-only' }
    assert_equal 0, Erx::Hardware.writable_mask(rsr)
    refute Erx::Hardware.plain_update?(rsr)
    assert_match(/\.name = "rsr", .*\.plain_update = false/, Erx::Hardware.device_table_header([Erx::Hardware.parse_svd(@source)]))
  end

  def test_xml_and_semantic_rejections
    malformed = [@source + '<device/>', @source.sub('<device schemaVersion="1.3">',
                 '<!DOCTYPE device [<!ENTITY x "boom">]><device schemaVersion="1.3">'),
                 @source.sub('<width>32</width>', '<width>24</width>'),
                 @source.sub('<addressOffset>0x18</addressOffset>', '<addressOffset>2</addressOffset>'),
                 @source.sub('<bitWidth>8</bitWidth>', '<bitWidth>33</bitWidth>'),
                 @source.sub('<name>PL011</name>', '<name derivedFrom="other">PL011</name>'),
                 @source.sub('<name>PL011</name>', '<name>PL011<hidden/></name>'),
                 @source.sub('oneToClear', 'zeroToToggle'), "\xff".b]
    malformed.each { |bytes| assert_raises(Erx::Error) { Erx::Hardware.parse_svd(bytes) } }
  end

  def test_a_register_without_its_owned_mark_is_refused
    missing = @source.sub('<ownedByNif>false</ownedByNif>', '')
    error = assert_raises(Erx::Error) { Erx::Hardware.parse_svd(missing) }
    assert_match(/ownedByNif/, error.message)
    assert_raises(Erx::Error) { Erx::Hardware.parse_svd(@source.sub('<ownedByNif>false<', '<ownedByNif>maybe<')) }
    refute(Erx::Hardware.parse_svd(@source).registers.any?(&:owned_by_nif))
    marked = @source.sub('<ownedByNif>false<', '<ownedByNif>true<')
    assert_includes Erx::Hardware.device_table_header([Erx::Hardware.parse_svd(marked)]), '.owned_by_nif = true'
  end

  def test_a_register_array_is_checked_whole
    array = lambda do |dim, stride, name: 'FR[%s]'|
      @source.sub('<name>FR</name>', "<name>#{name}</name><dim>#{dim}</dim><dimIncrement>#{stride}</dimIncrement>")
    end
    fr = Erx::Hardware.parse_svd(array.call(2, 4)).registers.find { |register| register.name == 'FR' }
    assert_equal [2, 4], [fr.count, fr.stride]
    assert_includes Erx::Hardware.device_header(Erx::Hardware.parse_svd(array.call(2, 4))), 'erx_pl011_fr_read(erx_mmio_t device, uint32_t index,'
    # No wider than its stride, no element past its neighbour or the block, and a name that says it is an array.
    [array.call(2, 2), array.call(4, 4), array.call(2, 4, name: 'FR'), array.call(0, 4), array.call(1, 4), array.call(1000, 4),
     array.call(2, 0x1000), @source.sub('<name>FR</name>', '<name>FR</name><dimIncrement>4</dimIncrement>')].each { |bytes| assert_raises(Erx::Error) { Erx::Hardware.parse_svd(bytes) } }
  end

  def test_the_device_table_says_what_a_register_allows
    table = Erx::Hardware.device_table_header([Erx::Hardware.parse_svd(@source)])
    assert_match(/\.name = "imsc", \.writable = UINT32_C\(0x7ff\), \.offset = 56,.*\.plain_update = true/, table)
    assert_match(/\.name = "dr", \.writable = UINT32_C\(0xff\),.*\.plain_update = false/, table)
    assert_match(/\.name = "icr", .*\.access = ERX_DEVICE_WRITE_ONLY,.*\.plain_update = false/, table)
    assert_match(/\.name = "rtic", \.mask = UINT32_C\(0x40\), \.shift = 6, .*\.clear = true/, table)
    assert table.ascii_only?
  end

  def test_a_peripheral_cannot_take_a_device_table_header_name
    File.binwrite(File.join(@root, 'hw/svd/pl011/pl011.svd'), @source.gsub('PL011', 'DEVICE_TABLE'))
    assert_raises(Erx::Error) { Erx::Hardware.output_plan(root: @root) }
  end

  def test_foreign_or_malformed_xml_encodings_are_typed_rejections
    ['{TF-8', 'ISO-8859-1', 'UTF-16'].each do |encoding|
      assert_raises(Erx::Error) { Erx::Hardware.parse_svd(@source.sub('UTF-8', encoding)) }
    end
  end

  def test_unpublishable_name_is_rejected_before_any_output
    source = @source.sub('<name>PL011</name><baseAddress>', "<name>#{'A' * 256}</name><baseAddress>")
    File.binwrite(File.join(@root, 'hw/svd/pl011/pl011.svd'), source)
    assert_raises(Erx::Error) { Erx::Hardware.output_plan(root: @root) }
    refute File.exist?(File.join(@root, 'include/erx/mmio.h'))
  end

  def test_combined_device_namespace_cannot_collide
    [['A_B', 'C'], ['A', 'B_C']].each_with_index do |(device, register), index|
      source = @source.sub('<name>PL011</name><baseAddress>', "<name>#{device}</name><baseAddress>")
                      .sub('<name>DR</name>', "<name>#{register}</name>")
      File.binwrite(File.join(@root, "hw/svd/device-#{index}.svd"), source)
    end
    assert_raises(Erx::Error) { Erx::Hardware.output_plan(root: @root) }
  end

  # CMDTM's fields as the SD Host Controller Specification lays them out (HC 2.2.6,
  # p.45-47), written here rather than read from the SVD, so a field the source moves
  # fails the check. check/0 answers ok, or each fact with what the header gave instead.
  CMDTM_CHECK = <<~ERLANG
    -module(cmdtm_check).
    -export([check/0]).
    -include("generated/erx_hw_sdhci.hrl").

    check() ->
        Facts = [{shift, 24, ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_SHIFT},
                 {width, 6, ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_WIDTH},
                 {mask, 16#3f000000, ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_MASK},
                 {put, 16#11000000, index(17)},
                 {get, 17, ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_GET(16#d1000000)},
                 {response, 16#20000, ?ERX_HW_SDHCI_CMDTM_CMD_RESP_PUT(?ERX_HW_SDHCI_CMDTM_CMD_RESP_BITS48)},
                 {busy, 3, ?ERX_HW_SDHCI_CMDTM_CMD_RESP_BITS48_BUSY},
                 {data, 16#200000, ?ERX_HW_SDHCI_CMDTM_CMD_DATA_MASK},
                 {too_large, 64, refused(64)}, {negative, -1, refused(-1)}, {atom, one, refused(one)},
                 {fits, [true, false, false], [fits(63), fits(64), fits(-1)]}],
        case [Fact || {_, Expected, Actual} = Fact <- Facts, Expected =/= Actual] of
            [] -> ok;
            Wrong -> {wrong, Wrong}
        end.

    index(Value) -> ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_PUT(Value).

    refused(Value) ->
        try index(Value) of
            _ -> accepted
        catch
            error:{badfield, {sdhci, cmdtm, cmd_index}, Refused} -> Refused
        end.

    fits(Value) when ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_FITS(Value) -> true;
    fits(_) -> false.
  ERLANG

  def test_erlang_fields_match_the_specification
    assert_equal 'ok', cmdtm_check(File.binread(File.join(@repository, 'hw/svd/sdhci/sdhci.svd')))
  end

  # The seeded fault: CMD_INDEX one bit higher in the source, which the generator accepts
  # (bits 30 and 31 are free) and the check must refuse.
  def test_erlang_field_check_catches_a_field_shifted_by_one
    source = File.binread(File.join(@repository, 'hw/svd/sdhci/sdhci.svd'))
    shifted = source.sub(%r{(<name>CMD_INDEX</name>.*?<bitOffset>)24(</bitOffset>)}, '\125\2')
    refute_equal source, shifted
    assert_includes cmdtm_check(shifted), '{shift,24,25}'
  end

  # An enumerated value named for one of a field's macros would define that macro twice.
  def test_erlang_names_cannot_collide
    collide = @source.sub(%r{(<name>DATA</name>.*?</bitWidth>)},
                          '\1<enumeratedValues><enumeratedValue><name>MASK</name><value>1</value>' \
                          '</enumeratedValue></enumeratedValues>')
    refute_equal @source, collide
    assert_raises(Erx::Error) { Erx::Hardware.parse_svd(collide) }
  end

  # A transport, as one cluster, and a kind that copies it and adds its own narrow registers:
  # the shape of hw/svd/virtio_mmio/virtio_mmio.svd, small enough to break one rule at a time.
  KINDS = <<~SVD
    <?xml version="1.0" encoding="UTF-8"?>
    <device schemaVersion="1.3">
      <name>T</name><version>1</version><description>t</description>
      <addressUnitBits>8</addressUnitBits><width>32</width>
      <peripherals>
        <peripheral>
          <name>BASE</name><baseAddress>0</baseAddress>
          <addressBlock><offset>0</offset><size>0x20</size><usage>registers</usage></addressBlock>
          <registers>
            <cluster><name>TRANSPORT</name><description>shared</description><addressOffset>0</addressOffset>
              <register><name>MAGIC</name><ownedByNif>false</ownedByNif><addressOffset>0</addressOffset><access>read-only</access>
                <fields><field><name>VALUE</name><bitOffset>0</bitOffset><bitWidth>32</bitWidth></field></fields></register>
              <register><name>STATUS</name><ownedByNif>true</ownedByNif><addressOffset>4</addressOffset><access>read-write</access>
                <fields><field><name>VALUE</name><bitOffset>0</bitOffset><bitWidth>32</bitWidth></field></fields></register>
            </cluster>
          </registers>
        </peripheral>
        <peripheral>
          <name>KIND</name><baseAddress>0</baseAddress>
          <addressBlock><offset>0</offset><size>0x20</size><usage>registers</usage></addressBlock>
          <registers>
            <cluster derivedFrom="BASE.TRANSPORT"><name>TRANSPORT</name><description>shared</description><addressOffset>0</addressOffset></cluster>
            <register><name>SELECT</name><ownedByNif>false</ownedByNif><size>8</size><addressOffset>0x10</addressOffset><access>read-write</access>
              <fields><field><name>VALUE</name><bitOffset>0</bitOffset><bitWidth>8</bitWidth></field></fields></register>
            <register><name>SIZE</name><ownedByNif>false</ownedByNif><size>8</size><addressOffset>0x11</addressOffset><access>read-only</access>
              <fields><field><name>VALUE</name><bitOffset>0</bitOffset><bitWidth>8</bitWidth></field></fields></register>
            <register><name>STEP</name><ownedByNif>false</ownedByNif><size>16</size><addressOffset>0x12</addressOffset><access>read-write</access>
              <fields><field><name>VALUE</name><bitOffset>0</bitOffset><bitWidth>16</bitWidth></field></fields></register>
            <register><name>LIMIT</name><ownedByNif>false</ownedByNif><addressOffset>0x14</addressOffset><access>read-only</access>
              <fields><field><name>VALUE</name><bitOffset>0</bitOffset><bitWidth>32</bitWidth></field></fields></register>
          </registers>
        </peripheral>
      </peripherals>
    </device>
  SVD

  def test_a_kind_copies_the_transport_cluster_and_adds_registers_of_their_own_width
    base, kind = Erx::Hardware.parse_peripherals(KINDS)
    assert_equal %w[MAGIC STATUS], base.registers.map(&:name)
    assert_nil base.derived_from
    assert_equal %w[MAGIC STATUS SELECT SIZE STEP LIMIT], kind.registers.map(&:name)
    assert_equal base.registers, kind.registers.first(2)
    assert_equal [32, 32, 8, 8, 16, 32], kind.registers.map(&:width)
    assert_equal 'BASE', kind.derived_from
    table = Erx::Hardware.device_table_header([base, kind])
    assert_match(/\.name = "select", \.writable = UINT8_C\(0xff\), \.offset = 16,.*\.width = 8,/, table)
    assert_match(/\.name = "kind", .*\.derived_from = "base"/, table)
    assert_match(/\.name = "base", .*\.derived_from = NULL/, table)
    access = Erx::Hardware.device_access_header
    %w[load8 store8 load16 store16 load32 load64].each { |name| assert_includes access, "erx_device_access_#{name}(" }
    assert_raises(Erx::Error) { Erx::Hardware.parse_svd(KINDS) }
  end

  # Each rule of the profile's derivation and widths, broken once.
  def test_a_derivation_or_a_narrow_register_outside_the_profile_is_refused
    derived = '<cluster derivedFrom="BASE.TRANSPORT"><name>TRANSPORT</name><description>shared</description>' \
              '<addressOffset>0</addressOffset></cluster>'
    select = '<size>8</size><addressOffset>0x10</addressOffset>'
    # The last match: KIND's element, where the first would be BASE's.
    last = ->(text, old, new) { text.sub(/\A(.*)#{Regexp.escape(old)}/m) { "#{Regexp.last_match(1)}#{new}" } }
    # KIND with nothing but its copy of the cluster, in a block too small for the copy.
    copy_only = last.call(KINDS.sub(%r{\s*<register><name>SELECT.*</register>}m, ''), '<size>0x20</size>', '<size>0x4</size>')
    extra = '<register><name>EXTRA</name><ownedByNif>true</ownedByNif><addressOffset>8</addressOffset>' \
            '<access>read-write</access><fields><field><name>VALUE</name><bitOffset>0</bitOffset>' \
            '<bitWidth>32</bitWidth></field></fields></register>'
    {
      KINDS.sub('derivedFrom="BASE.TRANSPORT"', 'derivedFrom="NONE.TRANSPORT"') => /no earlier peripheral/,
      KINDS.sub('derivedFrom="BASE.TRANSPORT"', 'derivedFrom="BASE.OTHER"') => /no leading cluster/,
      KINDS.sub('derivedFrom="BASE.TRANSPORT"', 'derivedFrom="TRANSPORT"') => /no earlier peripheral/,
      KINDS.sub('derivedFrom="BASE.TRANSPORT"', 'derivedFrom="KIND.TRANSPORT"') => /no earlier peripheral/,
      last.call(KINDS.sub("#{derived}\n", ''), '</registers>', "#{derived}</registers>") => /first element/,
      KINDS.sub('<addressOffset>0</addressOffset></cluster>', '<addressOffset>8</addressOffset></cluster>') => /no leading cluster/,
      KINDS.sub('</addressOffset></cluster>', '</addressOffset><register/></cluster>') => /unsupported SVD element/,
      KINDS.sub(%r{</cluster>(\s*</registers>)}) { "</cluster>#{extra}#{Regexp.last_match(1)}" } => /whole table/,
      copy_only => /outside its aligned block/,
      KINDS.sub(select, '<size>8</size><addressOffset>0x4</addressOffset>') => /overlap/,
      KINDS.sub('<size>16</size><addressOffset>0x12</addressOffset>', '<size>16</size><addressOffset>0x13</addressOffset>') => /aligned block/,
      KINDS.sub(select, '<size>24</size><addressOffset>0x10</addressOffset>') => /8, 16, 32 or 64/,
      KINDS.sub('<bitWidth>8</bitWidth>', '<bitWidth>9</bitWidth>') => /exceeds its width/
    }.each_with_index do |(bytes, reason), index|
      refute_equal KINDS, bytes, "case #{index} changed nothing"
      error = assert_raises(Erx::Error, "case #{index}") { Erx::Hardware.parse_peripherals(bytes) }
      assert_match reason, error.message, "case #{index}"
    end
  end

  def test_narrow_accessors_compile_and_touch_only_their_bytes
    FileUtils.mkdir_p(File.join(@root, 'hw/svd/kinds'))
    File.binwrite(File.join(@root, 'hw/svd/kinds/kinds.svd'), KINDS)
    Erx::Hardware.output_plan(root: @root).each do |relative, bytes|
      FileUtils.mkdir_p(File.dirname(File.join(@root, relative)))
      File.binwrite(File.join(@root, relative), bytes)
    end
    source = File.join(@root, 'narrow.c')
    File.binwrite(source, <<~C)
      #include "erx/hw/kind.h"
      #include "erx/hw/device_access.h"
      #include <assert.h>
      int main(void)
      {
      \t_Alignas(8) uint8_t registers[0x20] = {0};
      \terx_mmio_t device = {registers, sizeof(registers)};
      \tuint8_t size = 0;
      \tuint16_t step = 0;
      \tregisters[0x11] = 0x14;
      \tassert(erx_kind_select_write(device, UINT8_C(0x12)));
      \tassert(registers[0x10] == 0x12 && registers[0x11] == 0x14 && registers[0x0f] == 0);
      \tassert(erx_kind_size_read(device, &size) && size == 0x14);
      \tassert(erx_kind_step_write(device, UINT16_C(0xbeef)));
      \tassert(erx_kind_step_read(device, &step) && step == 0xbeef && registers[0x11] == 0x14);
      \terx_device_access_store8(registers, 0x13, 0x7f);
      \tassert(erx_device_access_load8(registers, 0x13) == 0x7f && erx_device_access_load8(registers, 0x12) == 0xef);
      \terx_device_access_store16(registers, 0x12, 0x1234);
      \tassert(erx_device_access_load16(registers, 0x12) == 0x1234 && registers[0x11] == 0x14);
      \tdevice.length = 0x11;
      \tassert(!erx_kind_size_read(device, &size));
      \treturn (0);
      }
    C
    runner = Erx::Runner.new(owner_root: @root, log_dir: File.join(@root, 'logs'))
    program = File.join(@root, 'narrow')
    runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                '-fsanitize=address,undefined', '-I', File.join(@root, 'include'), source,
                '-o', program], name: 'compile-narrow', deadline: 60)
    assert_equal 'succeeded', runner.run([program], name: 'narrow-accessors', deadline: 30).fetch('state')
  end

  def test_generated_accessors_compile_and_preserve_neighbor_bits
    Erx::Hardware.output_plan(root: @root).each do |relative, bytes|
      FileUtils.mkdir_p(File.dirname(File.join(@root, relative)))
      File.binwrite(File.join(@root, relative), bytes)
    end
    source = File.join(@root, 'accessors.c')
    File.binwrite(source, <<~C)
      #include "erx/hw/pl011.h"
      #include <assert.h>
      int main(void)
      {
      \t_Alignas(8) uint32_t registers[1024] = {0};
      \terx_mmio_t device = {(volatile uint8_t *)registers, sizeof(registers)};
      \tuint32_t value = 0;
      \tassert(erx_pl011_dr_data_set(UINT32_C(0xab00), UINT32_C(0x55), &value));
      \tassert(value == UINT32_C(0xab55));
      \tassert(!erx_pl011_dr_data_set(0, UINT32_C(0x100), &value));
      \tassert(erx_pl011_dr_write(device, UINT32_C(0x42)));
      \tassert(registers[0] == UINT32_C(0x42));
      \tassert(!erx_pl011_dr_write(device, UINT32_C(0x100)));
      \tregisters[6] = UINT32_C(0x90);
      \tassert(erx_pl011_fr_read(device, &value));
      \tassert(erx_pl011_fr_rxfe_get(value) == 1);
      \tassert(erx_pl011_fr_txfe_get(value) == 1);
      \tassert(erx_pl011_icr_rtic_clear(device, UINT32_C(1)));
      \tassert(registers[17] == UINT32_C(0x40));
      \tdevice.length = 4;
      \tassert(!erx_pl011_fr_read(device, &value));
      \tdevice.base += 1;
      \tassert(!erx_pl011_dr_read(device, &value));
      \treturn (0);
      }
    C
    runner = Erx::Runner.new(owner_root: @root, log_dir: File.join(@root, 'logs'))
    program = File.join(@root, 'accessors')
    runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                '-fsanitize=address,undefined', '-I', File.join(@root, 'include'), source,
                '-o', program], name: 'compile-hardware', deadline: 60)
    result = runner.run([program], name: 'hardware-accessors', deadline: 30)
    assert_equal 'succeeded', result.fetch('state')
  end

  # The header's controllers as BCM2711 ARM Peripherals (release 4) lays them out, written
  # here from its tables rather than read from the SVDs: each register's offset (Tables 24,
  # 159 and 63; the clock manager's PWM offsets are FreeBSD's bcm2835_clkman.h and .c, in
  # Tables 99 and 100's format) and the fields a driver steers by, as [register, field, bit
  # offset, width].
  HEADER_REGISTERS = {
    'BSC' => { 'C' => 0x00, 'S' => 0x04, 'DLEN' => 0x08, 'A' => 0x0c, 'FIFO' => 0x10, 'DIV' => 0x14,
               'DEL' => 0x18, 'CLKT' => 0x1c },
    'BCM2711_SPI' => { 'CS' => 0x00, 'FIFO' => 0x04, 'CLK' => 0x08, 'DLEN' => 0x0c, 'LTOH' => 0x10, 'DC' => 0x14 },
    'BCM2711_GPIO' => { 'GPFSEL0' => 0x00, 'GPFSEL5' => 0x14, 'GPSET0' => 0x1c, 'GPCLR0' => 0x28, 'GPLEV0' => 0x34,
                        'GPEDS0' => 0x40, 'GPREN0' => 0x4c, 'GPFEN0' => 0x58, 'GPHEN0' => 0x64, 'GPLEN0' => 0x70,
                        'GPAREN0' => 0x7c, 'GPAFEN1' => 0x8c, 'PUP_PDN0' => 0xe4, 'PUP_PDN3' => 0xf0 },
    'CPRMAN' => { 'PWMCTL' => 0xa0, 'PWMDIV' => 0xa4 }
  }.freeze
  HEADER_FIELDS = {
    'BSC' => [%w[C I2CEN 15 1], %w[C ST 7 1], %w[C CLEAR 4 2], %w[C READ 0 1], %w[S CLKT 9 1], %w[S ERR 8 1],
              %w[S DONE 1 1], %w[S TA 0 1], %w[A ADDR 0 7], %w[DEL FEDL 16 16]],
    'BCM2711_SPI' => [%w[CS RXF 20 1], %w[CS DONE 16 1], %w[CS TA 7 1], %w[CS CLEAR 4 2], %w[CS CPOL 3 1],
                      %w[CS CPHA 2 1], %w[CS CS 0 2], %w[CLK CDIV 0 16]],
    'BCM2711_GPIO' => [%w[GPFSEL0 FSEL9 27 3], %w[GPFSEL2 FSEL27 21 3], %w[GPFSEL5 FSEL57 21 3], %w[GPSET1 SET 0 26],
                       %w[PUP_PDN0 PULL15 30 2], %w[PUP_PDN1 PULL16 0 2], %w[PUP_PDN3 PULL57 18 2]],
    'CPRMAN' => [%w[PWMCTL SRC 0 4], %w[PWMCTL ENAB 4 1], %w[PWMCTL KILL 5 1], %w[PWMCTL BUSY 7 1], %w[PWMCTL FLIP 8 1],
                 %w[PWMCTL MASH 9 2], %w[PWMCTL PASSWD 24 8], %w[PWMDIV DIVF 0 12], %w[PWMDIV DIVI 12 12],
                 %w[PWMDIV PASSWD 24 8]]
  }.freeze
  HEADER_SVDS = { 'BSC' => 'hw/svd/bsc/bsc.svd', 'BCM2711_SPI' => 'hw/svd/bcm2711_spi/bcm2711_spi.svd',
                  'BCM2711_GPIO' => 'hw/svd/bcm2711_gpio/bcm2711_gpio.svd',
                  'CPRMAN' => 'hw/svd/cprman/cprman.svd' }.freeze

  def header_device(name) = Erx::Hardware.parse_svd(File.binread(File.join(@repository, HEADER_SVDS.fetch(name))))

  def test_header_controllers_match_the_datasheet
    HEADER_REGISTERS.each do |name, offsets|
      registers = header_device(name).registers.to_h { |register| [register.name, register] }
      offsets.each { |register, offset| assert_equal offset, registers.fetch(register).offset, "#{name}.#{register}" }
      HEADER_FIELDS.fetch(name).each do |register, field, shift, width|
        found = registers.fetch(register).fields.find { |candidate| candidate.name == field }
        assert_equal [Integer(shift), Integer(width)], [found&.offset, found&.width], "#{name}.#{register}.#{field}"
      end
    end
  end

  # Every pin's function select and pull follow one rule (Tables 64 to 69 and 90 to 93):
  # GPIO n's FSEL is three bits at 3 * (n mod 10) of GPFSEL(n div 10), its pull two bits
  # at 2 * (n mod 16) of PUP_PDN(n div 16), each with the encodings the tables give.
  def test_every_gpio_pin_has_its_function_select_and_pull
    registers = header_device('BCM2711_GPIO').registers.to_h { |register| [register.name, register] }
    alternates = { 'input' => 0, 'output' => 1, 'alt0' => 4, 'alt1' => 5, 'alt2' => 6, 'alt3' => 7, 'alt4' => 3, 'alt5' => 2 }
    58.times do |pin|
      fsel = registers.fetch("GPFSEL#{pin / 10}").fields.find { |field| field.name == "FSEL#{pin}" }
      assert_equal [3 * (pin % 10), 3, alternates], [fsel.offset, fsel.width, fsel.values], "FSEL#{pin}"
      pull = registers.fetch("PUP_PDN#{pin / 16}").fields.find { |field| field.name == "PULL#{pin}" }
      assert_equal [2 * (pin % 16), 2, { 'none' => 0, 'up' => 1, 'down' => 2 }], [pull.offset, pull.width, pull.values], "PULL#{pin}"
    end
  end

  def test_header_controllers_side_effects_are_marked
    bsc = header_device('BSC').registers.to_h { |register| [register.name, register] }
    assert_equal %w[DONE ERR CLKT], bsc.fetch('S').fields.select(&:clear).map(&:name)
    assert_equal 'modify', bsc.fetch('FIFO').read_action
    refute Erx::Hardware.plain_update?(bsc.fetch('S'))
    spi = header_device('BCM2711_SPI').registers.to_h { |register| [register.name, register] }
    assert_equal 'modify', spi.fetch('FIFO').read_action
    assert Erx::Hardware.plain_update?(spi.fetch('CS'))
    gpio = header_device('BCM2711_GPIO').registers.to_h { |register| [register.name, register] }
    assert_equal %w[write-only write-only read-only], %w[GPSET0 GPCLR1 GPLEV0].map { |name| gpio.fetch(name).access }
    assert gpio.fetch('GPEDS0').fields.all?(&:clear)
  end

  # The seeded fault: FSEL9 three bits wider, past bit 31, which the generator must refuse
  # before it writes an accessor.
  def test_a_header_field_wider_than_its_register_is_refused
    source = File.binread(File.join(@repository, HEADER_SVDS.fetch('BCM2711_GPIO')))
    widened = source.sub(%r{(<name>FSEL9</name>.*?<bitWidth>)3(</bitWidth>)}) { "#{$1}6#{$2}" }
    refute_equal source, widened
    error = assert_raises(Erx::Error) { Erx::Hardware.parse_svd(widened) }
    assert_equal 'SVD field exceeds register width', error.message
  end

  # Selecting GPIO 2's alternate 0 (SDA1) through the generated accessors changes FSEL2's
  # bits alone, and BSC's and SPI's headers compile beside it.
  def test_header_accessors_compile_and_select_a_function
    HEADER_SVDS.each_value do |relative|
      FileUtils.mkdir_p(File.dirname(File.join(@root, relative)))
      File.binwrite(File.join(@root, relative), File.binread(File.join(@repository, relative)))
    end
    Erx::Hardware.output_plan(root: @root).each do |relative, bytes|
      FileUtils.mkdir_p(File.dirname(File.join(@root, relative)))
      File.binwrite(File.join(@root, relative), bytes)
    end
    source = File.join(@root, 'header.c')
    File.binwrite(source, <<~C)
      #include "erx/hw/bcm2711_gpio.h"
      #include "erx/hw/bcm2711_spi.h"
      #include "erx/hw/bsc.h"
      #include <assert.h>
      int main(void)
      {
      \t_Alignas(8) uint32_t registers[64] = {0};
      \terx_mmio_t device = {(volatile uint8_t *)registers, 0xf4};
      \tuint32_t word = 0;
      \tregisters[0] = UINT32_C(0x3ffffe3f);
      \tassert(erx_bcm2711_gpio_gpfsel0_read(device, &word));
      \tassert(erx_bcm2711_gpio_gpfsel0_fsel2_set(word, ERX_BCM2711_GPIO_GPFSEL0_FSEL2_ALT0, &word));
      \tassert(erx_bcm2711_gpio_gpfsel0_write(device, word));
      \tassert(registers[0] == UINT32_C(0x3fffff3f));
      \tassert(!erx_bcm2711_gpio_gpset1_write(device, UINT32_C(1) << 26));
      \tassert(erx_bcm2711_gpio_gpeds0_eds_clear(device, UINT32_C(1) << 15));
      \tassert(registers[16] == UINT32_C(1) << 15);
      \tassert(erx_bsc_s_done_clear(device, 1));
      \tassert(erx_bcm2711_spi_cs_cs_set(0, ERX_BCM2711_SPI_CS_CS_CE1, &word) && word == 1);
      \treturn (0);
      }
    C
    runner = Erx::Runner.new(owner_root: @root, log_dir: File.join(@root, 'logs'))
    program = File.join(@root, 'header')
    runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                '-fsanitize=address,undefined', '-I', File.join(@root, 'include'), source,
                '-o', program], name: 'compile-header', deadline: 60)
    assert_equal 'succeeded', runner.run([program], name: 'header-accessors', deadline: 30).fetch('state')
  end

  private

  # What CMDTM_CHECK returns against the Erlang header generated from svd, compiled with
  # warnings as errors on stock's emulator (ERX_ERLC and ERX_ERL, which make check
  # supplies): 'ok', or the error it failed with.
  def cmdtm_check(svd)
    FileUtils.mkdir_p(File.join(@root, 'hw/svd/sdhci'))
    File.binwrite(File.join(@root, 'hw/svd/sdhci/sdhci.svd'), svd)
    include_dir = File.join(@root, 'erlang/apps/erx/include')
    Erx::Hardware.output_plan(root: @root).each do |relative, bytes|
      FileUtils.mkdir_p(File.dirname(File.join(@root, relative)))
      File.binwrite(File.join(@root, relative), bytes)
    end
    File.binwrite(File.join(@root, 'cmdtm_check.erl'), CMDTM_CHECK)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', include_dir, '-o', @root,
                                     File.join(@root, 'cmdtm_check.erl'), stdin_data: '')
    assert status.success?, output
    output, status = Open3.capture2e(ENV.fetch('ERX_ERL'), '-noshell', '-pa', @root, '-eval',
                                     'io:format("~p", [cmdtm_check:check()]), halt().',
                                     chdir: @root, stdin_data: '')
    assert status.success?, output
    output
  end
end
