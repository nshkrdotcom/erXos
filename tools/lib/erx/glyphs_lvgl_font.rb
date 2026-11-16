# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module Glyphs
    # A role's LVGL font (docs/design-desktop-programs.md, "Type" and
    # "Kerning"): the role's subfont written a third time, as C source of
    # LVGL's built-in font format (display/lvgl/lvgl,
    # include/lvgl/font/lv_font_fmt_txt.h), so LVGL draws the same glyphs at
    # the same places as the subfont's readers.
    #
    # The subfont's drawn glyphs, those of width other than 0, become LVGL's
    # glyphs 1 to n in subfont order; LVGL reserves glyph 0 for "none". A
    # glyph's bitmap is its coverage, 8 bits a pixel, its rows packed with no
    # padding. Each range of the role's font is one character map that names
    # only the drawn glyphs, so a character the subfont lacks is one LVGL
    # lacks too: a range drawn whole maps by offset, any other lists its drawn
    # characters.
    #
    # The pairs are LVGL's pair table in the subfont's order, its glyph ids
    # 16-bit, which the renumbering keeps ascending. Each advance is written
    # as its whole pixels times 16, and the kern scale is 256, so LVGL's
    # advance, (16 width + (k 256 >> 4) + 8) >> 4
    # (src/font/fmt_txt/lv_font_fmt_txt.c, lines 239-256), is width + k
    # exactly.
    module LvglFont
      PREFIX = 'erx_lvgl_font_'
      KERN_SCALE = 256
      SIXTEENTHS = 16
      BPP = 8
      # The limits of lv_font_fmt_txt_glyph_dsc_t without LV_FONT_FMT_TXT_LARGE
      # (lv_font_fmt_txt.h): a 20-bit bitmap index, an 8-bit box and offsets;
      # and of lv_font_fmt_txt_cmap_t and the 16-bit pair table: 16-bit glyph
      # ids and range lengths. A box's height, its x offset and the 12-bit
      # advance in sixteenths need no check: the subfont's ROW, LEFT and
      # ADVANCE (Glyphs) already hold them within these.
      BITMAP_INDEX = 0...(1 << 20)
      BOX = 0..255
      OFFSET = -128..127
      ID = 1..0xffff
      RANGE_LENGTH = 1..0xffff
      # Numbers, and pairs of glyph ids, per line of the source.
      PER_LINE = 16
      PAIRS_PER_LINE = 6
      # The characters whose ink tops give the cap height and the x-height.
      CAP = 0x48
      X = 0x78

      # A drawn glyph: its subfont glyph's index GLYPH and its character POINT,
      # its ink's columns from X and rows from TOP, WIDTH by HEIGHT (0 by 0
      # without ink), drawn LEFT pixels right of the pen, which then advances
      # ADVANCE pixels, and INDEX, where its ink starts in the bitmap.
      Box = Data.define(:glyph, :point, :x, :top, :width, :height, :left, :advance, :index)
      # A character map: its entry in cmaps, and the C array listing its
      # characters, nil for a range drawn whole.
      Cmap = Data.define(:entry, :list)

      module_function

      def symbol(role_name) = "#{PREFIX}#{role_name}"
      def file(role_name) = "#{symbol(role_name)}.c"

      # The C source of ROLE's font from SUBFONT, whose glyph i is the i-th
      # code point of RANGES; SOURCES names the files it was rasterised from
      # and NOTICE (Glyphs::FontNotice) the font they derive from.
      def c_source(subfont, role:, ranges:, sources:, notice:)
        boxes = boxes(subfont, role: role, points: ranges.flat_map { |low, high| (low..high).to_a })
        Glyphs.refuse(role, 'it has no drawn glyph') if boxes.empty?
        Glyphs.refuse(role, "its #{boxes.size} glyphs pass LVGL's 16-bit glyph ids") unless ID.cover?(boxes.size)
        ids = boxes.each_with_index.to_h { |box, rank| [box.glyph, rank + 1] }
        maps = cmaps(role, ranges: ranges, drawn: boxes.to_h { |box| [box.point, ids.fetch(box.glyph)] })
        <<~C
          /*
          #{Glyphs.header(notice, generator: LvglFont.name, sources: sources).map { |line| " * #{line}" }.join("\n")}
           *
           * The theme's #{role.name} role in LVGL's built-in font format.
           * Glyphs: #{boxes.size}, the subfont's drawn glyphs in its order, 8-bit coverage.
           * Kerning pairs: #{subfont.pairs.size}, the subfont's.
           * Each advance is in sixteenths of a pixel and the kern scale is #{KERN_SCALE},
           * so a kerned advance is the glyph's width plus the pair's adjustment in
           * whole pixels (docs/design-desktop-programs.md, "Kerning").
           */

          #include "lvgl.h"

          static const uint8_t glyph_bitmap[] = {
          #{bitmap(subfont, boxes)}
          };

          /* Glyph 0 is LVGL's "no glyph". */
          static const lv_font_fmt_txt_glyph_dsc_t glyph_dsc[] = {
              { .bitmap_index = 0, .adv_w = 0, .box_w = 0, .box_h = 0, .ofs_x = 0, .ofs_y = 0 },
          #{boxes.map { |box| descriptor(role, box, ascent: subfont.ascent) }.join(",\n")}
          };

          #{maps.filter_map(&:list).join("\n")}
          static const lv_font_fmt_txt_cmap_t cmaps[] = {
          #{maps.map(&:entry).join(",\n")}
          };

          #{kerning(subfont.pairs, ids)}
          static const lv_font_fmt_txt_dsc_t font_dsc = {
              .glyph_bitmap = glyph_bitmap,
              .glyph_dsc = glyph_dsc,
              .cmaps = cmaps,
              .kern_dsc = #{subfont.pairs.empty? ? 'NULL' : '&kern_pairs'},
              .kern_scale = #{KERN_SCALE},
              .cmap_num = #{maps.size},
              .bpp = #{BPP},
              .kern_classes = 0,
              .bitmap_format = LV_FONT_FMT_TXT_PLAIN,
              .stride = 0,
          };

          /*
           * The line is the role's; base_line counts the baseline's rows above the
           * line's bottom. The font gives no underline, so LVGL draws its default.
           */
          const lv_font_t #{symbol(role.name)} = {
              .get_glyph_dsc = lv_font_get_glyph_dsc_fmt_txt,
              .get_glyph_bitmap = lv_font_get_bitmap_fmt_txt,
              .line_height = #{subfont.height},
              .base_line = #{subfont.height - subfont.ascent},
              .cap_height = #{ink_height(subfont, boxes, CAP)},
              .x_height = #{ink_height(subfont, boxes, X)},
              .subpx = LV_FONT_SUBPX_NONE,
              .kerning = LV_FONT_KERNING_NORMAL,
              .static_bitmap = 1,
              .dsc = &font_dsc,
          };
        C
      end

      # The subfont's drawn glyphs as Boxes, each with its bitmap's index, or
      # Refused when one does not fit LVGL's glyph descriptor. A glyph's
      # columns end where the next glyph's start, or at the image's width.
      def boxes(subfont, role:, points:)
        ends = [*subfont.glyphs.drop(1).map(&:x), subfont.width]
        index = 0
        points.zip(subfont.glyphs, ends).each_with_index.filter_map do |(point, glyph, columns_end), number|
          next if glyph.width.zero?

          rows = glyph.bottom - glyph.top
          width = rows.zero? ? 0 : columns_end - glyph.x
          Glyphs.refuse(role, format('U+%04X is %d columns wide', point, width)) unless BOX.cover?(width)
          box = Box.new(glyph: number, point: point, x: glyph.x, top: glyph.top, width: width,
                        height: width.zero? ? 0 : rows, left: glyph.left, advance: glyph.width, index: index)
          index += box.width * box.height
          Glyphs.refuse(role, "its bitmap of #{index} bytes passes LVGL's 20-bit index") unless BITMAP_INDEX.cover?(index)
          box
        end
      end

      # The bitmap's bytes, each box's rows of the subfont's image in turn; a
      # C array is never empty, so a font without ink holds one 0.
      def bitmap(subfont, boxes)
        bytes = boxes.flat_map do |box|
          (box.top...(box.top + box.height)).flat_map do |row|
            subfont.pixels.byteslice((row * subfont.width) + box.x, box.width).bytes
          end
        end
        lines((bytes.empty? ? [0] : bytes).map { |byte| format('0x%02x', byte) })
      end

      # A box as LVGL's glyph descriptor: its advance in sixteenths, and its
      # bottom row counted up from the baseline (ofs_y), since LVGL draws a
      # box line_height - base_line - box_h - ofs_y rows below the line's top
      # (src/draw/lv_draw_label.c, line 671). A box without ink sits at 0.
      def descriptor(role, box, ascent:)
        rise = box.height.zero? ? 0 : ascent - (box.top + box.height)
        Glyphs.refuse(role, format('U+%04X lies %d rows from the baseline', box.point, rise)) unless OFFSET.cover?(rise)

        format('    /* U+%04X */ { .bitmap_index = %d, .adv_w = %d, .box_w = %d, .box_h = %d, .ofs_x = %d, .ofs_y = %d }',
               box.point, box.index, box.advance * SIXTEENTHS, box.width, box.height, box.left, rise)
      end

      # One character map for each range with a drawn glyph. DRAWN gives each
      # drawn character's glyph id, which ascends with the character.
      def cmaps(role, ranges:, drawn:)
        ranges.each_with_index.filter_map do |(low, high), number|
          length = high - low + 1
          unless RANGE_LENGTH.cover?(length)
            Glyphs.refuse(role, format("its range U+%04X-U+%04X passes LVGL's 16-bit length", low, high))
          end
          points = (low..high).select { |point| drawn.key?(point) }
          next if points.empty?

          start = drawn.fetch(points.first)
          if points.size == length
            Cmap.new(entry: cmap_entry(low: low, length: length, start: start, list: 'NULL', count: 0, type: 'FORMAT0_TINY'),
                     list: nil)
          else
            name = "unicode_list_#{number}"
            Cmap.new(entry: cmap_entry(low: low, length: length, start: start, list: name, count: points.size,
                                       type: 'SPARSE_TINY'),
                     list: "static const uint16_t #{name}[] = {\n#{lines(points.map { |point| point - low })}\n};\n")
          end
        end
      end

      def cmap_entry(low:, length:, start:, list:, count:, type:)
        "    {\n        .range_start = #{low}, .range_length = #{length}, .glyph_id_start = #{start},\n" \
          "        .unicode_list = #{list}, .glyph_id_ofs_list = NULL, .list_length = #{count},\n" \
          "        .type = LV_FONT_FMT_TXT_CMAP_#{type}\n    }"
      end

      # The pair table, the glyph ids two to a pair, or nothing without pairs.
      def kerning(pairs, ids)
        return '' if pairs.empty?

        glyph_ids = pairs.map { |first, second, _| "#{ids.fetch(first)}, #{ids.fetch(second)}" }
        <<~C
          /* Aligned for LVGL, which converts it to a uint32_t pointer. */
          static const _Alignas(uint32_t) uint16_t kern_pair_glyph_ids[] = {
          #{lines(glyph_ids, per_line: PAIRS_PER_LINE)}
          };

          static const int8_t kern_pair_values[] = {
          #{lines(pairs.map(&:last))}
          };

          static const lv_font_fmt_txt_kern_pair_t kern_pairs = {
              .glyph_ids = kern_pair_glyph_ids,
              .values = kern_pair_values,
              .pair_cnt = #{pairs.size},
              .glyph_ids_size = 1,
          };
        C
      end

      # The rows above the baseline that a character's ink reaches, or 0
      # when the role's ranges have no ink for it, which puts LVGL's
      # trim to the cap or x height (src/misc/lv_text_private.h, lines
      # 292-301) at the baseline.
      def ink_height(subfont, boxes, point)
        box = boxes.find { |each| each.point == point && each.height.positive? }
        box ? subfont.ascent - box.top : 0
      end

      # VALUES, PER_LINE to an indented line, the lines separated by commas.
      def lines(values, per_line: PER_LINE) = values.each_slice(per_line).map { |line| "    #{line.join(', ')}" }.join(",\n")

    end
  end
end
