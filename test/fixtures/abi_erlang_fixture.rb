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
    [*(264..352).step(8), *(384..440).step(8), 472].each { |offset| AbiManifestFixture.span(body, offset, strings_offset, 0) }
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
      AbiManifestFixture.span(body, offset + 96, strings_offset, 0)
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
    AbiManifestFixture.span(body, 216, 560, 1)
    AbiManifestFixture.span(body, 224, 624, 1)
    AbiManifestFixture.span(body, 232, 784, 1)
    [*(240..264).step(8), 472].each { |offset| AbiManifestFixture.span(body, offset, 840, 0) }
    AbiManifestFixture.span(body, 272, 840, 1)
    AbiManifestFixture.span(body, 280, 864, 1)
    AbiManifestFixture.span(body, 288, 944, 0)
    AbiManifestFixture.span(body, 296, 944, 1)
    (304..352).step(8) { |offset| AbiManifestFixture.span(body, offset, 976, 0) }
    AbiManifestFixture.span(body, 360, 976, strings.bytesize)
    AbiManifestFixture.span(body, 376, 624, 0)
    AbiManifestFixture.span(body, 384, 976, 0)
    AbiManifestFixture.span(body, 392, 976, 0)
    (400..440).step(8) { |offset| AbiManifestFixture.span(body, offset, 976, 0) }

    AbiManifestFixture.span(body, 560, 34, 6)
    AbiManifestFixture.integer(body, 572, 1)
    AbiManifestFixture.integer(body, 580, 2)
    AbiManifestFixture.integer(body, 584, 2)
    AbiManifestFixture.integer(body, 588, 1)
    AbiManifestFixture.span(body, 608, 40, 0)
    AbiManifestFixture.span(body, 616, 40, 0)
    AbiManifestFixture.span(body, 840, 40, 7)
    AbiManifestFixture.integer(body, 852, 1)
    AbiManifestFixture.span(body, 864, 47, 6)
    AbiManifestFixture.span(body, 880, 944, 0)
    AbiManifestFixture.span(body, 888, 944, 1)
    AbiManifestFixture.integer(body, 896, 4096)
    AbiManifestFixture.integer(body, 900, 1)
    AbiManifestFixture.integer(body, 904, 1000, width: 8)
    AbiManifestFixture.integer(body, 912, 1_000_000, width: 8)
    AbiManifestFixture.integer(body, 920, 65_536, width: 8)
    AbiManifestFixture.integer(body, 928, 4096, width: 8)
    AbiManifestFixture.integer(body, 944, 1)
    AbiManifestFixture.integer(body, 948, kind)
    AbiManifestFixture.integer(body, 952, scalar, width: 8)
    AbiManifestFixture.span(body, 960, 53, text.bytesize) if [4, 5, 9].include?(kind)
    AbiManifestFixture.integer(body, 968, index)
    body << strings
    AbiManifestFixture.integer(body, 8, body.bytesize)
    body
  end
end
