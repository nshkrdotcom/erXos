# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'error'
require_relative 'abi_theme'
require_relative 'output_directory'
require_relative 'raster'

module Erx
  # The glyph step (docs/design-desktop-programs.md, "Type"): one Plan 9
  # subfont with an 8-bit grey image (`k8`) per role of the theme, from the
  # coverage erx-raster gives for the role's font, weight and size, written
  # into build/glyphs as ROLE.subfont. Nothing here is checked in.
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

    class Refused < Error; end

    # Glyph i of a subfont, as font(7) records it: its columns start at X of
    # the image, its ink lies in rows TOP to BOTTOM (exclusive), it is drawn
    # LEFT pixels right of the pen and advances it by WIDTH.
    Glyph = Data.define(:x, :top, :bottom, :left, :width)
    # A glyph's entry and the coverage drawn in its columns, nil for an
    # absent glyph.
    Placed = Data.define(:glyph, :coverage)

    # A k8 subfont: an image WIDTH by HEIGHT whose PIXELS are its rows top
    # first, one byte of coverage each, the baseline ASCENT rows down, and
    # GLYPHS in index order.
    Subfont = Data.define(:width, :height, :ascent, :pixels, :glyphs) do
      # The file: the image (image(7)), then the subfont header and the
      # glyph table with its closing entry, which gives only the end of the
      # last glyph's columns (font(7)).
      def encode
        header = [CHANNEL, 0, 0, width, height].map { |word| Glyphs.field(word) }.join
        table = [height, ascent].map { |word| Glyphs.field(word) }.join
        entries = [*glyphs, Glyph.new(x: width, top: 0, bottom: 0, left: 0, width: 0)].map do |glyph|
          [glyph.x, glyph.top, glyph.bottom, glyph.left, glyph.width].pack('vCCcC')
        end
        header + pixels + Glyphs.field(glyphs.size) + table + entries.join
      end
    end

    module_function

    def field(word) = "#{word.to_s.rjust(FIELD)} "

    # The theme of the tree at root.
    def theme(root:)
      source = File.read(File.join(root, ABI::Theme::SOURCE))
      ABI::Theme.validate(ABI::Syntax.parse(source, path: ABI::Theme::SOURCE).select { |item| item.kind == 'theme' })
    end

    # Writes every role's subfont of theme into OUTPUT beneath output_root and
    # returns their paths by role name. Font paths in the theme are beneath root.
    def write(root:, program:, runner:, theme: Glyphs.theme(root: root), output_root: root)
      subfonts = theme.roles.transform_values do |role|
        font = theme.fonts.fetch(role.font)
        asked = requests(role, font)
        result = program.rasterise(font: File.join(root, font.directory, font.files.fetch(role.weight)),
                                   size: role.size, glyphs: asked, runner: runner)
        subfont(role, requests: asked, result: result)
      end
      publish(subfonts, output_root: output_root)
    end

    # The subfonts in a new directory beside OUTPUT, which then replaces it
    # whole; returns each file's final path by role name.
    def publish(subfonts, output_root:)
      parent = OutputDirectory.prepare(root: output_root, path: File.join(output_root, File.dirname(OUTPUT)))
      destination = File.join(output_root, OUTPUT)
      raise Error, "glyph output is a symbolic link: #{destination}" if File.symlink?(destination)

      Dir.mktmpdir('.glyphs-', parent) do |work|
        fresh = File.join(work, 'glyphs')
        Dir.mkdir(fresh)
        subfonts.each { |name, subfont| File.binwrite(File.join(fresh, "#{name}#{EXTENSION}"), subfont.encode) }
        File.rename(destination, File.join(work, 'previous')) if File.exist?(destination)
        File.rename(fresh, destination)
      end
      subfonts.to_h { |name, _| [name, File.join(destination, "#{name}#{EXTENSION}")] }
    end

    # What erx-raster is asked for, for each code point of the font's ranges
    # in order: the character, or for a tabular role's digit, the digit's
    # tabular glyph by name.
    def requests(role, font)
      font.ranges.flat_map { |low, high| (low..high).to_a }.map do |point|
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
                  glyphs: placed.map(&:glyph).freeze)
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
