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
    bytes = "\0".b * (752 + text.bytesize)
    integer(bytes, 0, 0x4d585245)
    integer(bytes, 4, 1, width: 2)
    integer(bytes, 6, 3, width: 2)
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 12, 456)
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
    span(bytes, 208, 456, 1)
    span(bytes, 216, 536, 0)
    span(bytes, 224, 536, 1)
    span(bytes, 232, 696, 1)
    (240..352).step(8) { |offset| span(bytes, offset, 752, 0) }
    span(bytes, 360, 752, text.bytesize)
    span(bytes, 376, 536, 0)
    span(bytes, 384, 752, 0)
    span(bytes, 392, 752, 0)
    (400..440).step(8) { |offset| span(bytes, offset, 752, 0) }
    integer(bytes, 448, 60) # the machine's boot_timeout_s, which the reader takes from 1
    span(bytes, 456, 18, 4)
    integer(bytes, 464, 268_435_456, width: 8)
    share(bytes, 472, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 520, 4)
    integer(bytes, 524, 4)
    span(bytes, 536, 22, 6)
    integer(bytes, 544, 16_777_216, width: 8)
    integer(bytes, 552, 1_048_576, width: 8)
    share(bytes, 560, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 656, 4096)
    integer(bytes, 680, 4096, width: 8)
    integer(bytes, 688, 4096, width: 8)
    span(bytes, 696, 28, 6)
    integer(bytes, 704, 4096)
    integer(bytes, 708, 8192)
    integer(bytes, 712, 64)
    integer(bytes, 716, 64)
    integer(bytes, 736, 1024)
    integer(bytes, 740, 64)
    bytes[752, text.bytesize] = text
    bytes
  end

  # Byte offsets of erx_mf_session's fields in abi/manifest.txt.
  SESSION_FIELDS = { principal: 0, limits: 4, runtime: 8, release: 12, release_files: 16, reserved: 20 }.freeze

  # erx_mf_device's size in abi/manifest.txt.
  DEVICE_ROW = 88

  def unit_partition(overlap: false, orphan: false)
    original = valid
    units = orphan ? 1 : 2
    device_offset = 752 + units * 24
    strings_offset = device_offset + 2 * DEVICE_ROW
    text = original.byteslice(752..-1) + (orphan ? 'unit0' : 'unit0unit1')
    bytes = original.byteslice(0, 752) + "\0".b * (strings_offset - 752) + text
    integer(bytes, 8, bytes.bytesize)
    span(bytes, 248, 752, units)
    span(bytes, 256, device_offset, 2)
    [*(264..352).step(8), *(384..440).step(8)].each { |offset| span(bytes, offset, strings_offset, 0) }
    span(bytes, 360, strings_offset, text.bytesize)
    units.times do |index|
      base = 752 + index * 24
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
    service = "\0".b * 24
    span(service, 0, 18, 4)
    integer(service, 8, 0xffffffff)
    facet = "\0".b * 80
    span(facet, 0, 18, 4)
    # Header456, principal80, domain64, limits160, runtime-limits56,
    # service24, facet80, parameter32, then strings.
    span(facet, 16, 920, 0)
    span(facet, 24, 920, 1)
    parameter = "\0".b * 32
    integer(parameter, 4, kind)
    integer(parameter, 8, scalar, width: 8)
    span(parameter, 16, 34, text.bytesize) unless text.empty?
    integer(parameter, 24, index)
    strings = original.byteslice(752..-1) + text
    bytes = original.byteslice(0, 536) + domain + original.byteslice(536, 216) + service + facet + parameter + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, 1, width: 2)
    span(bytes, 216, 536, 1)
    span(bytes, 224, 600, 1)
    span(bytes, 232, 760, 1)
    (240..264).step(8) { |offset| span(bytes, offset, 816, 0) }
    span(bytes, 272, 816, 1)
    span(bytes, 280, 840, 1)
    span(bytes, 288, 920, 0)
    span(bytes, 296, 920, 1)
    (304..352).step(8) { |offset| span(bytes, offset, 952, 0) }
    span(bytes, 360, 952, strings.bytesize)
    span(bytes, 376, 600, 0)
    span(bytes, 384, 952, 0)
    span(bytes, 392, 952, 0)
    (400..440).step(8) { |offset| span(bytes, offset, 952, 0) }
    bytes
  end

  # The valid fixture plus one session record; every field index is 0 and
  # args and env are empty. Header456, principal80, sessions40, limits160,
  # runtime-limits56, then strings.
  def session_template(**fields)
    original = valid
    session = "\0".b * 40
    fields.each { |name, value| integer(session, SESSION_FIELDS.fetch(name), value) }
    strings = original.byteslice(752..-1)
    bytes = original.byteslice(0, 536) + session + original.byteslice(536, 216) + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, 1, width: 2)
    span(bytes, 224, 576, 1)
    span(bytes, 232, 736, 1)
    (240..352).step(8) { |offset| span(bytes, offset, 792, 0) }
    span(bytes, 360, 792, strings.bytesize)
    span(bytes, 376, 536, 1)
    span(bytes, 384, 792, 0)
    span(bytes, 392, 792, 0)
    (400..440).step(8) { |offset| span(bytes, offset, 792, 0) }
    bytes
  end

  # Byte offsets of erx_mf_start's fields in abi/manifest.txt, and its size.
  START_FIELDS = { principal: 0, flags: 4, display: 8, restarts: 12, restart_period_s: 16, reserved: 20 }.freeze
  START_ROW = 24

  # The valid fixture as a development manifest plus count start rows, each
  # enabled, of principal 0, with no display and 5 restarts in 600 s, and fields
  # overriding the first row. Header456, principal80, limits160,
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
    strings_offset = 752 + rows.bytesize
    strings = original.byteslice(752..-1)
    bytes = original.byteslice(0, 752) + rows + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, partial ? 3 : 1, width: 2)
    span(bytes, 360, strings_offset, strings.bytesize)
    span(bytes, 384, 752, count)
    span(bytes, 392, strings_offset, 0)
    (400..440).step(8) { |offset| span(bytes, offset, strings_offset, 0) }
    bytes
  end

  # abi/manifest.txt's tables in its `order`: each table's span in the header and its
  # alignment. The strings table, whose span is at STRINGS_SPAN, comes last.
  TABLES = {
    principals: [208, 8], domains: [216, 8], sessions: [376, 8], limits: [224, 8],
    runtime_limits: [232, 8], lane_classes: [240, 8], units: [248, 8], devices: [256, 8],
    windows: [264, 8], services: [272, 8], facets: [280, 8], facet_operations: [288, 4],
    facet_parameters: [296, 8], introductions: [304, 8], images: [312, 8], extents: [320, 8],
    boot_order: [328, 4], liveness: [336, 4], shell_principals: [344, 4], partial_boot: [352, 8],
    starts: [384, 4], displays: [392, 4], apps: [400, 8], app_services: [408, 4],
    packages: [416, 4], signers: [424, 4], development_key: [432, 1], system_image: [440, 8]
  }.freeze
  STRINGS_SPAN = 360

  # The valid fixture's header with flags, each table's rows (byte strings of its record
  # size) at its place in TABLES's order, padded to its alignment, and text as the strings
  # table. counts overrides the count a table's span claims. The block, given the bytes
  # and each table's offset, writes the fields that name another table's place.
  def layout(flags:, rows:, text:, counts: {})
    bytes = valid.byteslice(0, 456)
    integer(bytes, 6, flags, width: 2)
    offsets = TABLES.to_h do |table, (field, alignment)|
      bytes << ("\0".b * (-bytes.bytesize % alignment))
      offset = bytes.bytesize
      records = rows.fetch(table, [])
      span(bytes, field, offset, counts.fetch(table, records.size))
      records.each { |record| bytes << record }
      [table, offset]
    end
    span(bytes, STRINGS_SPAN, bytes.bytesize, text.bytesize)
    bytes << text
    integer(bytes, 8, bytes.bytesize)
    yield bytes, offsets
    bytes
  end

  # The names the packages fixture adds to the valid fixture's strings.
  PACKAGE_NAMES = %w[clock quotes ops storage packages display data spare system kiosk_display pkg_admin].freeze

  # The valid fixture as a manifest of flags (development by default) holding everything
  # erx_pkg_manifest reads. Its principal root; the domain storage; the session templates
  # 0, the app template, whose principal is absent, and 1, root's;
  # the services packages, data, spare and system of storage's files interface and display
  # of the system domain's windows interface; the facet rows 0 kiosk_display, display
  # granted to template 1, 1 pkg_admin, packages granted to the system domain, and the app
  # template's 2 packages, 3 display, 4 data and 5 system; an apps row of 1 MiB and max 2
  # naming template 0, its packages row 2 and its system row 5, and offering display and data, each with the template's row,
  # whose span claims apps rows, which the reader bounds to 1; the enabled package clock and the package quotes; the
  # signer ops; and the development key of 7s when development is true.
  def packages(flags: 1, apps: 1, development: true)
    text = valid.byteslice(752..-1)
    names = {}
    PACKAGE_NAMES.each do |label|
      names[label] = [text.bytesize, label.bytesize]
      text += label
    end
    name = ->(label) { names.fetch(label).pack('V2') }
    facet = lambda do |label, kind:, grantee:, service:|
      (name.(label) + [grantee, service].pack('V2') + "\0".b * 56 + [kind, 0].pack('V2')).b
    end
    rows = {
      principals: [valid.byteslice(456, 80)],
      domains: [name.('storage') + [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0].pack('V14')],
      sessions: [[0xffffffff, *[0] * 9], [0] * 10].map { |fields| fields.pack('V10') },
      limits: [valid.byteslice(536, 160)],
      runtime_limits: [valid.byteslice(696, 56)],
      services: [['packages', 0, 5], ['display', 0xffffffff, 8], ['data', 0, 5], ['spare', 0, 5], ['system', 0, 5]]
        .map { |label, server, interface| name.(label) + [server, interface, 0].pack('V2Q<') },
      facets: [facet.('kiosk_display', kind: 2, grantee: 1, service: 1),
               facet.('pkg_admin', kind: 0, grantee: 0, service: 0),
               facet.('packages', kind: 2, grantee: 0, service: 0),
               facet.('display', kind: 2, grantee: 0, service: 1),
               facet.('data', kind: 2, grantee: 0, service: 2),
               facet.('system', kind: 2, grantee: 0, service: 4)],
      apps: ["\0".b * 32],
      app_services: [[1, 3].pack('V2'), [2, 4].pack('V2')],
      packages: [name.('clock') + [1].pack('V') + "\xab".b * 32, name.('quotes') + [0].pack('V') + "\xee".b * 32],
      signers: [name.('ops') + "\xcd".b * 32],
      development_key: development ? ["\x07".b * 32] : []
    }
    layout(flags: flags, rows: rows, text: text, counts: { apps: apps }) do |bytes, at|
      6.times do |index|
        span(bytes, at[:facets] + index * 80 + 16, at[:facet_operations], 0)
        span(bytes, at[:facets] + index * 80 + 24, at[:facet_parameters], 0)
      end
      integer(bytes, at[:apps], 1_048_576, width: 8)
      integer(bytes, at[:apps] + 8, 2)
      integer(bytes, at[:apps] + 16, 2)
      integer(bytes, at[:apps] + 20, 5)
      span(bytes, at[:apps] + 24, at[:app_services], 2)
    end
  end
end
