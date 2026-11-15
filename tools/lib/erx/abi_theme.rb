# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_source'

module Erx
  module ABI
    # A font: its directory beneath the repository root, the file of each
    # weight it has, in Theme::WEIGHTS order, and RANGES, the code points the
    # glyph step rasterises from it as [LOW, HIGH] pairs, ascending and
    # disjoint.
    ThemeFont = Data.define(:name, :directory, :files, :ranges)
    # A type role: SIZE and LINE are pixels, WEIGHT a key of Theme::WEIGHTS,
    # FIGURES one of Theme::FIGURES and COLOR a declared colour's name.
    ThemeRole = Data.define(:name, :font, :size, :line, :weight, :figures, :color)
    # A shadow: X, Y and BLUR are pixels, PERCENT the opacity of its black.
    ThemeShadow = Data.define(:name, :x, :y, :blur, :percent)
    # A contrast rule: FOREGROUND meets RATIO, a Rational, on each of
    # BACKGROUNDS.
    ThemeContrast = Data.define(:foreground, :backgrounds, :ratio)
    # The icons' definition file and the pixel sizes, ascending.
    ThemeIcons = Data.define(:path, :sizes)
    # The validated theme. UNIT and HAIRLINE are pixels; FONTS, ROLES,
    # SHADOWS and COLORS (each an Integer 0xRRGGBB) are frozen hashes by
    # name, and SPACES (in units) and RADII (in pixels) frozen hashes of
    # integers by name, each sorted by name, so no output depends on the
    # order of the rows; CONTRASTS keep the declared order.
    ThemeSchema = Data.define(:version, :unit, :hairline, :fonts, :roles, :spaces, :radii, :shadows,
                              :colors, :contrasts, :icons) do
      def space_pixels(name) = spaces.fetch(name) * unit
    end

    # The reader of the one `theme VERSION` declaration (docs/design-abi.md,
    # "Theme"). It refuses every source the grammar refuses, checks every
    # contrast rule, and returns a frozen theme with every reference
    # resolved.
    module Theme
      SOURCE = 'abi/theme.txt'
      NAME = /\A[a-z][a-z0-9_]{0,62}\z/.freeze
      # A relative path beneath the root: no segment starts with a dot, so
      # none is `..`.
      PATH = %r{\A[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_][A-Za-z0-9_.-]*)*\z}.freeze
      FONT_FILE = /\A[A-Za-z0-9_][A-Za-z0-9_.-]*\.ttf\z/.freeze
      COLOR = /\A[0-9A-F]{6}\z/.freeze
      CODE_RANGE = /\A([0-9A-F]{4,6})-([0-9A-F]{4,6})\z/.freeze
      RATIO = /\A(?:[1-9]|1[0-9]|2[01])\.[0-9]\z/.freeze
      # The weights a font has and a role takes, each with the numeric weight
      # CSS gives its name: CSS Fonts Module Level 3, W3C Recommendation 20
      # September 2018, section 3.2, "font-weight"
      # (https://www.w3.org/TR/2018/REC-css-fonts-3-20180920/).
      WEIGHTS = { 'regular' => 400, 'medium' => 500, 'semibold' => 600 }.freeze
      FIGURES = %w[proportional tabular].freeze
      ROLE_KEYS = %w[font size line weight figures color].freeze
      REQUIRED_ROLE_KEYS = %w[font size line weight].freeze
      # The colour of a role that names none.
      ROLE_COLOR = 'text'
      MEMBERS = %w[unit hairline font range role space radius shadow color contrast icons].freeze
      SINGLETONS = %w[unit hairline space radius icons].freeze
      # The families every theme has at least one row of, so no generated
      # type or function is empty.
      PRESENT = %w[font role color shadow].freeze
      PIXELS = 0..4096
      OFFSETS = -4096..4096
      PERCENT = 0..100
      CODE_POINTS = 0..0x10ffff
      CONTRAST = 1..21

      module_function

      def validate(declarations)
        return nil if declarations.empty?

        declarations.drop(1).first&.fail!('exactly one theme declaration is allowed')
        declaration = declarations.first
        declaration.fail!("the theme declaration belongs in #{SOURCE}") unless declaration.line.path == SOURCE
        declaration.fail!('expected theme VERSION') unless declaration.line.tokens.size == 2
        version = Syntax.integer(declaration.args.first, line: declaration.line)
        declaration.fail!('theme version must be positive and fit 32 bits') unless version.between?(1, 0xffffffff)
        Reader.new(declaration).schema(version)
      end

      # WCAG 2's contrast ratio of two sRGB colours, each 0xRRGGBB:
      # (L1 + 0.05) / (L2 + 0.05), L1 the relative luminance of the lighter
      # colour and L2 that of the darker, from 1 to 21. WCAG 2.2, W3C
      # Recommendation 12 December 2024
      # (https://www.w3.org/TR/2024/REC-WCAG22-20241212/), the definitions
      # of "contrast ratio" and "relative luminance".
      def contrast_ratio(first, second)
        darker, lighter = [first, second].map { |color| luminance(color) }.minmax
        (lighter + 0.05) / (darker + 0.05)
      end

      # The relative luminance of an sRGB colour, by the same definition.
      def luminance(color)
        red, green, blue = [16, 8, 0].map { |shift| linear(((color >> shift) & 0xff) / 255.0) }
        (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
      end

      def linear(channel) = channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055)**2.4

      # Validation of one declaration's rows: each family resolved against
      # the ones it refers to, failing at the first refusal with the row's
      # place.
      class Reader
        def initialize(declaration)
          declaration.members.each do |line|
            line.fail!('a theme member takes two-space indentation') unless line.indent == 2
            line.fail!("unknown theme member #{line.words.first}") unless MEMBERS.include?(line.words.first)
            # A quoted token's escapes could spell a name, which the lexer keeps out of identifiers.
            line.fail!('a theme row takes no quoted token') if line.tokens.any?(&:quoted)
          end
          @rows = declaration.members.group_by { |line| line.words.first }
          SINGLETONS.each do |member|
            declaration.fail!("the theme needs one #{member} row") unless rows(member).size == 1
          end
          PRESENT.each { |member| declaration.fail!("the theme needs a #{member} row") if rows(member).empty? }
        end

        def schema(version)
          unit = single_integer('unit')
          hairline = single_integer('hairline')
          colors = declare_each('color') { |line| color(line) }
          fonts = fonts_with_ranges
          ThemeSchema.new(
            version: version, unit: unit, hairline: hairline, fonts: fonts,
            roles: declare_each('role') { |line| role(line, fonts: fonts, colors: colors, unit: unit) },
            spaces: scale(single('space'), 1..(PIXELS.max / unit), 'space'),
            radii: radii, shadows: declare_each('shadow') { |line| shadow(line) },
            colors: colors, contrasts: rows('contrast').map { |line| contrast(line, colors) }.freeze,
            icons: icons(single('icons'))
          )
        end

        private

        def rows(member) = @rows.fetch(member, [])
        def single(member) = rows(member).first

        # Each row of a member family, by its name, sorted by name; a name
        # given twice is refused.
        def declare_each(member)
          rows(member).each_with_object({}) do |line, values|
            name = name(line, line.words[1])
            line.fail!("#{member} #{name} is declared twice") if values.key?(name)
            values[name] = yield(line)
          end.sort.to_h.freeze
        end

        def name(line, word)
          line.fail!("invalid theme name #{word.inspect}") unless word&.match?(NAME)
          word
        end

        # The one row MEMBER VALUE, VALUE a positive number of pixels.
        def single_integer(member)
          line = single(member)
          line.fail!("expected #{member} PIXELS") unless line.words.size == 2
          integer(line, line.words[1], 1..PIXELS.max, member)
        end

        def integer(line, word, range, what)
          value = Syntax.integer(word, line: line)
          line.fail!("#{what} must lie in #{range.min}..#{range.max}") unless range.cover?(value)
          value
        end

        def color(line)
          line.fail!('expected color NAME RRGGBB') unless line.words.size == 3
          line.fail!("colour #{line.words[1]} is not six upper-case hexadecimal digits") unless line.words[2].match?(COLOR)
          line.words[2].to_i(16)
        end

        # The fonts, each with the one range row that names it.
        def fonts_with_ranges
          ranges = declare_each('range') { |line| code_ranges(line) }
          fonts = declare_each('font') do |line|
            name = line.words[1]
            line.fail!("font #{name} has no range row") unless ranges.key?(name)
            ThemeFont.new(name: name, directory: path(line, line.words[2]), files: font_files(line),
                          ranges: ranges.fetch(name))
          end
          stray = ranges.keys.find { |name| !fonts.key?(name) }
          rows('range').find { |line| line.words[1] == stray }.fail!("range names an undeclared font #{stray}") if stray
          fonts
        end

        def font_files(line)
          pairs = line.words.drop(3)
          line.fail!('expected font NAME DIRECTORY WEIGHT FILE...') if pairs.empty? || pairs.size.odd?
          files = pairs.each_slice(2).each_with_object({}) do |(weight, file), seen|
            line.fail!("font weight #{weight} is not one of #{WEIGHTS.keys.join(', ')}") unless WEIGHTS.key?(weight)
            line.fail!("font weight #{weight} is given twice") if seen.key?(weight)
            line.fail!("font file #{file.inspect} is not a .ttf file name") unless file.match?(FONT_FILE)
            seen[weight] = file
          end
          WEIGHTS.keys.select { |weight| files.key?(weight) }.to_h { |weight| [weight, files.fetch(weight)] }.freeze
        end

        def code_ranges(line)
          words = line.words.drop(2)
          line.fail!('expected range FONT LOW-HIGH...') if words.empty?
          words.each_with_object([]) do |word, ranges|
            match = CODE_RANGE.match(word) || line.fail!("code range #{word} is not LOW-HIGH in upper-case hexadecimal")
            low, high = match.captures.map { |digits| digits.to_i(16) }
            line.fail!("code range #{word} is empty or beyond U+10FFFF") unless low <= high && CODE_POINTS.cover?(high)
            line.fail!("code range #{word} does not follow the one before it") if ranges.any? && low <= ranges.last.last
            ranges << [low, high].freeze
          end.freeze
        end

        def path(line, word)
          line.fail!("path #{word.inspect} is not a relative path beneath the root") unless word&.match?(PATH)
          word
        end

        def role(line, fonts:, colors:, unit:)
          given = role_keys(line)
          font =fonts[given.fetch('font')] || line.fail!("role names an undeclared font #{given.fetch('font')}")
          weight = given.fetch('weight')
          line.fail!("font #{font.name} has no weight #{weight}") unless font.files.key?(weight)
          line_height = integer(line, given.fetch('line'), 1..PIXELS.max, 'line')
          line.fail!("line #{line_height} is not a multiple of the unit #{unit}") unless (line_height % unit).zero?
          figures = given.fetch('figures', FIGURES.first)
          line.fail!("figures #{figures} is not one of #{FIGURES.join(', ')}") unless FIGURES.include?(figures)
          color = given.fetch('color', ROLE_COLOR)
          line.fail!("role takes the undeclared colour #{color}") unless colors.key?(color)
          ThemeRole.new(name: line.words[1], font: font.name, size: integer(line, given.fetch('size'), 1..PIXELS.max, 'size'),
                        line: line_height, weight: weight, figures: figures, color: color)
        end

