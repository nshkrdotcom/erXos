# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# F2FS's codec, erx_f2fs_codec (docs/design-f2fs.md, "Reading the medium" and "Unit and
# property tests"): its EUnit cases on stock's emulator (ERX_ERL and ERX_ERLC), then the
# same cases against a codec with one seeded fault each, which must fail the case named
# for it: so the cases reach the code each fault breaks.
class ErxF2fsCodecTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CODEC = 'erlang/apps/erx_f2fs/src/erx_f2fs_codec.erl'
  TESTS = %w[test/erlang/erx_f2fs_codec_tests.erl].freeze

  Seed = Data.define(:fault, :anchor, :replacement, :failure)

  SEEDS = [
    Seed.new(fault: "zlib's inversions kept in the CRC",
             anchor: "    Inverted = erlang:crc32((bnot Seed) band 16#ffffffff, Data),\n" \
                     "    (bnot Inverted) band 16#ffffffff.",
             replacement: '    erlang:crc32(Seed, Data).',
             failure: /crc_matches_the_definition_from_any_seed_test.*failed/),
    Seed.new(fault: 'the area-boundary rule of [F 14] dropped',
             anchor: "    check_areas(Super),\n", replacement: '',
             failure: /each_superblock_rule_fails_with_its_name.*areas.*failed/m),
    Seed.new(fault: "the header bitmaps' room check removed",
             anchor: '            require(SitBytes + NatBytes =< HeaderRoom, bitmap_room),',
             replacement: '            ok,',
             failure: /bitmaps_past_their_room_fail.*failed/m),
    Seed.new(fault: 'the orphan count bound off by one',
             anchor: '    require(Used =< ?ERX_F2FS_ORPHANS_PER_BLOCK, entry_count),',
             replacement: '    require(Used =< ?ERX_F2FS_ORPHANS_PER_BLOCK + 1, entry_count),',
             failure: /an_orphan_count_past_the_block_fails_test.*failed/)
  ].freeze

  def test_eunit_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    text = File.read(File.join(ROOT, CODEC))
    SEEDS.each do |seed|
      assert_equal 1, text.scan(seed.anchor).size, "the seed no longer applies: #{seed.fault}"
      output, status = eunit({ CODEC => text.sub(seed.anchor, seed.replacement) })
      refute status.success?, "#{seed.fault} passed:\n#{output}"
      assert_match seed.failure, output, seed.fault
    end
  end

  private

  # Runs the EUnit cases against erx and erx_f2fs with the given sources replaced; the
  # output and status.
  def eunit(replaced)
    Dir.mktmpdir('erx-f2fs-codec-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_f2fs], tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_f2fs_codec_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
