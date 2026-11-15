# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/prog_profile_frames'

# liberx's erx_prog check, and the start-up plan over it (liberx/program/startup.c), over
# hostile frames. Inputs in tools/fuzz/erx_prog_fuzz.c's format: a byte whose bits 0-2 choose
# the frame (0 start, 1 request, 2 notice, 3 report, 4 a frame to the program after its
# startup message), whose bits 3-5 offset the scratch and whose bits 6-7 choose the busy
# slots (1, every slot holding a kill), then the frame. Seeds: the hand-encoded start frames
# of test/fixtures/prog_profile_frames.rb that fit the fuzz bound (every encoding, a
# capability past 2^63 - 1, wrappers past the depth, lists in segments), a start frame with
# a pipe's two ends, the request frames, a frame of each notice and report, each reply as a
# frame to the program, and a start frame with no descriptor and a cwd of prog_path_max
# bytes, which the plan copies whole.
frames = ProgProfileFrames
fixtures = frames::ALL.select { |fixture| fixture.bytes.bytesize < 32_768 }
etf = frames::Etf
cwd_at_max = frames.start(frames::BASE_PAIRS.merge(fds: etf::NIL, cwd: etf.binary('/' + ('c' * 4095))))
# A reply seed's busy slots are one of the fuzz target's patterns: every slot a kill for a reply on a
# kill, and slot 0 a kill and slot 1 a probe for a reply on slot 1's probe.
choice = { 'start' => "\x00".b, 'request' => "\x01".b, 'notice' => "\x02".b, 'report' => "\x03".b,
           'reply' => [4 | (1 << 6)].pack('C') }.freeze
probe_reply = [4 | (3 << 6)].pack('C')
selector = ->(seed) { seed.busy == '1:probe' ? probe_reply : choice.fetch(seed.frame) }
Erx::PackFuzz.declare_target(
  sources: %w[liberx/program/startup.c liberx/program/inbound.c liberx/erx_profile.c liberx/erx_etf.c kernel/crypto/blake3/blake3.c
              kernel/crypto/blake3/blake3_portable.c build/gen/liberx/generated/prog_profile.c],
  includes: [*Erx::PackFuzz::INCLUDES, '.'],
  seeds: fixtures.to_h { |fixture| [fixture.name.to_s.tr('_', '-'), choice.fetch('start') + fixture.bytes] }.merge(
    frames::SEEDS.to_h { |seed| [seed.name, selector.call(seed) + seed.bytes] }
  ).merge('cwd-at-max' => choice.fetch('start') + cwd_at_max)
)
