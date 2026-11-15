# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_png_tests.erl and erx_inflate_tests.erl, the PNG
# reader's cases over test/fixtures/pngsuite and the inflate's agreement with
# stock OTP's zlib, and a short run of the fuzz target erx_png_fuzz, on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies). Then each seeded
# fault of docs/design-display.md's "Verification and testing", applied to a
# copy of erx_png or erx_inflate, must fail the case named for it, or the fuzz
# run.
class ErxPngTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx_win].freeze
  PNG = 'erlang/apps/erx_win/src/erx_png.erl'
  INFLATE = 'erlang/apps/erx_win/src/erx_inflate.erl'
  TESTS = %w[test/erlang/erx_png_encode.erl test/erlang/erx_png_tests.erl test/erlang/erx_inflate_tests.erl
             test/erlang/erx_png_fuzz.erl].freeze
  PNGSUITE = File.join(ROOT, 'test/fixtures/pngsuite')
  FUZZ_ROUNDS = 2000
  DEADLINE_SECONDS = '600'

  Seed = Data.define(:fault, :source, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the output bound removed', source: INFLATE,
             anchor: 'check(byte_size(Out) + byte_size(Bytes) =< Limit, limit),',
             replacement: 'check(true, limit),', catching_case: 'limit_test'),
    Seed.new(fault: 'the output bound removed, under the fuzz target', source: INFLATE,
             anchor: 'check(byte_size(Out) + byte_size(Bytes) =< Limit, limit),',
             replacement: 'check(true, limit),', catching_case: :fuzz),
    Seed.new(fault: "an off-by-one in a back-reference's distance", source: INFLATE,
             anchor: 'put(Out, copy(Out, Distance, Length), Limit)',
             replacement: 'put(Out, copy(Out, max(1, Distance - 1), Length), Limit)',
             catching_case: 'differential_test'),
    Seed.new(fault: 'the Adler-32 unchecked', source: INFLATE,
             anchor: 'check(erlang:adler32(Data) =:= Adler, check)', replacement: 'ok',
             catching_case: 'stream_refusal_test_'),
    Seed.new(fault: 'an interlaced image read', source: PNG,
             anchor: "check(Interlace =/= 1, interlaced),\n    check(Interlace =:= 0, header),",
             replacement: 'check(Interlace =< 1, header),', catching_case: 'interlaced_test'),
    Seed.new(fault: 'the image not put to the draw connection', source: PNG,
             anchor: 'case erx_draw_core:admit(R, Depth, Quota) of', replacement: 'case ok of',
             catching_case: 'quota_test'),
    Seed.new(fault: 'every code-length set taken as usable', source: INFLATE,
             anchor: 'usable(_Left, _Longest, _Kind) -> false.', replacement: 'usable(_Left, _Longest, _Kind) -> true.',
             catching_case: 'incomplete_codes_test_'),
    Seed.new(fault: 'the CRC unchecked', source: PNG,
             anchor: 'check(erlang:crc32([Type, Data]) =:= Crc, crc),', replacement: 'ok,',
             catching_case: 'refusal_test_'),
    Seed.new(fault: "Paeth's last choice the byte above", source: PNG,
             anchor: "        true -> C\n", replacement: "        true -> B\n", catching_case: 'filters_test')
  ].freeze

  def test_cases_pass_under_eunit
    output, status = run_cases({}, eunit_command)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_fuzz_target_runs_clean
    output, status = run_cases({}, fuzz_command)
    assert status.success?, output
  end

  def test_each_seeded_fault_fails_its_case
    sources = [PNG, INFLATE].to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    SEEDS.each do |seed|
      assert_equal 1, sources.fetch(seed.source).scan(seed.anchor).size, "anchor for #{seed.fault} is not once"
    end
    runs = SEEDS.map do |seed|
      seeded = { seed.source => sources.fetch(seed.source).sub(seed.anchor, seed.replacement) }
      command = seed.catching_case == :fuzz ? fuzz_command : eunit_command
      Thread.new { [seed, *run_cases(seeded, command)] }
    end
    runs.map(&:value).each do |seed, output, status|
      refute status.success?, "#{seed.fault} passed:\n#{output}"
      assert_match(caught_by(seed.catching_case), output, "#{seed.catching_case} did not catch #{seed.fault}")
    end
  end

  private

  def eunit_command = 'halt(case eunit:test([erx_png_tests, erx_inflate_tests], [verbose]) of ok -> 0; _ -> 1 end)'

  def fuzz_command = "erx_png_fuzz:rounds(1, #{FUZZ_ROUNDS}), halt(0)"

  # What the output shows when the case named, or the fuzz target, caught a fault: the fuzz
  # target's past_limit, the one assertion a seed it is named for breaks; or the case's
  # failure, EUnit naming a plain case by its function and a generator's by the fun inside it.
  def caught_by(name)
    return /past_limit/ if name == :fuzz

    %r{#{Regexp.escape(name)}(/0-fun-\d+-)?\.\.\.(\[[^\]]*\] )?\*failed\*}
  end

  # The output and status of Command, over the applications with the sources of replaced in place of the tree's.
  def run_cases(replaced, command)
    Dir.mktmpdir('erx-png-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e({ 'ERX_PNGSUITE' => PNGSUITE }, 'gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work, '-eval', command, chdir: work, stdin_data: '')
    end
  end
end
