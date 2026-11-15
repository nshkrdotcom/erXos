# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_manifest_fixture'

# Additional independent wire fixtures. These deliberately spell physical
# offsets from the format contract and do not use the production encoder.
module AbiErlangFixture
  module_function

  def devices(owners:, devices:)
    original = AbiManifestFixture.valid
    strings = original.byteslice(736..-1).dup
    units_offset = 736
    devices_offset = units_offset + owners * 24
    strings_offset = devices_offset + devices * AbiManifestFixture::DEVICE_ROW
    body = original.byteslice(0, 736) + "\0".b * (strings_offset - 736)
    AbiManifestFixture.span(body, 248, units_offset, owners)
    AbiManifestFixture.span(body, 256, devices_offset, devices)
    [*(264..352).step(8), *(384..432).step(8)].each { |offset| AbiManifestFixture.span(body, offset, strings_offset, 0) }
    owners.times do |index|
      offset = units_offset + index * 24
      name = "unit#{index}".b
      AbiManifestFixture.span(body, offset, strings.bytesize, name.bytesize)
      strings << name
      AbiManifestFixture.integer(body, offset + 8, 0xffffffff)
      AbiManifestFixture.span(body, offset + 12, devices_offset + index * AbiManifestFixture::DEVICE_ROW, 1)
    end
    devices.times do |index|
      offset = devices_offset + index * AbiManifestFixture::DEVICE_ROW
      AbiManifestFixture.integer(body, offset, 1)
      AbiManifestFixture.integer(body, offset + 4, 2)
      path = "/uart@#{index}".b
      AbiManifestFixture.span(body, offset + 8, strings.bytesize, path.bytesize)
      strings << path
      AbiManifestFixture.span(body, offset + 16, 0, 0)
      compatible = 'arm,pl011'.b
      AbiManifestFixture.span(body, offset + 24, strings.bytesize, compatible.bytesize)
      strings << compatible
      key = "uart#{index}".b
      AbiManifestFixture.span(body, offset + 56, strings.bytesize, key.bytesize)
      strings << key
    end
    AbiManifestFixture.span(body, 360, strings_offset, strings.bytesize)
    body << strings
    AbiManifestFixture.integer(body, 8, body.bytesize)
    body
  end

  def parameter(kind:, scalar: 0, index: 0, text: ''.b)
    original = AbiManifestFixture.valid
    strings = original.byteslice(736..-1) + 'clientserviceaccess'.b + text
    body = original.byteslice(0, 520) + "\0".b * 64 +
           original.byteslice(520, 216) + "\0".b * 136
    AbiManifestFixture.integer(body, 6, 1, width: 2)
    AbiManifestFixture.span(body, 216, 520, 1)
    AbiManifestFixture.span(body, 224, 584, 1)
    AbiManifestFixture.span(body, 232, 744, 1)
    (240..264).step(8) { |offset| AbiManifestFixture.span(body, offset, 800, 0) }
    AbiManifestFixture.span(body, 272, 800, 1)
    AbiManifestFixture.span(body, 280, 824, 1)
    AbiManifestFixture.span(body, 288, 904, 0)
    AbiManifestFixture.span(body, 296, 904, 1)
    (304..352).step(8) { |offset| AbiManifestFixture.span(body, offset, 936, 0) }
    AbiManifestFixture.span(body, 360, 936, strings.bytesize)
    AbiManifestFixture.span(body, 376, 584, 0)
    AbiManifestFixture.span(body, 384, 936, 0)
    AbiManifestFixture.span(body, 392, 936, 0)
    (400..432).step(8) { |offset| AbiManifestFixture.span(body, offset, 936, 0) }

    AbiManifestFixture.span(body, 520, 34, 6)
    AbiManifestFixture.integer(body, 532, 1)
    AbiManifestFixture.integer(body, 540, 2)
    AbiManifestFixture.integer(body, 544, 2)
    AbiManifestFixture.integer(body, 548, 1)
    AbiManifestFixture.integer(body, 564, 10) # the row's boot_timeout_s, from 1
    AbiManifestFixture.span(body, 568, 40, 0)
    AbiManifestFixture.span(body, 576, 40, 0)
    AbiManifestFixture.span(body, 800, 40, 7)
    AbiManifestFixture.integer(body, 812, 1)
    AbiManifestFixture.span(body, 824, 47, 6)
    AbiManifestFixture.span(body, 840, 904, 0)
    AbiManifestFixture.span(body, 848, 904, 1)
    AbiManifestFixture.integer(body, 856, 4096)
    AbiManifestFixture.integer(body, 860, 1)
    AbiManifestFixture.integer(body, 864, 1000, width: 8)
    AbiManifestFixture.integer(body, 872, 1_000_000, width: 8)
    AbiManifestFixture.integer(body, 880, 65_536, width: 8)
    AbiManifestFixture.integer(body, 888, 4096, width: 8)
    AbiManifestFixture.integer(body, 904, 1)
    AbiManifestFixture.integer(body, 908, kind)
    AbiManifestFixture.integer(body, 912, scalar, width: 8)
    AbiManifestFixture.span(body, 920, 53, text.bytesize) if [4, 5, 9].include?(kind)
    AbiManifestFixture.integer(body, 928, index)
    body << strings
    AbiManifestFixture.integer(body, 8, body.bytesize)
    body
  end
end
