# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Independent byte oracle: offsets and encodings come from the published
# format, not the generator's model or encoder. The fixture is structurally
# complete; these bytes make no claim that its resource policy is admitted.
module AbiManifestFixture
  module_function

  def integer(bytes, offset, value, width: 4)
    format = { 2 => 'v', 4 => 'V', 8 => 'Q<' }.fetch(width)
    bytes[offset, width] = [value].pack(format)
  end

  def span(bytes, offset, first, count)
    bytes[offset, 8] = [first, count].pack('V2')
  end

  def share(bytes, offset, quota:, capacity:, base:, ceiling:)
    bytes[offset, 48] = [quota, 10_000_000, 1, capacity, 0,
                        1000, 5, base, ceiling, 0, 0].pack('Q<3V4CCvV')
  end

  def valid
    text = 'node/uart@0fixturerootnativenative'.b
    bytes = "\0".b * (736 + text.bytesize)
    integer(bytes, 0, 0x4d585245)
    integer(bytes, 4, 1, width: 2)
    integer(bytes, 6, 3, width: 2)
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 12, 440)
    span(bytes, 16, 0, 4)
    span(bytes, 24, 4, 7)
    span(bytes, 32, 11, 0)
    span(bytes, 40, 11, 7)
    integer(bytes, 48, 1_073_741_824, width: 8)
    integer(bytes, 56, 67_108_864, width: 8)
    share(bytes, 72, quota: 2_000_000, capacity: 200, base: 24, ceiling: 47)
    share(bytes, 120, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 172, 4)
    integer(bytes, 176, 4)
    integer(bytes, 180, 4096)
    integer(bytes, 184, 16384)
    integer(bytes, 188, 4096)
    integer(bytes, 192, 250)
    span(bytes, 208, 440, 1)
    span(bytes, 216, 520, 0)
    span(bytes, 224, 520, 1)
    span(bytes, 232, 680, 1)
    (240..352).step(8) { |offset| span(bytes, offset, 736, 0) }
    span(bytes, 360, 736, text.bytesize)
    span(bytes, 376, 520, 0)
    span(bytes, 384, 736, 0)
    span(bytes, 392, 736, 0)
    (400..432).step(8) { |offset| span(bytes, offset, 736, 0) }
    span(bytes, 440, 18, 4)
    integer(bytes, 448, 268_435_456, width: 8)
    share(bytes, 456, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 504, 4)
    integer(bytes, 508, 4)
    span(bytes, 520, 22, 6)
    integer(bytes, 528, 16_777_216, width: 8)
    integer(bytes, 536, 1_048_576, width: 8)
    share(bytes, 544, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 640, 4096)
    integer(bytes, 664, 4096, width: 8)
    integer(bytes, 672, 4096, width: 8)
    span(bytes, 680, 28, 6)
    integer(bytes, 688, 4096)
    integer(bytes, 692, 8192)
    integer(bytes, 696, 64)
    integer(bytes, 700, 64)
    integer(bytes, 720, 1024)
    integer(bytes, 724, 64)
    bytes[736, text.bytesize] = text
    bytes
  end

  # Byte offsets of erx_mf_session's fields in abi/manifest.txt.
  SESSION_FIELDS = { principal: 0, limits: 4, runtime: 8, release: 12, release_files: 16, reserved: 20 }.freeze

  # erx_mf_device's size in abi/manifest.txt.
  DEVICE_ROW = 88

  def unit_partition(overlap: false, orphan: false)
    original = valid
    units = orphan ? 1 : 2
    device_offset = 736 + units * 24
    strings_offset = device_offset + 2 * DEVICE_ROW
    text = original.byteslice(736..-1) + (orphan ? 'unit0' : 'unit0unit1')
    bytes = original.byteslice(0, 736) + "\0".b * (strings_offset - 736) + text
    integer(bytes, 8, bytes.bytesize)
    span(bytes, 248, 736, units)
    span(bytes, 256, device_offset, 2)
    [*(264..352).step(8), *(384..432).step(8)].each { |offset| span(bytes, offset, strings_offset, 0) }
    span(bytes, 360, strings_offset, text.bytesize)
    units.times do |index|
      base = 736 + index * 24
      span(bytes, base, 34 + index * 5, 5)
      integer(bytes, base + 8, 0xffffffff)
      first = overlap ? device_offset : device_offset + index * DEVICE_ROW
      span(bytes, base + 12, first, 1)
    end
    2.times do |index|
      base = device_offset + index * DEVICE_ROW
      integer(bytes, base, 1)
      integer(bytes, base + 4, 2)
      span(bytes, base + 8, 4, 7)
      span(bytes, base + 16, 0, 0)
      span(bytes, base + 24, 11, 7)
      span(bytes, base + 56, 0, 4)
    end
    bytes
  end

  def facet_parameter(kind: 3, scalar: 1, index: 0, text: '')
    original = valid
    domain = "\0".b * 64
    span(domain, 0, 18, 4)
    integer(domain, 12, 2)
    integer(domain, 44, 10) # boot_timeout_s, which the reader takes from 1
    service = "\0".b * 24
    span(service, 0, 18, 4)
    integer(service, 8, 0xffffffff)
    facet = "\0".b * 80
    span(facet, 0, 18, 4)
    # Header440, principal80, domain64, limits160, runtime-limits56,
    # service24, facet80, parameter32, then strings.
    span(facet, 16, 904, 0)
    span(facet, 24, 904, 1)
    parameter = "\0".b * 32
    integer(parameter, 4, kind)
    integer(parameter, 8, scalar, width: 8)
    span(parameter, 16, 34, text.bytesize) unless text.empty?
    integer(parameter, 24, index)
    strings = original.byteslice(736..-1) + text
    bytes = original.byteslice(0, 520) + domain + original.byteslice(520, 216) + service + facet + parameter + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, 1, width: 2)
    span(bytes, 216, 520, 1)
    span(bytes, 224, 584, 1)
    span(bytes, 232, 744, 1)
    (240..264).step(8) { |offset| span(bytes, offset, 800, 0) }
    span(bytes, 272, 800, 1)
    span(bytes, 280, 824, 1)
    span(bytes, 288, 904, 0)
    span(bytes, 296, 904, 1)
    (304..352).step(8) { |offset| span(bytes, offset, 936, 0) }
    span(bytes, 360, 936, strings.bytesize)
    span(bytes, 376, 584, 0)
    span(bytes, 384, 936, 0)
    span(bytes, 392, 936, 0)
    (400..432).step(8) { |offset| span(bytes, offset, 936, 0) }
    bytes
  end

  # The valid fixture plus one session record; every field index is 0 and
  # args and env are empty. Header440, principal80, sessions40, limits160,
  # runtime-limits56, then strings.
  def session_template(**fields)
    original = valid
    session = "\0".b * 40
    fields.each { |name, value| integer(session, SESSION_FIELDS.fetch(name), value) }
    strings = original.byteslice(736..-1)
    bytes = original.byteslice(0, 520) + session + original.byteslice(520, 216) + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, 1, width: 2)
    span(bytes, 224, 560, 1)
    span(bytes, 232, 720, 1)
    (240..352).step(8) { |offset| span(bytes, offset, 776, 0) }
    span(bytes, 360, 776, strings.bytesize)
    span(bytes, 376, 520, 1)
    span(bytes, 384, 776, 0)
    span(bytes, 392, 776, 0)
    (400..432).step(8) { |offset| span(bytes, offset, 776, 0) }
    bytes
  end

  # session_template's manifest naming principal (0xffffffff, none, by default), with
  # an apps row of 1 MiB and max 2 and no services when apps is true: Header440,
  # principal80, sessions40, limits160, runtime-limits56, apps24 at 776 when present,
  # then strings.
  def app_template(principal: 0xffffffff, apps: true)
    original = session_template(principal: principal)
    row = "\0".b * (apps ? 24 : 0)
    strings = original.byteslice(776..-1)
    bytes = original.byteslice(0, 776) + row + strings
    strings_offset = 776 + row.bytesize
    integer(bytes, 8, bytes.bytesize)
    span(bytes, 360, strings_offset, strings.bytesize)
    span(bytes, 384, strings_offset, 0)
    span(bytes, 392, strings_offset, 0)
    (400..432).step(8) { |offset| span(bytes, offset, strings_offset, 0) }
    return bytes unless apps

    span(bytes, 384, 776, 0)
    span(bytes, 392, 776, 0)
    span(bytes, 400, 776, 1)
    integer(bytes, 776, 1_048_576, width: 8)
    integer(bytes, 784, 2)
    span(bytes, 792, 800, 0)
    bytes
  end

  # Byte offsets of erx_mf_start's fields in abi/manifest.txt, and its size.
  START_FIELDS = { principal: 0, flags: 4, display: 8, restarts: 12, restart_period_s: 16, reserved: 20 }.freeze
  START_ROW = 24

  # The valid fixture as a development manifest plus count start rows, each
  # enabled, of principal 0, with no display and 5 restarts in 600 s, and fields
  # overriding the first row. Header440, principal80, limits160,
  # runtime-limits56, the start rows, then strings.
  def start_rows(count: 1, partial: false, **fields)
    original = valid
    rows = Array.new(count) do |index|
      row = "\0".b * START_ROW
      { flags: 1, display: 0xffffffff, restarts: 5, restart_period_s: 600 }
        .merge(index.zero? ? fields : {})
        .each { |name, value| integer(row, START_FIELDS.fetch(name), value) }
      row
    end.join
    strings_offset = 736 + rows.bytesize
    strings = original.byteslice(736..-1)
    bytes = original.byteslice(0, 736) + rows + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, partial ? 3 : 1, width: 2)
    span(bytes, 360, strings_offset, strings.bytesize)
    span(bytes, 384, 736, count)
    span(bytes, 392, strings_offset, 0)
    (400..432).step(8) { |offset| span(bytes, offset, strings_offset, 0) }
    bytes
  end

  # The valid fixture as a manifest of flags (development by default) with an apps row
  # of 1 MiB and max 2 and no services, the enabled package clock, the signer ops and
  # the development key: Header440, principal80, limits160, runtime-limits56, apps24 at
  # 736, no app services, package44 at 760, signer40 at 804, development key32 at 844,
  # then strings at 876, with clock at 34 and ops at 39. apps names the count its span
  # claims, which the reader bounds to 1.
  def packages(flags: 1, apps: 1)
    original = valid
    strings = original.byteslice(736..-1) + 'clockops'.b
    bytes = original.byteslice(0, 736) + "\0".b * 140 + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, flags, width: 2)
    span(bytes, 360, 876, strings.bytesize)
    span(bytes, 400, 736, apps)
    span(bytes, 408, 760, 0)
    span(bytes, 416, 760, 1)
    span(bytes, 424, 804, 1)
    span(bytes, 432, 844, 1)
    integer(bytes, 736, 1_048_576, width: 8)
    integer(bytes, 744, 2)
    span(bytes, 752, 760, 0)
    span(bytes, 760, 34, 5)
    integer(bytes, 768, 1)
    bytes[772, 32] = "\xab".b * 32
    span(bytes, 804, 39, 3)
    bytes[812, 32] = "\xcd".b * 32
    bytes[844, 32] = "\x07".b * 32
    bytes
  end
end