# A role row's values by key, each key known, given once, and the
# required ones present.
def role_keys(line)
  pairs = line.words.drop(2)
  line.fail!('expected role NAME KEY VALUE...') if pairs.size.odd?
  given = pairs.each_slice(2).each_with_object({}) do |(key, value), seen|
    line.fail!("role key #{key} is not one of #{ROLE_KEYS.join(', ')}") unless ROLE_KEYS.include?(key)
    line.fail!("role key #{key} is given twice") if seen.key?(key)
    seen[key] = value
  end
  missing = REQUIRED_ROLE_KEYS.find { |key| !given.key?(key) }
  line.fail!("role needs #{missing}") if missing
  given
end

# A row of NAME VALUE pairs, by name, sorted by name.
        def scale(line, range, what)
          pairs = line.words.drop(1)
          line.fail!("expected #{what} NAME VALUE...") if pairs.empty? || pairs.size.odd?
          pairs.each_slice(2).each_with_object({}) do |(name, value), values|
            name(line, name)
            line.fail!("#{what} #{name} is given twice") if values.key?(name)
            values[name] = integer(line, value, range, "#{what} #{name}")
          end.sort.to_h.freeze
        end

        # Windows are square (docs/design-desktop-programs.md, "Windows and
        # the window manager"), so the radius `window` is declared and 0.
        def radii
          line = single('radius')
          scale(line, PIXELS, 'radius').tap do |values|
            line.fail!('radius window must be declared and 0') unless values['window']&.zero?
          end
        end

        def shadow(line)
          line.fail!('expected shadow NAME X Y BLUR PERCENT') unless line.words.size == 6
          x, y, blur, percent = line.words.drop(2)
          ThemeShadow.new(name: line.words[1], x: integer(line, x, OFFSETS, 'shadow x'),
                          y: integer(line, y, OFFSETS, 'shadow y'), blur: integer(line, blur, PIXELS, 'shadow blur'),
                          percent: integer(line, percent, PERCENT, 'shadow percent'))
        end

        # A contrast row, checked: the foreground meets the ratio on every
        # background it names.
        def contrast(line, colors)
          foreground, on, *backgrounds, ratio_text = line.words.drop(1)
          line.fail!('expected contrast FOREGROUND on BACKGROUND... RATIO') unless on == 'on' && backgrounds.any?
          ratio = ratio(line, ratio_text)
          [foreground, *backgrounds].each do |name|
            line.fail!("contrast names an undeclared colour #{name}") unless colors.key?(name)
          end
          backgrounds.each do |background|
            measured = Theme.contrast_ratio(colors.fetch(foreground), colors.fetch(background))
            next if measured >= ratio

            line.fail!(format('contrast %<fg>s on %<bg>s is %<measured>.2f, below %<ratio>s',
                              fg: foreground, bg: background, measured: measured, ratio: ratio_text))
          end
          ThemeContrast.new(foreground: foreground, backgrounds: backgrounds.freeze, ratio: ratio)
        end

        def ratio(line, text)
          ratio = text&.match?(RATIO) ? Rational(text) : nil
          line.fail!("contrast ratio #{text.inspect} is not a ratio from 1.0 to 21.0") unless ratio && CONTRAST.cover?(ratio)
          ratio
        end

        def icons(line)
          path, keyword, *sizes = line.words.drop(1)
          line.fail!('expected icons PATH sizes SIZE...') unless keyword == 'sizes' && sizes.any?
          pixels = sizes.map { |size| integer(line, size, 1..PIXELS.max, 'icon size') }
          line.fail!('icon sizes must ascend') unless pixels.each_cons(2).all? { |low, high| low < high }
          ThemeIcons.new(path: path(line, path), sizes: pixels.freeze)
        end
      end
    end
  end
end
