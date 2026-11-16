# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'abi'
require_relative 'bounded_file'

module Erx
  # The desktop's icon set (docs/design-desktop-programs.md, "Icons"), read
  # from the file the theme's `icons` row names (display/icons/icons.txt,
  # whose header comment gives its form) and checked against the closed list
  # of names, the ABI's `ui_icon` enumeration (abi/formats/ui.txt): every
  # name has an icon with a base layer, and no icon has another name. Every
  # point of a path, control points included, lies at least half a stroke
  # inside the grid, so a stroke with round caps and joins stays inside the
  # icon's square at every size.
  #
  # The file is read in its one order, through a cursor over the
  # declaration's rows: the grid and stroke rows, then each `icon NAME` row
  # followed by its layer rows. The reader fails at the first error with an
  # ABI::SchemaError naming the file and line.
  module Icons
    ENUMERATION = 'ui_icon'
    MAX_BYTES = 1 << 20
    LAYERS = %w[base accent].freeze
    # A path's numbers: a whole number of grid units with at most three
    # decimals.
    NUMBER = /\A(?:0|[1-9][0-9]{0,2})(?:\.[0-9]{1,3})?\z/
    # The commands a path takes, and how many numbers each takes.
    ARITY = { 'M' => 2, 'L' => 2, 'C' => 6, 'Z' => 0 }.freeze

    # A segment: a line to the last of its POINTS, or a cubic with two
    # control points before it. A point is a frozen [x, y] in grid units,
    # y downward, as Rationals.
    Segment = Data.define(:kind, :points)
    # A subpath: its START point, its SEGMENTS, and whether Z closed it.
    Subpath = Data.define(:start, :segments, :closed)
    # An icon: its NAME and the subpaths of its BASE and ACCENT layers; an
    # icon without an accent has none.
    Icon = Data.define(:name, :base, :accent)
    # The set: the GRID's side and the STROKE's width in grid units, and the
    # ICONS in the enumeration's value order.
    IconSet = Data.define(:grid, :stroke, :icons)

    # The set the theme's icons row names, beneath root, checked against the
    # tree's ABI.
    def self.read(root:, path:)
      names = names(ABI::Model.validate(ABI::Sources.read(root: root)))
      parse(BoundedFile.read(File.join(root, path), maximum: MAX_BYTES), path: path, names: names)
    end

    # The `ui_icon` names of an ABI schema, in value order.
    def self.names(schema)
      type = schema.types[ENUMERATION]
      raise ABI::SchemaError, "the ABI declares no enum #{ENUMERATION}" unless type.is_a?(ABI::EnumType) && !type.flags

      type.members.sort_by { |_, value| value }.map(&:first)
    end

    # The set in TEXT, its icons in the order of NAMES.
    def self.parse(text, path:, names:)
      declarations = ABI::Syntax.parse(text, path: path)
      raise ABI::SchemaError, "#{path}: expected one `icons 1` declaration" unless declarations.size == 1

      declaration = declarations.first
      declaration.fail!('expected icons 1') unless declaration.kind == 'icons' && declaration.args == ['1']
      Reader.new(declaration, path: path, names: names).set
    end

    # A length in pixels as whole 26.6 units, rounded half up.
    def self.fixed(pixels) = (pixels * 64 + Rational(1, 2)).floor

    # A layer of SET as erx-raster takes it (erx_raster.c, -s): SVG-style
    # commands over whole 26.6 pixel coordinates of a SIZE-pixel square, y
    # upward. Every coordinate lies in 0..SIZE * 64, since the reader keeps
    # every point inside the grid.
    def self.raster_path(set, subpaths, size:)
      raise ArgumentError, "size #{size} is not a positive whole number" unless size.is_a?(Integer) && size.positive?

      point = ->((x, y)) { [x, set.grid - y].map { |value| fixed(value * size / set.grid) }.join(' ') }
      subpaths.map do |subpath|
        segments = subpath.segments.map do |segment|
          "#{segment.kind == :line ? 'L' : 'C'} #{segment.points.map(&point).join(' ')}"
        end
        ["M #{point.call(subpath.start)}", *segments, *('Z' if subpath.closed)].join(' ')
      end.join(' ')
    end

    # The stroke's width at SIZE pixels, in 26.6 pixels.
    def self.raster_width(set, size:) = fixed(set.stroke * size / set.grid)

    # Reads one declaration's rows in order; each method takes the rows it
    # reads off the front and fails at the first row out of place.
    class Reader
      def initialize(declaration, path:, names:)
        @declaration = declaration
        @path = path
        @names = names
        @rows = declaration.members.dup
      end

      def set
        grid = setting('grid')
        stroke = setting('stroke')
        @declaration.fail!('the stroke must be narrower than the grid') unless stroke.positive? && stroke < grid
        @bounds = (stroke / 2)..(grid - stroke / 2)
        found = {}
        until @rows.empty?
          icon = icon_entry
          raise ABI::SchemaError, "#{@path}: icon #{icon.name} appears twice" if found.key?(icon.name)

          found[icon.name] = icon
        end
        check_names(found.keys)
        IconSet.new(grid: grid, stroke: stroke, icons: @names.map { |name| found.fetch(name) }.freeze)
      end

      private

      # The row `NAME VALUE` at the front.
      def setting(name)
        line = take
        line.fail!("expected #{name} NUMBER") unless line.indent == 2 && line.words.size == 2 && line.words.first == name
        number(line, line.words.last)
      end

      # `icon NAME` at indent 2, then its layer rows at indent 4.
      def icon_entry
        head = take
        head.fail!('expected icon NAME') unless head.indent == 2 && head.words.size == 2 && head.words.first == 'icon'
        layers = LAYERS.to_h { |layer| [layer, []] }
        while @rows.first&.indent == 4
          line = take
          line.fail!("expected base or accent PATH, not #{line.words.first}") unless LAYERS.include?(line.words.first)
          layers.fetch(line.words.first).concat(subpaths(line))
        end
        head.fail!("icon #{head.words.last} has no base layer") if layers.fetch('base').empty?
        Icon.new(name: head.words.last, base: layers.fetch('base').freeze, accent: layers.fetch('accent').freeze)
      end

      def check_names(found)
        missing = @names - found
        extra = found - @names
        raise ABI::SchemaError, "#{@path}: no paths for icon #{missing.join(', ')} of #{ENUMERATION}" unless missing.empty?
        raise ABI::SchemaError, "#{@path}: icon #{extra.join(', ')} is not in #{ENUMERATION}" unless extra.empty?
      end

      # The subpaths of one layer row's path data, each starting at an M.
      def subpaths(line)
        words = line.words.drop(1)
        line.fail!('expected a path starting with M') unless words.first == 'M'

        words.slice_before('M').map { |path| subpath(line, path) }
      end

      # One subpath: M x y, then L and C segments, then an optional Z.
      def subpath(line, words)
        commands = words.slice_before { |word| ARITY.key?(word) }.map do |command, *numbers|
          command_points(line, command, numbers)
        end
        (_, (start, *)), *rest = commands
        closed = rest.last&.first == 'Z'
        body = closed ? rest[0...-1] : rest
        line.fail!('a subpath needs a segment after M') if body.empty?
        line.fail!('M and Z only start and end a subpath') unless body.all? { |command, _| %w[L C].include?(command) }

        segments = body.map { |command, points| Segment.new(kind: command == 'L' ? :line : :cubic, points: points) }
        Subpath.new(start: start, segments: segments.freeze, closed: closed)
      end

      # A command and its points, after one check of its numbers.
      def command_points(line, command, numbers)
        unknown = numbers.find { |word| !NUMBER.match?(word) }
        line.fail!("#{unknown} is neither a command nor a number of grid units") if unknown
        line.fail!("#{command} takes #{ARITY.fetch(command)} numbers") unless numbers.size == ARITY.fetch(command)

        points = numbers.map { |word| number(line, word) }.each_slice(2).map(&:freeze)
        points.flatten.each do |value|
          line.fail!("#{value.to_f} lies outside the grid less half a stroke") unless @bounds.cover?(value)
        end
        [command, points.freeze]
      end

      def number(line, word)
        line.fail!("#{word} is not a number of grid units") unless NUMBER.match?(word)
        Rational(word)
      end

      # The next row, refused when any of its words is quoted, since no word
      # of this file is a string.
      def take
        line = @rows.shift || @declaration.fail!('the declaration ends before its grid, stroke and icons')
        line.fail!('a word of an icon file is never quoted') if line.tokens.any?(&:quoted)
        line
      end
    end
    private_constant :Reader
  end
end
