# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs erx_mask's EUnit cases (test/erlang/erx_mask_tests.erl), compiled from source on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies); erx_mask is pure, so
# it needs no hosted build. Then the seeded fault of docs/design-desktop-programs.md's raster
# step, every pixel moved half a pixel, is compiled in place of erx_mask, and the quarter
# disc's area and the stroke's column coverage must each fail on it. Last, the densest graph
# must stroke within ten times its measured time.
class ErxMaskTest < Minitest::Test
  APPLICATIONS = %w[erx_memdraw].freeze
  TESTS = %w[test/erlang/erx_mask_tests.erl].freeze
  MASK = 'erlang/apps/erx_memdraw/src/erx_mask.erl'
  HALF_PIXEL_FROM = "centre(I) ->\n    I + 0.5."
  HALF_PIXEL_TO = "centre(I) ->\n    I + 0.0."
  CAUGHT_BY = %w[quarter_disc_sums_to_its_area_test stroke_column_coverage_test].freeze
  # The densest graph a stats window draws: 240 random samples across 300x60, stroked 1.5
  # wide. Its best of five runs took 22 ms on an Apple M3 Max under stock OTP 29.1.2 with
  # the JIT; ten times that fails, as sampling every pixel that two segments reach did.
  GRAPH = <<~ERLANG
    rand:seed(exsss, {1, 2, 3}),
    Points = [{I * 300 / 239, rand:uniform() * 60} || I <- lists:seq(0, 239)],
    Times = [element(1, timer:tc(erx_mask, stroke, [300, 60, Points, 1.5]))
             || _ <- lists:seq(1, 5)],
    io:format("~p~n", [lists:min(Times) div 1000]),
    halt().
  ERLANG
  GRAPH_LIMIT_MS = 220

  def test_dense_graph_strokes_in_time
    Dir.mktmpdir('erx-mask-time') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-eval', GRAPH, chdir: work, stdin_data: '')
      assert status.success?, output
      assert_operator Integer(output.strip), :<=, GRAPH_LIMIT_MS, "the dense graph's stroke, in ms"
    end
  end

  def test_mask_cases_pass_under_eunit
    Dir.mktmpdir('erx-mask-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = eunit(work, 'erx_mask_tests')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_half_pixel_offset_fails_disc_and_stroke
    text = File.read(File.join(ErlangBuild::ROOT, MASK))
    assert_equal 1, text.scan(HALF_PIXEL_FROM).size, "the pixel centre must be defined once in #{MASK}"
    Dir.mktmpdir('erx-mask-fault') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS,
                                replaced: { MASK => text.sub(HALF_PIXEL_FROM, HALF_PIXEL_TO) })
      CAUGHT_BY.each do |test|
        output, status = eunit(work, "{erx_mask_tests, #{test}}")
        refute status.success?, "a half-pixel offset passed #{test}:\n#{output}"
        assert_match(/Failed: 1/, output, test)
      end
    end
  end

  private

  def eunit(work, cases)
    Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                    '-eval', "halt(case eunit:test(#{cases}, []) of ok -> 0; _ -> 1 end)",
                    chdir: work, stdin_data: '')
  end
end
