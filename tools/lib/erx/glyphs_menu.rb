# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module Glyphs
    # The window menu's glyphs (docs/design-desktop-programs.md, "Windows and
    # the window manager", and Decisions, 8): the menu role's subfont written a
    # second time as an Erlang module, so the display release holds its glyphs
    # as data and no font file or font reader. The module gives the subfont's
    # image size, its baseline, its pixels as erx_memdraw:load/3 takes a k8
    # image's rows, each character's glyph as the rectangle of the image
    # that is its mask, and the subfont's pairs by character ("Kerning").
    module Menu
      ROLE = 'body'
      MODULE = 'erx_menu_glyphs'
      FILE = "#{MODULE}.erl"
      # Pixel bytes per binary segment, so each line of the module stays short.
      CHUNK = 32

      module_function

      # The module's source for SUBFONT, whose glyph i is the character
      # CODE_POINTS[i]; SOURCES names the files it was rasterised from and
      # NOTICE (Glyphs::FontNotice) the font they derive from.
      def erlang(subfont, code_points:, sources:, notice:)
        rows = "#{ROW.min}..#{ROW.max}"
        <<~ERLANG
          #{Glyphs.header(notice, generator: Menu.name, sources: sources).map { |line| "%% #{line}" }.join("\n")}

          -module(#{MODULE}).
          -moduledoc """
          The theme's #{ROLE} role as the window menu draws it
          (docs/design-desktop-programs.md, "Windows and the window manager"):
          an 8-bit grey (k8) image of every glyph's coverage and each glyph's
          place in it. The menu loads pixels/0 into an image of size/0 with
          erx_memdraw:load/3 and draws a glyph's rectangle of that image as the
          mask of its colour, with the rectangle's left edge `left` pixels
          right of the pen and its rows placed so that row ascent/0 of the
          image lies on the baseline; the pen then moves `advance` pixels,
          plus kern/2 of the glyph and the next, by erx_pen's rule
          ("Kerning").
          """.

          -export([role/0, size/0, ascent/0, pixels/0, glyph/1, kern/2]).
          -export_type([glyph/0]).

          -doc """
          A glyph: R, its columns and ink rows in the image (empty for a glyph
          without ink, such as a space), drawn LEFT pixels right of the pen,
          which then advances ADVANCE pixels, never 0.
          """.
          -type glyph() :: \#{r := {0..#{MAX_X}, #{rows}, 0..#{MAX_X}, #{rows}}, left := #{LEFT.min}..#{LEFT.max},
                              advance := 1..#{ADVANCE.max}}.

          -doc "The theme role these glyphs are, whose colour the menu draws them in.".
          -spec role() -> erx_theme:role_name().
          role() -> #{ROLE}.

          -doc "The image's width and height; the height is the role's line.".
          -spec size() -> {pos_integer(), pos_integer()}.
          size() -> {#{subfont.width}, #{subfont.height}}.

          -doc "The baseline's row of the image.".
          -spec ascent() -> #{rows}.
          ascent() -> #{subfont.ascent}.

          -doc "The image's rows, top first, one byte of coverage a pixel.".
          -spec pixels() -> binary().
          pixels() ->
              <<#{segments(subfont.pixels).join(",\n      ")}>>.

          -doc "A character's glyph, or none when the font or the theme's ranges have none.".
          -spec glyph(char()) -> glyph() | none.
          #{clauses(subfont, code_points).join(";\n")}.

          -doc "The adjustment of a character's advance when another follows it, 0 where no pair names the two.".
          -spec kern(char(), char()) -> #{ADJUSTMENT.min}..#{ADJUSTMENT.max}.
          #{kern_clauses(subfont, code_points).join(";\n")}.
        ERLANG
      end

      # One clause a pair of the subfont, its glyph indices taken to their
      # characters, then the clause of every other two characters.
      def kern_clauses(subfont, code_points)
        subfont.pairs.map do |first, second, adjustment|
          format('kern(16#%04X, 16#%04X) -> %d', code_points.fetch(first), code_points.fetch(second), adjustment)
        end + ['kern(_, _) -> 0']
      end

      # The pixels as binary segments of CHUNK bytes, the last one shorter.
      def segments(pixels)
        pixels.bytes.each_slice(CHUNK).map do |chunk|
          value = chunk.all?(&:zero?) ? '0' : "16##{chunk.map { |byte| format('%02X', byte) }.join}"
          "#{value}:#{chunk.size}/unit:8"
        end
      end

      # One clause a glyph, then the clause of every other character; a glyph of width 0, which a Plan 9 font reader
      # takes as missing (Glyphs, the module comment), takes the last clause
      # as a character outside the ranges does, so the menu and the subfont's
      # readers lack the same characters. A glyph's columns end where the
      # next glyph's start, or at the image's width.
      def clauses(subfont, code_points)
        ends = [*subfont.glyphs.drop(1).map(&:x), subfont.width]
        code_points.zip(subfont.glyphs, ends).filter_map do |point, glyph, last|
          next if glyph.width.zero?

          format("glyph(16#%04X) ->\n    \#{r => {%d, %d, %d, %d}, left => %d, advance => %d}",
                 point, glyph.x, glyph.top, last, glyph.bottom, glyph.left, glyph.width)
        end + ["glyph(_) ->\n    none"]
      end
    end
  end
end
