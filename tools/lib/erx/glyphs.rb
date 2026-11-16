# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require_relative 'error'
require_relative 'abi_theme'
require_relative 'gpos'
require_relative 'origin'
require_relative 'bounded_file'
require_relative 'output_directory'
require_relative 'raster'
require_relative 'glyphs_menu'
require_relative 'glyphs_lvgl_font'

module Erx
  # The glyph step (docs/design-desktop-programs.md, "Type"): one Plan 9
  # subfont with an 8-bit grey image (`k8`) per role of the theme, from the
  # coverage erx-raster gives for the role's font, weight and size, written
  # into build/glyphs as ROLE.subfont, each role's glyphs a second time as
  # its LVGL font's C source (LvglFont), and the body role's a third time as
  # the window menu's Erlang module (Menu). Nothing here is checked in.
  #
  # The generated files hold glyph data derived from the role's font, so
  # each opens with a header (font_notice, header) that gives the license
  # the font's import records for the font file in its ORIGIN.md (OFL-1.1
  # for Inter, font data only) and a line naming the file, the import's
  # release and the copyright line of the import's LICENSE.txt. The
  # generators themselves stay erXos's, under BSD-2-Clause. A subfont file
  # is binary and has no place for a header; it holds the same data.
  #
  # A role's subfont holds one glyph for each code point of its font's
  # ranges, in ascending order across the ranges, so glyph i is the i-th code
  # point the ranges list. A code point the font lacks has an empty glyph of
  # width 0, which a Plan 9 font reader takes as missing (plan9port at commit
  # 1f13969, src/libdraw/font.c, lines 276-277), so the renderer draws the
  # replacement box for it as for a code point outside the ranges. A role
  # marked `figures tabular` takes the digits' tabular glyphs by name
  # (DIGITS, TABULAR) and is refused when the font lacks one.
  #
  # The image is as tall as the role's line; the baseline is where CSS puts
  # it, half the line's leading below the font's ascender: (line - (ascender
  # + descender)) / 2 + ascender, rounded half up, from the font's own
  # metrics. A glyph is drawn its coverage's offset right of the pen and
  # advances by its advance rounded half up to a whole pixel. A glyph whose ink
  # leaves the line, or a role whose values the subfont format cannot hold
  # (font(7): x in two bytes, rows, left and width in one), is refused, so
  # no subfont is cut to fit.
  #
  # The kerning ("Kerning"): each role's pairs, from its font's GPOS table
  # through Gpos, are adjustments in whole pixels of the first glyph's
  # advance when the second follows it, chosen so that width(a) + kern(a, b)
  # is the font's exact kerned advance rounded half up, as width(a) is the
  # exact advance rounded half up. Pairs name only drawn glyphs, those of
  # width other than 0, and a pair whose adjustment is 0 is not kept. They
  # follow the glyph table as the pair section: the word kern and the pair
  # count as two header fields, then per pair the two glyph indices, two
  # bytes each low byte first, and the adjustment as a signed byte, in
  # strictly ascending order. A role whose font has a legacy kern table, or
  # whose GPOS or GDEF table Gpos refuses, or with a pair whose adjustment
  # leaves a signed byte or whose kerned advance leaves 0 to 255, is refused.
  #
  # Each role's subfont is computed whole before any file is written, and
  # the whole directory is written beside its destination and renamed onto
  # it, so no reader sees a partial set and no stale role's file remains.
  module Glyphs
    OUTPUT = 'build/glyphs'
    EXTENSION = '.subfont'
    # The digits U+0030 to U+0039 by their glyph names, and the suffix of
    # their tabular forms' names (Inter 4.1's post table: zero.tf to nine.tf).
    DIGITS = %w[zero one two three four five six seven eight nine].freeze
    DIGIT_ZERO = 0x30
    TABULAR = '.tf'
    # A font(7) field: a word right-justified in 11 bytes, then a blank.
    FIELD = 11
    CHANNEL = 'k8'
    MAX_X = 0xffff
    ROW = 0..255
    LEFT = -128..127
    ADVANCE = 0..255
    ADJUSTMENT = -128..127
    PAIRS = 'kern'
    HALF = Rational(1, 2)
    # The license file of a font's import, beside its ORIGIN.md.
    FONT_LICENSE = 'LICENSE.txt'
    LICENSE_BYTES = 1 << 20

    class Refused < Error; end

    # Glyph i of a subfont, as font(7) records it: its columns start at X of
    # the image, its ink lies in rows TOP to BOTTOM (exclusive), it is drawn
    # LEFT pixels right of the pen and advances it by WIDTH.
    Glyph = Data.define(:x, :top, :bottom, :left, :width)
    # A glyph's entry and the coverage drawn in its columns, nil for an
    # absent glyph.
    Placed = Data.define(:glyph, :coverage)
    # What a generated file of a role's glyphs declares of the font they derive
    # from: LICENSE, an SPDX expression, and LINE, one line naming the font file,
    # its release and its copyright. Both go into a generated file's opening
    # comment, so each is printable ASCII and never ends a C comment.
    FontNotice = Data.define(:license, :line) do
      def initialize(license:, line:)
        [license, line].each do |text|
          next if text.is_a?(String) && text.match?(/\A[\x20-\x7e]+\z/) && !text.include?('*/')

          raise Refused, "font notice #{text.inspect} is not printable ASCII without a comment's end"
        end
        super
      end
    end

    # A k8 subfont: an image WIDTH by HEIGHT whose PIXELS are its rows top
    # first, one byte of coverage each, the baseline ASCENT rows down,
    # GLYPHS in index order, and PAIRS, each [first, second, adjustment] by
    # glyph index, ascending.
    Subfont = Data.define(:width, :height, :ascent, :pixels, :glyphs, :pairs) do
      def initialize(pairs: [].freeze, **fields) = super

      # The file: the image (image(7)), then the subfont header and the
      # glyph table with its closing entry, which gives only the end of the
      # last glyph's columns (font(7)), then the pair section when there
      # are pairs.
      def encode
        header = [CHANNEL, 0, 0, width, height].map { |word| Glyphs.field(word) }.join
        table = [height, ascent].map { |word| Glyphs.field(word) }.join
        entries = [*glyphs, Glyph.new(x: width, top: 0, bottom: 0, left: 0, width: 0)].map do |glyph|
          [glyph.x, glyph.top, glyph.bottom, glyph.left, glyph.width].pack('vCCcC')
        end
        header + pixels + Glyphs.field(glyphs.size) + table + entries.join + pair_section
      end

      def pair_section
        return '' if pairs.empty?

        [PAIRS, pairs.size].map { |word| Glyphs.field(word) }.join + pairs.map { |pair| pair.pack('vvc') }.join
      end
    end

    module_function

    def field(word) = "#{word.to_s.rjust(FIELD)} "

    # The theme of the tree at root.
    def theme(root:)
      source = File.read(File.join(root, ABI::Theme::SOURCE))
      ABI::Theme.validate(ABI::Syntax.parse(source, path: ABI::Theme::SOURCE).select { |item| item.kind == 'theme' })
    end

    # What write wrote: each role's subfont's path and LVGL font's path by
    # role name, and the window menu's glyph module's path.
    Written = Data.define(:subfonts, :lvgl, :menu)

    # Writes every role's subfont of theme and its LVGL font (LvglFont), and
    # the menu role's glyph module (Menu), into OUTPUT beneath output_root,
    # and returns their paths as Written. Font paths in the theme are beneath
    # root.
    def write(root:, program:, runner:, theme: Glyphs.theme(root: root), output_root: root)
      notices = theme.roles.transform_values { |role| font_notice(theme, role, root: root) }
      subfonts = theme.roles.transform_values do |role|
        font = theme.fonts.fetch(role.font)
        asked = requests(role, font)
        result = program.rasterise(font: File.join(root, font_file(theme, role)), size: role.size, glyphs: asked,
                                   runner: runner)
        subfont(role, requests: asked, result: result)
      end
      menu_role = theme.roles[Menu::ROLE] || raise(Refused, "the theme has no #{Menu::ROLE} role, which the window menu takes")
      menu = Menu.erlang(subfonts.fetch(Menu::ROLE), code_points: code_points(theme.fonts.fetch(menu_role.font)),
                         sources: [ABI::Theme::SOURCE, font_file(theme, menu_role)],
                         notice: notices.fetch(Menu::ROLE))
      lvgl_fonts = subfonts.to_h do |name, subfont|
        role = theme.roles.fetch(name)
        [LvglFont.file(name), LvglFont.c_source(subfont, role: role, ranges: theme.fonts.fetch(role.font).ranges,
                                                   sources: [ABI::Theme::SOURCE, font_file(theme, role)],
                                                   notice: notices.fetch(name))]
      end
      files = subfonts.to_h { |name, subfont| [subfont_file(name), subfont.encode] }.merge(lvgl_fonts, Menu::FILE => menu)
      paths = publish(files, output_root: output_root)
      Written.new(subfonts: subfonts.to_h { |name, _| [name, paths.fetch(subfont_file(name))] },
                  lvgl: subfonts.to_h { |name, _| [name, paths.fetch(LvglFont.file(name))] },
                  menu: paths.fetch(Menu::FILE))
    end

    # A role's font file, relative to the tree, and a role's subfont's file name.
    def font_file(theme, role)
      font = theme.fonts.fetch(role.font)
      File.join(font.directory, font.files.fetch(role.weight))
    end

    def subfont_file(name) = "#{name}#{EXTENSION}"

    # ROLE's FontNotice, from its font's import beneath root: the license
    # ORIGIN.md records for the font file's current bytes (its row in changes,
    # else in files, whose SHA-256 must be the file's), the first word of the
    # import's revision as its release, and the first line of its LICENSE.txt,
    # which must be a copyright line.
    def font_notice(theme, role, root:)
      font = theme.fonts.fetch(role.font)
      file = font.files.fetch(role.weight)
      path = font_file(theme, role)
      inventory = Origin.new(root: File.join(root, font.directory)).inventory
      row = inventory.fetch('changes')[file] || inventory.fetch('files')[file]
      refuse(role, "#{path} has no row in its import's ORIGIN.md") unless row
      refuse(role, "#{path} is not the file its ORIGIN.md row records") unless
        Digest::SHA256.file(File.join(root, path)).hexdigest == row.fetch('sha256')
      license_file = File.join(font.directory, FONT_LICENSE)
      copyright = BoundedFile.read(File.join(root, license_file), maximum: LICENSE_BYTES).lines.first.to_s.chomp
      refuse(role, "#{license_file} does not open with a copyright line") unless copyright.start_with?('Copyright ')
      FontNotice.new(license: row.fetch('license'),
                     line: "Glyph data derived from #{file} #{inventory.fetch('revision').split.first}, #{copyright}")
    end

    # The opening comment lines of a generated file of a role's glyphs, without
    # their comment leaders: erXos's copyright, NOTICE's license and line, and
    # that GENERATOR wrote it from SOURCES.
    def header(notice, generator:, sources:)
      ['Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>',
       "SPDX-License-Identifier: #{notice.license}",
       notice.line,
       "Generated by tools/erx build glyphs (#{generator}) from",
       *sources[0...-1].map { |source| "#{source}," }, "#{sources.last}.",
       'Do not edit this file.']
    end

    # FILES, their contents by name, in a new directory beside OUTPUT, which
    # then replaces it whole; returns each file's final path by name.
    def publish(files, output_root:)
      parent = OutputDirectory.prepare(root: output_root, path: File.join(output_root, File.dirname(OUTPUT)))
      destination = File.join(output_root, OUTPUT)
      raise Error, "glyph output is a symbolic link: #{destination}" if File.symlink?(destination)

      Dir.mktmpdir('.glyphs-', parent) do |work|
        fresh = File.join(work, 'glyphs')
        Dir.mkdir(fresh)
        files.each { |name, contents| File.binwrite(File.join(fresh, name), contents) }
        File.rename(destination, File.join(work, 'previous')) if File.exist?(destination)
        File.rename(fresh, destination)
      end
      files.to_h { |name, _| [name, File.join(destination, name)] }
    end

    # The code points of a font's ranges, in order: glyph i of its subfonts
    # is the i-th.
    def code_points(font) = font.ranges.flat_map { |low, high| (low..high).to_a }

    # What erx-raster is asked for, for each code point of the font's ranges
    # in order: the character, or for a tabular role's digit, the digit's
    # tabular glyph by name.
    def requests(role, font)
      code_points(font).map do |point|
        digit = point - DIGIT_ZERO
        if role.figures == 'tabular' && (0...DIGITS.size).cover?(digit)
          "#{DIGITS.fetch(digit)}#{TABULAR}"
        else
          format('U+%04X', point)
        end
      end
    end

    # The role's subfont from erx-raster's result for requests, or Refused.
    def subfont(role, requests:, result:)
      missing = requests.zip(result.glyphs).filter_map { |request, coverage| request if coverage.nil? && named?(request) }
      refuse(role, "its font has no tabular figure #{missing.join(', ')}") unless missing.empty?
      refuse(role, "its line of #{role.line} pixels does not fit a subfont's row field") unless ROW.cover?(role.line)

      ascent = baseline(role, result.face)
      columns = result.glyphs.map { |coverage| coverage ? coverage.width : 0 }
      starts = columns.each_with_object([0]) { |width, ends| ends << (ends.last + width) }
      width = starts.last
      refuse(role, "its glyphs are #{width} pixels wide, more than a subfont's #{MAX_X}") if width > MAX_X
      refuse(role, 'its font has none of its code points') if width.zero?

      # starts holds each glyph's first column and, last, the image's width.
      placed = requests.zip(result.glyphs, starts.first(requests.size)).map do |request, coverage, x|
        place(role, request, coverage, x: x, ascent: ascent)
      end
      Subfont.new(width: width, height: role.line, ascent: ascent, pixels: image(placed, width: width, height: role.line),
                  glyphs: placed.map(&:glyph).freeze, pairs: pairs(role, result: result, placed: placed))
    end

    # The role's pairs, [first, second, adjustment] by subfont glyph index in
    # ascending order, from the font's kerning of its drawn glyphs.
    def pairs(role, result:, placed:)
      refuse(role, 'its font has a legacy kern table, a second source of kerning') if result.legacy_kern
      drawn = placed.each_index.select { |index| placed[index].glyph.width.positive? }
      # The drawn subfont glyphs by the font glyph each draws.
      by_font_glyph = drawn.group_by { |index| result.glyphs.fetch(index).index }
      font_pairs(role, result: result, glyphs: by_font_glyph.keys).flat_map do |(font_first, font_second), units|
        by_font_glyph.fetch(font_first).product(by_font_glyph.fetch(font_second)).filter_map do |first, second|
          pixels = adjustment(role, result.face, result.glyphs.fetch(first), units)
          [first, second, pixels] unless pixels.zero?
        end
      end.sort.freeze
    end

    # Gpos's pairs of the font's glyphs GLYPHS, its refusal the role's.
    def font_pairs(role, result:, glyphs:)
      Gpos.pairs(gpos: result.gpos, gdef: result.gdef, glyphs: glyphs)
    rescue Gpos::Refused => e
      refuse(role, "its kerning: #{e.message}")
    end

    # The first glyph's kerned advance rounded half up, less its advance
    # rounded half up, in exact arithmetic: a the advance in 26.6 pixels
    # over 64, k the pair's UNITS scaled to the role's size.
    def adjustment(role, face, coverage, units)
      advance = Rational(coverage.advance, 64)
      kerned = (advance + Rational(units * role.size, face.units_per_em) + HALF).floor
      pixels = kerned - (advance + HALF).floor
      unless ADJUSTMENT.cover?(pixels)
        refuse(role, "glyph #{coverage.index}'s kerning of #{units} units is an adjustment of #{pixels} pixels")
      end
      refuse(role, "glyph #{coverage.index}'s kerned advance of #{kerned} pixels leaves 0 to 255") unless ADVANCE.cover?(kerned)
      pixels
    end

    # The baseline's row: half the line's leading below the font's ascender,
    # rounded half up, in exact arithmetic.
    def baseline(role, face)
      ascender = Rational(face.ascender * role.size, face.units_per_em)
      descender = Rational(-face.descender * role.size, face.units_per_em)
      ascent = ((role.line - (ascender + descender)) / 2 + ascender + Rational(1, 2)).floor
      refuse(role, "its baseline at row #{ascent} lies outside its line") unless (0..role.line).cover?(ascent)
      ascent
    end

    # A glyph as placed in the image. An absent glyph is empty and has width 0.
    def place(role, request, coverage, x:, ascent:)
      return Placed.new(glyph: Glyph.new(x: x, top: 0, bottom: 0, left: 0, width: 0), coverage: nil) if coverage.nil?

      advance = (coverage.advance + 32) >> 6
      top = coverage.rows.empty? ? 0 : ascent - coverage.top
      bottom = top + coverage.rows.size
      refuse(role, "#{request} leaves the line, rows #{top} to #{bottom} of #{role.line}") unless top >= 0 && bottom <= role.line
      refuse(role, "#{request} is offset #{coverage.left} pixels from the pen") unless LEFT.cover?(coverage.left)
      refuse(role, "#{request} advances #{advance} pixels") unless ADVANCE.cover?(advance)
      Placed.new(glyph: Glyph.new(x: x, top: top, bottom: bottom, left: coverage.left, width: advance), coverage: coverage)
    end

    # The image's rows: each placed glyph's coverage in its columns and rows,
    # zero elsewhere.
    def image(placed, width:, height:)
      rows = Array.new(height) { "\0".b * width }
      placed.each do |entry|
        entry.coverage&.rows&.each_with_index do |row, index|
          rows[entry.glyph.top + index][entry.glyph.x, row.bytesize] = row
        end
      end
      rows.join
    end

    # Whether a request names a glyph rather than a character (requests).
    def named?(request) = !request.start_with?('U+')

    def refuse(role, reason) = raise(Refused, "role #{role.name}: #{reason}")
  end
end
