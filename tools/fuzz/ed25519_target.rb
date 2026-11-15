# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'openssl'

# erx_ed25519_check, erx_bytes:ed25519_verify/3's core: a signature, a public key and a
# message across SHA-512's block and padding boundaries, each signed by a seeded key as
# OpenSSL signs it, and each again with its signature's last byte changed.
key = OpenSSL::PKey.new_raw_private_key('ED25519', "\x5a".b * 32)
Erx::PackFuzz.declare_target(
  sources: %w[otp/erts/emulator/nifs/erxos/erx_ed25519.c monocypher/monocypher.c monocypher/monocypher-ed25519.c],
  includes: [*Erx::PackFuzz::INCLUDES, '.', 'otp/erts/emulator/nifs/erxos'],
  seeds: [0, 1, 63, 64, 111, 112, 128, 1000].each_with_object({}) do |length, seeds|
    message = ("\xa5".b * length)
    signature = key.sign(nil, message)
    seeds["signed-#{length}"] = signature + key.raw_public_key + message
    seeds["altered-#{length}"] = signature.byteslice(0, 63) + (signature.getbyte(63) ^ 1).chr + key.raw_public_key + message
  end
)
