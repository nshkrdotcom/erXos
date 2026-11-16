# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_font_tests.erl, the cases of erx_font, the reader of
# Plan 9 subfont files (docs/design-display.md, "Erlang clients"), on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies), in a directory
# holding the subfonts of display/font/fixed. Then erx_font without its
# check for bytes after the glyph table must fail trailing_test, and an
# erx_font that takes each tile's pixels one pixel left of its rectangle
# must fail tiles_test.
class ErxFontTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx_win].freeze
  MODULE_SOURCE = 'erlang/apps/erx_win/src/erx_font.erl'
  TESTS = %w[test/erlang/erx_font_tests.erl].freeze
  FONTS = Dir.glob(File.join(ROOT, 'display/font/fixed/6x13.*')).freeze
  SEED = ["                    <<_:TableBytes/binary, _/binary>> -> throw(trailing);\n", ''].freeze
  TILE_SEED = ["    Start = X0 * Depth div 8,\n", "    Start = max(0, X0 * Depth div 8 - 1),\n"].freeze
  DEADLINE_SECONDS = '300'

  def test_cases_pass_under_eunit
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_parser_without_the_trailing_check_fails_its_case
    output, status = seeded(SEED, 'the trailing check')
    refute status.success?, "a parser without the trailing check passed every case:\n#{output}"
    assert_match(/trailing_test\.\.\.\*failed\*/, output)
  end

  def test_loader_with_a_tile_one_pixel_off_fails_its_case
    output, status = seeded(TILE_SEED, "a tile's first byte")
    refute status.success?, "a loader taking each tile one pixel left passed every case:\n#{output}"
    assert_match(/tiles_test\.\.\.\*failed\*/, output)
  end

  private

  # The cases' output and status over erx_font with the anchor of seed, named
  # what, replaced by its replacement.
  def seeded(seed, what)
    source = File.binread(File.join(ROOT, MODULE_SOURCE))
    anchor, replacement = seed
    assert_equal 1, source.scan(anchor).size, "#{what} is not once in #{MODULE_SOURCE}"
    eunit({ MODULE_SOURCE => source.sub(anchor, replacement) })
  end

  # The cases' output and status, over the applications with the sources of replaced in place of the tree's.
  def eunit(replaced)
    Dir.mktmpdir('erx-font-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      FileUtils.cp(FONTS, work)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_font_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
