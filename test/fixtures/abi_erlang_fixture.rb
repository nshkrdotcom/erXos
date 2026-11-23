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
    [*(264..352).step(8), *(384..440).step(8), 472, 480, 488].each { |offset| AbiManifestFixture.span(body, offset, strings_offset, 0) }
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
    AbiManifestFixture.span(body, 216, 576, 1)
    AbiManifestFixture.span(body, 224, 640, 1)
    AbiManifestFixture.span(body, 232, 800, 1)
    [*(240..264).step(8), 472, 480, 488].each { |offset| AbiManifestFixture.span(body, offset, 856, 0) }
    AbiManifestFixture.span(body, 272, 856, 1)
    AbiManifestFixture.span(body, 280, 880, 1)
    AbiManifestFixture.span(body, 288, 960, 0)
    AbiManifestFixture.span(body, 296, 960, 1)
    (304..352).step(8) { |offset| AbiManifestFixture.span(body, offset, 992, 0) }
    AbiManifestFixture.span(body, 360, 992, strings.bytesize)
    AbiManifestFixture.span(body, 376, 640, 0)
    AbiManifestFixture.span(body, 384, 992, 0)
    AbiManifestFixture.span(body, 392, 992, 0)
    (400..440).step(8) { |offset| AbiManifestFixture.span(body, offset, 992, 0) }

    AbiManifestFixture.span(body, 576, 34, 6)
    AbiManifestFixture.integer(body, 588, 1)
    AbiManifestFixture.integer(body, 596, 2)
    AbiManifestFixture.integer(body, 600, 2)
    AbiManifestFixture.integer(body, 604, 1)
    AbiManifestFixture.span(body, 624, 40, 0)
    AbiManifestFixture.span(body, 632, 40, 0)
    AbiManifestFixture.span(body, 856, 40, 7)
    AbiManifestFixture.integer(body, 868, 1)
    AbiManifestFixture.span(body, 880, 47, 6)
    AbiManifestFixture.span(body, 896, 960, 0)
    AbiManifestFixture.span(body, 904, 960, 1)
    AbiManifestFixture.integer(body, 912, 4096)
    AbiManifestFixture.integer(body, 916, 1)
    AbiManifestFixture.integer(body, 920, 1000, width: 8)
    AbiManifestFixture.integer(body, 928, 1_000_000, width: 8)
    AbiManifestFixture.integer(body, 936, 65_536, width: 8)
    AbiManifestFixture.integer(body, 944, 4096, width: 8)
    AbiManifestFixture.integer(body, 960, 1)
    AbiManifestFixture.integer(body, 964, kind)
    AbiManifestFixture.integer(body, 968, scalar, width: 8)
    AbiManifestFixture.span(body, 976, 53, text.bytesize) if [4, 5, 9].include?(kind)
    AbiManifestFixture.integer(body, 984, index)
    body << strings
    AbiManifestFixture.integer(body, 8, body.bytesize)
    body
  end
end
