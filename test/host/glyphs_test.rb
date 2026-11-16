# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/square_font'
require_relative '../../tools/lib/erx/glyphs'

# The glyph step (docs/design-desktop-programs.md, "Type"): erx-raster, built
# once from the fetched FreeType pin (tools/erx fetch --source freetype) into
# a temporary directory, and Erx::Glyphs over it. A square glyph's coverage
# lands exactly where its geometry puts it, and an erx-raster seeded with a
# one-pixel shift fails that; the theme's subfonts are byte-identical over two
# runs, each parses with erx_font and loads into erx_draw_core on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies); and a role whose
# font lacks a tabular figure, or one with a glyph whose ink leaves its line,
# is refused.
class GlyphsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  THEME = File.read(File.join(ROOT, 'abi/theme.txt')).freeze
  # The one-pixel shift: every glyph's top one row higher than FreeType put it.
  SHIFT = ['put_u32((uint32_t)(int32_t)slot->bitmap_top);', 'put_u32((uint32_t)(int32_t)slot->bitmap_top + 1);'].freeze
  DEADLINE_SECONDS = '300'

  # erx-raster, built once for every case: the tree's, and the one seeded
  # with SHIFT.
  def self.programs
    @programs ||= begin
      work = Dir.mktmpdir('erx-glyphs-test-')
      Minitest.after_run { FileUtils.remove_entry(work) }
      runner = Erx::Runner.new(owner_root: work, log_dir: File.join(work, 'logs'))
      %w[tree seeded].each { |name| Dir.mkdir(File.join(work, name)) }
      source = File.read(File.join(ROOT, Erx::Raster::PROGRAM_SOURCE))
      raise "the shift's anchor is not once in #{Erx::Raster::PROGRAM_SOURCE}" unless source.scan(SHIFT.first).size == 1

      seeded = File.join(work, 'erx_raster.c')
      File.write(seeded, source.sub(SHIFT.first, SHIFT.last))
      { runner: runner,
        tree: Erx::Raster::Build.new(root: ROOT, runner: runner, output_root: File.join(work, 'tree')).call,
        seeded: Erx::Raster::Build.new(root: ROOT, runner: runner, output_root: File.join(work, 'seeded'),
                                       program: seeded).call }.freeze
    end
  end

  def setup
    @work = Dir.mktmpdir('erx-glyphs-case-')
  end

  def teardown = FileUtils.remove_entry(@work)

  def test_square_glyph_coverage_is_exact
    assert_equal expected_squares.encode, square_subfont(:tree)
  end

  def test_one_pixel_shift_fails_the_square_test
    refute_equal expected_squares.encode, square_subfont(:seeded)
  end

  def test_theme_subfonts_are_byte_identical_over_two_runs
    first, second = %w[first second].map { |name| write_theme(File.join(@work, name).tap { |path| Dir.mkdir(path) }) }
    assert_equal first.keys, second.keys
    first.each { |role, path| assert_equal File.binread(path), File.binread(second.fetch(role)), "role #{role}" }
  end

  def test_theme_subfonts_parse_and_load_in_a_draw_connection
    subfonts = write_theme(File.join(@work, 'roles').tap { |path| Dir.mkdir(path) })
    assert_equal theme_of(THEME).roles.keys, subfonts.keys
    ErlangBuild.compile(@work, applications: %w[erx_win], tests: %w[test/erlang/erx_glyph_subfonts_tests.erl])
    FileUtils.cp(subfonts.values, @work)
    output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                     '-pa', @work, '-eval',
                                     'halt(case eunit:test(erx_glyph_subfonts_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                     chdir: @work, stdin_data: '')
    assert status.success?, output
    assert_match(/All #{subfonts.size + 1} tests passed/, output)
  end

  def test_role_whose_font_lacks_a_tabular_figure_is_refused
    fonts = File.join(@work, 'display/fonts/inter')
    FileUtils.mkdir_p(fonts)
    medium = File.binread(File.join(ROOT, 'display/fonts/inter/Inter-Medium.ttf'))
    # The post table's name of one.tf, a Pascal string of six bytes.
    name = "\x06one.tf".b
    assert_equal 1, medium.scan(name).size, 'the post table names one.tf once'
    File.binwrite(File.join(fonts, 'Inter-Medium.ttf'), medium.sub(name, "\x06one.tx".b))
    theme = theme_of(THEME.gsub(/^  role .*\n/, '')
                          .sub("  # The spacing scale", "  role numeric font ui size 13 line 20 weight medium figures tabular\n  # The spacing scale"))
    error = assert_raises(Erx::Glyphs::Refused) { write(root: @work, theme: theme, program: :tree) }
    assert_equal 'role numeric: its font has no tabular figure one.tf', error.message
  end

  # The display role in a 56-pixel line: Inter SemiBold's accented capitals
  # and bar leave it at 48 pixels.
  def test_glyph_whose_ink_leaves_the_line_is_refused
    display = THEME[/^  role display .*\n/].sub(/ line \d+ /, ' line 56 ')
    theme = theme_of(THEME.gsub(/^  role .*\n/, '').sub('  # The spacing scale', "#{display}  # The spacing scale"))
    error = assert_raises(Erx::Glyphs::Refused) { write(root: ROOT, theme: theme, program: :tree, output_root: @work) }
    assert_match(/\Arole display: U\+[0-9A-F]{4} leaves the line, rows -?\d+ to \d+ of 56\z/, error.message)
  end

  private

  # Glyphs over the square font: a role of U+0041 to U+0043 at 16 pixels in
  # a 20-pixel line, through the tree's or the seeded erx-raster.
  def square_subfont(program)
    FileUtils.mkdir_p(File.join(@work, 'fonts'))
    File.binwrite(File.join(@work, 'fonts/Square.ttf'), SquareFont.bytes)
    theme = theme_of(THEME.gsub(/^  (?:font|range|role) .*\n/, '').sub("  # The spacing scale", <<~ROWS.gsub(/^/, '  ').chomp))
      font square fonts regular Square.ttf
      range square 0041-0043
      role box font square size 16 line 20 weight regular
      # The spacing scale
    ROWS
    File.binread(write(root: @work, theme: theme, program: program).fetch('box'))
  end

  # The squares' subfont as their geometry gives it. The ascender and
  # descender, 13 and 3 pixels, leave 4 pixels of the 20-pixel line, so the
  # baseline is row 2 + 13 = 15. U+0041 covers whole pixels: 4 by 4, rows 11
  # to 15, one pixel right of the pen. U+0042, moved half a pixel, touches 5
  # by 5 pixels, rows 10 to 15: half of each edge pixel, a quarter of each
  # corner. U+0043 covers 4 by 4 whole pixels from 2 rows above the baseline
  # to 2 below, rows 13 to 17, one pixel left of the pen, and its advance of
  # 6.5 pixels rounds up to 7.
  def expected_squares
    whole = Array.new(4) { [255] * 4 }
    edge = [64, *[128] * 3, 64]
    half = [edge, *Array.new(3) { [128, 255, 255, 255, 128] }, edge]
    rows = Array.new(20) { [0] * 13 }
    whole.each_with_index { |row, index| rows[11 + index][0, 4] = row }
    half.each_with_index { |row, index| rows[10 + index][4, 5] = row }
    whole.each_with_index { |row, index| rows[13 + index][9, 4] = row }
    glyphs = [Erx::Glyphs::Glyph.new(x: 0, top: 11, bottom: 15, left: 1, width: 6),
              Erx::Glyphs::Glyph.new(x: 4, top: 10, bottom: 15, left: 1, width: 6),
              Erx::Glyphs::Glyph.new(x: 9, top: 13, bottom: 17, left: -1, width: 7)]
    Erx::Glyphs::Subfont.new(width: 13, height: 20, ascent: 15, pixels: rows.flatten.pack('C*'), glyphs: glyphs)
  end

  # The theme's roles, written beneath output_root.
  def write_theme(output_root) = write(root: ROOT, theme: theme_of(THEME), program: :tree, output_root: output_root)

  def write(root:, theme:, program:, output_root: root)
    programs = self.class.programs
    Erx::Glyphs.write(root: root, program: programs.fetch(program), runner: programs.fetch(:runner), theme: theme,
                      output_root: output_root)
  end

  def theme_of(text)
    Erx::ABI::Theme.validate(Erx::ABI::Syntax.parse(text, path: 'abi/theme.txt').select { |item| item.kind == 'theme' })
  end
end
