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
    strings = original.byteslice(744..-1).dup
    units_offset = 744
    devices_offset = units_offset + owners * 24
    strings_offset = devices_offset + devices * AbiManifestFixture::DEVICE_ROW
    body = original.byteslice(0, 744) + "\0".b * (strings_offset - 744)
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
    strings = original.byteslice(744..-1) + 'clientserviceaccess'.b + text
    body = original.byteslice(0, 528) + "\0".b * 64 +
           original.byteslice(528, 216) + "\0".b * 136
    AbiManifestFixture.integer(body, 6, 1, width: 2)
    AbiManifestFixture.span(body, 216, 528, 1)
    AbiManifestFixture.span(body, 224, 592, 1)
    AbiManifestFixture.span(body, 232, 752, 1)
    (240..264).step(8) { |offset| AbiManifestFixture.span(body, offset, 808, 0) }
    AbiManifestFixture.span(body, 272, 808, 1)
    AbiManifestFixture.span(body, 280, 832, 1)
    AbiManifestFixture.span(body, 288, 912, 0)
    AbiManifestFixture.span(body, 296, 912, 1)
    (304..352).step(8) { |offset| AbiManifestFixture.span(body, offset, 944, 0) }
    AbiManifestFixture.span(body, 360, 944, strings.bytesize)
    AbiManifestFixture.span(body, 376, 592, 0)
    AbiManifestFixture.span(body, 384, 944, 0)
    AbiManifestFixture.span(body, 392, 944, 0)
    (400..440).step(8) { |offset| AbiManifestFixture.span(body, offset, 944, 0) }

    AbiManifestFixture.span(body, 528, 34, 6)
    AbiManifestFixture.integer(body, 540, 1)
    AbiManifestFixture.integer(body, 548, 2)
    AbiManifestFixture.integer(body, 552, 2)
    AbiManifestFixture.integer(body, 556, 1)
    AbiManifestFixture.integer(body, 572, 10) # the row's boot_timeout_s, from 1
    AbiManifestFixture.span(body, 576, 40, 0)
    AbiManifestFixture.span(body, 584, 40, 0)
    AbiManifestFixture.span(body, 808, 40, 7)
    AbiManifestFixture.integer(body, 820, 1)
    AbiManifestFixture.span(body, 832, 47, 6)
    AbiManifestFixture.span(body, 848, 912, 0)
    AbiManifestFixture.span(body, 856, 912, 1)
    AbiManifestFixture.integer(body, 864, 4096)
    AbiManifestFixture.integer(body, 868, 1)
    AbiManifestFixture.integer(body, 872, 1000, width: 8)
    AbiManifestFixture.integer(body, 880, 1_000_000, width: 8)
    AbiManifestFixture.integer(body, 888, 65_536, width: 8)
    AbiManifestFixture.integer(body, 896, 4096, width: 8)
    AbiManifestFixture.integer(body, 912, 1)
    AbiManifestFixture.integer(body, 916, kind)
    AbiManifestFixture.integer(body, 920, scalar, width: 8)
    AbiManifestFixture.span(body, 928, 53, text.bytesize) if [4, 5, 9].include?(kind)
    AbiManifestFixture.integer(body, 936, index)
    body << strings
    AbiManifestFixture.integer(body, 8, body.bytesize)
    body
  end
end
