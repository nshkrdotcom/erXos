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
    strings = original.byteslice(AbiManifestFixture::STRINGS_AT..-1).dup
    units_offset = AbiManifestFixture::STRINGS_AT
    devices_offset = units_offset + owners * 24
    strings_offset = devices_offset + devices * AbiManifestFixture::DEVICE_ROW
    body = original.byteslice(0, AbiManifestFixture::STRINGS_AT) + "\0".b * (strings_offset - AbiManifestFixture::STRINGS_AT)
    AbiManifestFixture.span(body, 248, units_offset, owners)
    AbiManifestFixture.span(body, 256, devices_offset, devices)
    [*(264..352).step(8), *(384..440).step(8)].each { |offset| AbiManifestFixture.span(body, offset, strings_offset, 0) }
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
    strings = original.byteslice(AbiManifestFixture::STRINGS_AT..-1) + 'clientserviceaccess'.b + text
    body = original.byteslice(0, AbiManifestFixture::LIMITS_AT) + "\0".b * 64 +
           original.byteslice(AbiManifestFixture::LIMITS_AT, 216) + "\0".b * 136
    AbiManifestFixture.integer(body, 6, 1, width: 2)
    AbiManifestFixture.span(body, 216, 552, 1)
    AbiManifestFixture.span(body, 224, 616, 1)
    AbiManifestFixture.span(body, 232, 776, 1)
    (240..264).step(8) { |offset| AbiManifestFixture.span(body, offset, 832, 0) }
    AbiManifestFixture.span(body, 272, 832, 1)
    AbiManifestFixture.span(body, 280, 856, 1)
    AbiManifestFixture.span(body, 288, 936, 0)
    AbiManifestFixture.span(body, 296, 936, 1)
    (304..352).step(8) { |offset| AbiManifestFixture.span(body, offset, 968, 0) }
    AbiManifestFixture.span(body, 360, 968, strings.bytesize)
    AbiManifestFixture.span(body, 376, 616, 0)
    AbiManifestFixture.span(body, 384, 968, 0)
    AbiManifestFixture.span(body, 392, 968, 0)
    (400..440).step(8) { |offset| AbiManifestFixture.span(body, offset, 968, 0) }

    AbiManifestFixture.span(body, 552, 34, 6)
    AbiManifestFixture.integer(body, 564, 1)
    AbiManifestFixture.integer(body, 572, 2)
    AbiManifestFixture.integer(body, 576, 2)
    AbiManifestFixture.integer(body, 580, 1)
    AbiManifestFixture.span(body, 600, 40, 0)
    AbiManifestFixture.span(body, 608, 40, 0)
    AbiManifestFixture.span(body, 832, 40, 7)
    AbiManifestFixture.integer(body, 844, 1)
    AbiManifestFixture.span(body, 856, 47, 6)
    AbiManifestFixture.span(body, 872, 936, 0)
    AbiManifestFixture.span(body, 880, 936, 1)
    AbiManifestFixture.integer(body, 888, 4096)
    AbiManifestFixture.integer(body, 892, 1)
    AbiManifestFixture.integer(body, 896, 1000, width: 8)
    AbiManifestFixture.integer(body, 904, 1_000_000, width: 8)
    AbiManifestFixture.integer(body, 912, 65_536, width: 8)
    AbiManifestFixture.integer(body, 920, 4096, width: 8)
    AbiManifestFixture.integer(body, 936, 1)
    AbiManifestFixture.integer(body, 940, kind)
    AbiManifestFixture.integer(body, 944, scalar, width: 8)
    AbiManifestFixture.span(body, 952, 53, text.bytesize) if [4, 5, 9].include?(kind)
    AbiManifestFixture.integer(body, 960, index)
    body << strings
    AbiManifestFixture.integer(body, 8, body.bytesize)
    body
  end
end
