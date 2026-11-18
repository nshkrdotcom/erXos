# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'error'
require_relative 'bounded_file'
require_relative 'generation_plan'

module Erx
  # The splash's mark (docs/design-display.md, "The splash"): the erXos
  # wordmark of erxos-logo.svg, rasterised at build time into an 8-bit
  # coverage mask MARK_WIDTH pixels wide and written as the generated Erlang
  # module erx_splash_mark, which erx_screen draws in the theme's `text`
  # colour while the display has shown no window. The screen therefore holds
  # the mark as data, a few tens of KiB, and never draws a picture at run
  # time.
  #
  # The logo is one path filled with the even-odd rule, in absolute M, L, C
  # and Z commands, a command's numbers repeating it as SVG allows; any other
  # form is refused. The mask is the path's bounding box scaled to
  # MARK_WIDTH, each pixel's coverage measured on SUBROWS rows through it,
  # each row's covered length exact.
  module SplashMark
    SOURCE = 'erxos-logo.svg'
    OUTPUT = 'erlang/apps/erx_display/src/erx_splash_mark.erl'
    MAX_SOURCE_BYTES = 65_536
    MARK_WIDTH = 384
    # The tallest mask, in widths: a taller one is a malformed source.
    MAX_ASPECT = 4
    SUBROWS = 16
    # Straight pieces a cubic is flattened into.
    CUBIC_STEPS = 16
    # Pixel bytes per binary segment, so each line of the module stays short.
    CHUNK = 32
    # Numbers each command takes.
    ARITY = { 'M' => 2, 'L' => 2, 'C' => 6, 'Z' => 0 }.freeze
    # A command letter or a number.
    TOKEN = /[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)/

    class MarkError < Error; end

    # An edge of the flattened outline, from [x0, y0] to [x1, y1].
    Edge = Data.define(:x0, :y0, :x1, :y1)
    # The mask: its width and height and its rows, top first, a byte a pixel.
    Mask = Data.define(:width, :height, :pixels)

    module_function

    def generation(root:)
      text = BoundedFile.read(File.join(root, SOURCE), maximum: MAX_SOURCE_BYTES)
      GenerationPlan.new(files: { OUTPUT => erlang(rasterise(outline(text))).freeze },
                         reads: { SOURCE => Digest::SHA256.hexdigest(text) }, globs: {})
    end

    # The logo's one path as closed polygons of [x, y] points, in its units.
    def outline(text)
      paths = text.scan(/<path\b[^>]*>/)
      raise MarkError, "#{SOURCE}: #{paths.size} paths, not one" unless paths.size == 1
      raise MarkError, "#{SOURCE}: the path is not filled even-odd" unless paths.first.include?('fill-rule="evenodd"')

      data = paths.first[/\sd="([^"]*)"/, 1]
      raise MarkError, "#{SOURCE}: the path has no data" if data.nil?

      tokens = data.scan(TOKEN)
      raise MarkError, "#{SOURCE}: the path data holds more than commands and numbers" unless data.gsub(TOKEN, '').match?(/\A[\s,]*\z/)
      polygons(tokens)
    end

    # Walks the tokens through a cursor; a command's numbers may repeat it.
    # As SVG's closepath says, a subpath that follows Z without a moveto
    # starts at the closed subpath's first point.
    def polygons(tokens)
      cursor = 0
      command = nil
      done = []
      current = []
      while cursor < tokens.size
        if tokens[cursor].match?(/[A-Za-z]/)
          command = tokens[cursor]
          cursor += 1
          raise MarkError, "#{SOURCE}: command #{command} is not one of #{ARITY.keys.join(' ')}" unless ARITY.key?(command)
        end
        raise MarkError, "#{SOURCE}: numbers with no command" if command.nil?

        arity = ARITY.fetch(command)
        numbers = tokens[cursor, arity]
        unless numbers.size == arity && numbers.none? { |token| token.match?(/[A-Za-z]/) }
          raise MarkError, "#{SOURCE}: command #{command} lacks its numbers"
        end

        cursor += arity
        points = numbers.map(&:to_f).each_slice(2).to_a
        raise MarkError, "#{SOURCE}: a number too large for a coordinate" unless points.flatten.all?(&:finite?)
        case command
        when 'M'
          done << current
          current = [points.first]
          command = 'L'
        when 'L', 'C'
          raise MarkError, "#{SOURCE}: #{command} before a moveto" if current.empty?

          command == 'L' ? current << points.first : current.concat(cubic(current.last, *points))
        when 'Z'
          raise MarkError, "#{SOURCE}: Z before a moveto" if current.empty?

          done << current
          current = [current.first]
          command = nil
        end
      end
      # A lone moveto, or the start a final Z leaves, bounds no area.
      (done + [current]).select { |polygon| polygon.size > 1 }
    end

    def cubic(start, first, second, last)
      (1..CUBIC_STEPS).map do |step|
        t = step.fdiv(CUBIC_STEPS)
        u = 1 - t
        weights = [u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t]
        [0, 1].map { |axis| [start, first, second, last].zip(weights).sum { |point, weight| point[axis] * weight } }
      end
    end

    # The polygons scaled so their bounding box is WIDTH pixels wide, filled
    # even-odd.
    def rasterise(polygons, width: MARK_WIDTH)
      xs, ys = polygons.flatten(1).transpose
      raise MarkError, "#{SOURCE}: the path encloses no area" if xs.nil? || xs.max == xs.min || ys.max == ys.min

      scale = width.fdiv(xs.max - xs.min)
      height = ((ys.max - ys.min) * scale).ceil
      raise MarkError, "#{SOURCE}: the mark is more than #{MAX_ASPECT} times as tall as wide" if height > MAX_ASPECT * width
      edges = polygons.flat_map do |polygon|
        placed = polygon.map { |x, y| [(x - xs.min) * scale, (y - ys.min) * scale] }
        placed.zip(placed.rotate).filter_map { |(x0, y0), (x1, y1)| Edge.new(x0:, y0:, x1:, y1:) unless y0 == y1 }
      end
      rows = (0...height).map do |row|
        coverage_row(row, edges.select { |e| [e.y0, e.y1].min < row + 1 && [e.y0, e.y1].max > row }, width:)
      end
      Mask.new(width:, height:, pixels: rows.join.b)
    end

    # One row of the mask as bytes: the even-odd spans of each of its
    # SUBROWS lines, each line's covered length added to its pixels.
    def coverage_row(row, edges, width:)
      cover = Array.new(width, 0.0)
      SUBROWS.times do |sub|
        y = row + (sub + 0.5) / SUBROWS
        crossings = edges.filter_map do |e|
          low, high = [e.y0, e.y1].minmax
          e.x0 + (y - e.y0) * (e.x1 - e.x0) / (e.y1 - e.y0) if y >= low && y < high
        end
        crossings.sort.each_slice(2) { |from, to| add_span(cover, from, to) if to }
      end
      cover.map { |sum| (sum / SUBROWS * 255).round.clamp(0, 255) }.pack('C*')
    end

    def add_span(cover, from, to)
      from = from.clamp(0.0, cover.size.to_f)
      to = to.clamp(0.0, cover.size.to_f)
      (from.floor...to.ceil).each do |pixel|
        cover[pixel] += [to, pixel + 1].min - [from, pixel].max
      end
    end

    def erlang(mask)
      segments = mask.pixels.bytes.each_slice(CHUNK).map do |chunk|
        value = chunk.all?(&:zero?) ? '0' : "16##{chunk.map { |byte| format('%02X', byte) }.join}"
        "#{value}:#{chunk.size}/unit:8"
      end
      <<~ERLANG
        %% Generated by tools/lib/erx/splash_mark.rb from #{SOURCE}; do not edit.

        -module(erx_splash_mark).
        -moduledoc """
        The splash's mark (docs/design-display.md, "The splash"): the erXos
        wordmark as an 8-bit grey (k8) coverage mask, which erx_memdraw:load/3
        takes as an image of size/0 and erx_screen draws a colour through.
        """.

        -export([size/0, pixels/0]).

        -doc "The mask's width and height.".
        -spec size() -> {pos_integer(), pos_integer()}.
        size() -> {#{mask.width}, #{mask.height}}.

        -doc "The mask's rows, top first, one byte of coverage a pixel.".
        -spec pixels() -> binary().
        pixels() ->
            <<#{segments.join(",\n      ")}>>.
      ERLANG
    end
  end
end
