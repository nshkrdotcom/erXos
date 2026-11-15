# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/web_stage'

# The theme (docs/design-abi.md, "Theme", and docs/design-desktop-programs.md,
# "The theme: one declaration"): abi/theme.txt passes its own rules, each rule
# refuses a copy of it seeded to break that rule alone, D7's seeded
# `secondary` of B0B0B0 fails its contrast rows, and the generated Erlang
# module, C header and TypeScript constants say what the source says, byte
# for byte the same over two runs of the generator.
class ErxThemeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE = File.read(File.join(ROOT, 'abi/theme.txt')).freeze
  GENERATED = File.join(ROOT, Erx::Generated::OUTPUT)
  OUTPUTS = [Erx::ABI::ThemeEmitter::ERLANG_PATH, Erx::ABI::ThemeEmitter::C_HEADER_PATH,
             Erx::ABI::ThemeEmitter::TS_PATH].freeze

  # Each seed replaces passages of abi/theme.txt, each occurring once, so
  # that it breaks one rule alone, and names the refusal that rule gives.
  REFUSALS = [
    [{ 'sizes 16 32' => "sizes 16 32\ntheme 2" }, /exactly one theme declaration/],
    [{ 'theme 1' => 'theme 0' }, /version must be positive/],
    [{ 'theme 1' => 'theme 4294967296' }, /version must be positive and fit 32 bits/],
    [{ 'theme 1' => 'theme 1 2' }, /expected theme VERSION/],
    [{ '  hairline 1' => '    hairline 1' }, /two-space indentation/],
    [{ '  hairline 1' => "  hairline 1\n  margin 3" }, /unknown theme member margin/],
    [{ 'color desktop    D9DAD5' => 'color "desktop"  D9DAD5' }, /takes no quoted token/],
    [{ '  hairline 1' => '' }, /needs one hairline row/],
    [{ '  hairline 1' => "  hairline 1\n  hairline 2" }, /needs one hairline row/],
    [{ '  shadow section 0 2 12 10' => '' }, /the theme needs a shadow row/],
    [{ '  unit 4' => '  unit 0' }, /unit must lie in 1\.\./],
    [{ '  unit 4' => '  unit 4 px' }, /expected unit PIXELS/],
    [{ 'color window     F6F5F2' => "color window     F6F5F2\n  color Wall       F6F5F2" }, /invalid theme name "Wall"/],
    [{ 'color desktop    D9DAD5' => "color desktop    D9DAD5\n  color desktop    D9DAD6" }, /color desktop is declared twice/],
    [{ 'color desktop    D9DAD5' => 'color desktop    d9dad5' }, /not six upper-case hexadecimal digits/],
    [{ 'color desktop    D9DAD5' => 'color desktop    D9DAD5 00' }, /expected color NAME RRGGBB/],
    [{ 'semibold Inter-SemiBold.ttf' => 'semibold Inter-SemiBold.ttf light Inter-Light.ttf' },
     /font weight light is not one of/],
    [{ 'semibold Inter-SemiBold.ttf' => 'semibold Inter-SemiBold.ttf medium Inter-Book.ttf' },
     /font weight medium is given twice/],
    [{ 'Inter-Medium.ttf' => 'Inter-Medium.otf' }, /not a \.ttf file name/],
    [{ 'semibold Inter-SemiBold.ttf' => 'semibold' }, /expected font NAME DIRECTORY WEIGHT FILE/],
    [{ 'display/fonts/inter' => '../fonts/inter' }, /not a relative path beneath the root/],
    [{ '2190-21FF' => "2190-21FF\n  range uj 0020-007E" }, /range names an undeclared font uj/],
    [{ '  range ui 0020-007E 00A0-017F 2000-206F 2190-21FF' => '' }, /font ui has no range row/],
    [{ '  range ui 0020-007E 00A0-017F 2000-206F 2190-21FF' => '  range ui' }, /expected range FONT LOW-HIGH/],
    [{ '00A0-017F' => '007E-017F' }, /007E-017F does not follow the one before it/],
    [{ '2190-21FF' => '21FF-2190' }, /21FF-2190 is empty/],
    [{ '2190-21FF' => '2190-21FF 10FFFE-110000' }, /10FFFE-110000 is empty or beyond U\+10FFFF/],
    [{ '2190-21FF' => '2190-21ff' }, /not LOW-HIGH in upper-case hexadecimal/],
    [{ 'role title   font ui' => 'role title   face ui font ui' }, /role key face is not one of/],
    [{ 'size 20 line 28' => 'size 20 line 28 size 21' }, /role key size is given twice/],
    [{ 'weight semibold figures tabular' => 'weight semibold figures tabular bold' },
     /expected role NAME KEY VALUE/],
    [{ 'role title   font ui size 20 line 28 weight semibold' => 'role title   font ui size 20 weight semibold' },
     /role needs line/],
    [{ 'role title   font ui' => 'role title   font uj' }, /role names an undeclared font uj/],
    [{ ' semibold Inter-SemiBold.ttf' => '' }, /font ui has no weight semibold/],
    [{ 'size 15 line 20' => 'size 15 line 18' }, /line 18 is not a multiple of the unit 4/],
    [{ 'size 13 line 20 weight regular' => 'size 13 line 20 weight regular figures oldstyle' },
     /figures oldstyle is not one of/],
    [{ 'weight regular color secondary' => 'weight regular color quaternary' },
     /role takes the undeclared colour quaternary/],
    [{ '  color text       1B1C1E' => '  color ink        1B1C1E', 'contrast text ' => 'contrast ink  ' },
     /role takes the undeclared colour text/],
    [{ 'space xs 1' => 'space xs 0' }, /space xs must lie in 1\.\.1024/],
    [{ 'xxl 8' => 'xxl 1025' }, /space xxl must lie in 1\.\.1024/],
    [{ 'xxl 8' => 'xxl 8 huge' }, /expected space NAME VALUE/],
    [{ 'l 4 xl 6' => 'l 4 l 6' }, /space l is given twice/],
    [{ 'window 0' => 'window 2' }, /radius window must be declared and 0/],
    [{ ' window 0' => '' }, /radius window must be declared and 0/],
    [{ '0 2 12 10' => '0 2 12 101' }, /shadow percent must lie in 0\.\.100/],
    [{ '0 2 12 10' => '0 2 12' }, /expected shadow NAME X Y BLUR PERCENT/],
    [{ 'contrast on_accent on accent' => 'contrast on_accent on accentt' },
     /contrast names an undeclared colour accentt/],
    [{ 'contrast on_accent on accent' => 'contrast on_accent over accent' }, /expected contrast FOREGROUND on/],
    [{ 'on accent 4.5' => 'on accent 4.50' }, /contrast ratio "4\.50" is not a ratio/],
    [{ 'on accent 4.5' => 'on accent 04.5' }, /contrast ratio "04\.5" is not a ratio/],
    [{ 'on accent 4.5' => 'on accent 22.0' }, /contrast ratio "22\.0" is not a ratio/],
    [{ 'sizes 16 32' => 'sizes 32 16' }, /icon sizes must ascend/],
    [{ 'sizes 16 32' => 'size 16 32' }, /expected icons PATH sizes SIZE/]
  ].freeze

  def test_the_source_meets_its_own_rules
    theme = theme_of(SOURCE)
    assert_equal %w[body caption display heading numeric title], theme.roles.keys
    assert_equal 3, theme.contrasts.size
    assert_equal 'secondary', theme.roles.fetch('caption').color
    assert_equal 'text', theme.roles.fetch('body').color
  end

  def test_the_contrast_ratio_follows_wcag_2
    ratio = Erx::ABI::Theme.method(:contrast_ratio)
    assert_in_delta 21.0, ratio.call(0x000000, 0xffffff), 1e-9
    assert_in_delta 1.0, ratio.call(0x5d6066, 0x5d6066), 1e-9
    assert_equal ratio.call(0x0e7a6b, 0xffffff), ratio.call(0xffffff, 0x0e7a6b)
    # 0x77 / 255 lies above the 0.04045 threshold: ((0.4667 + 0.055) / 1.055) ^ 2.4 = 0.1845,
    # and (1.0 + 0.05) / (0.1845 + 0.05) = 4.48.
    assert_in_delta 4.48, ratio.call(0x777777, 0xffffff), 0.005
  end

  # D7: the palette meets its contrast rules, so a `secondary` too light for
  # its surfaces fails generation.
  def test_d7_a_secondary_too_light_fails
    error = assert_raises(Erx::ABI::SchemaError) do
      theme_of(seeded('color secondary  5D6066' => 'color secondary  B0B0B0'))
    end
    assert_match(/abi\/theme\.txt:\d+: contrast secondary on window is 1\.99, below 4\.5/, error.message)
  end

  def test_each_rule_refuses_its_seed
    REFUSALS.each do |replacements, refusal|
      error = assert_raises(Erx::ABI::SchemaError, replacements.inspect) { theme_of(seeded(replacements)) }
      assert_match refusal, error.message, replacements.inspect
    end
  end

  def test_the_theme_belongs_in_its_own_file
    declarations = Erx::ABI::Syntax.parse(SOURCE, path: 'abi/formats/theme.txt').select { |item| item.kind == 'theme' }
    error = assert_raises(Erx::ABI::SchemaError) { Erx::ABI::Theme.validate(declarations) }
    assert_match(/belongs in abi\/theme\.txt/, error.message)
  end

  def test_the_output_is_byte_identical_over_two_runs
    Dir.mktmpdir('erx-theme-test') do |work|
      runs = %w[first second].map do |run|
        output = File.join(work, run)
        run!(RbConfig.ruby, File.join(ROOT, 'tools/gen_abi.rb'), '--root', ROOT, '--output', output, chdir: work)
        OUTPUTS.to_h { |path| [path, File.binread(File.join(output, path))] }
      end
      assert_equal(*runs)
    end
  end

  # The families are sets, so the order of their rows changes no byte.
  def test_the_order_of_the_rows_changes_no_output
    rows = SOURCE.lines.partition { |line| line.start_with?('  color ', '  role ') }
    reordered = [*rows.last, *rows.first.reverse].join
    assert_equal Erx::ABI::ThemeEmitter.files(theme_of(SOURCE)), Erx::ABI::ThemeEmitter.files(theme_of(reordered))
  end

  def test_the_erlang_module_says_what_the_source_says
    Dir.mktmpdir('erx-theme-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_memdraw], tests: [])
      # A failed match ends the run with status 1 and what failed, not in a shell.
      script = <<~ERLANG
        try
          16#1b1c1eff = erx_theme:color(text),
          #{SOURCE.scan(/^  color /).size} = length(erx_theme:colors()),
          \#{size := 11, line := 16, weight := regular, figures := proportional, color := secondary} =
            erx_theme:role(caption),
          tabular = maps:get(figures, erx_theme:role(display)),
          12 = erx_theme:space(m),
          0 = erx_theme:radius(window),
          \#{x := 0, y := 2, blur := 12, percent := 10} = erx_theme:shadow(section),
          {4, 1, 1} = {erx_theme:unit(), erx_theme:hairline(), erx_theme:version()},
          undeclared = try erx_theme:color(lavender) catch error:function_clause -> undeclared end,
          halt(0)
        catch Class:Reason -> io:format("~p:~p~n", [Class, Reason]), halt(1)
        end.
      ERLANG
      run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval', script, chdir: work)
    end
  end

  def test_the_c_header_compiles_and_says_what_the_source_says
    Dir.mktmpdir('erx-theme-test') do |work|
      source = File.join(work, 'theme.c')
      File.write(source, <<~C)
        #include <erx/theme.h>

        _Static_assert(ERX_THEME_COLOR_TEXT == 0x1b1c1eu, "text");
        _Static_assert(ERX_THEME_ROLE_CAPTION_COLOR == ERX_THEME_COLOR_SECONDARY, "caption colour");
        _Static_assert(ERX_THEME_ROLE_DISPLAY_TABULAR == 1 && ERX_THEME_ROLE_BODY_TABULAR == 0, "figures");
        _Static_assert(ERX_THEME_ROLE_NUMERIC_WEIGHT == 500, "weight");
        _Static_assert(ERX_THEME_SPACE_XXL == 32 && ERX_THEME_RADIUS_WINDOW == 0, "lengths");
        _Static_assert(ERX_THEME_SHADOW_SECTION_BLUR == 12, "shadow");

        #define SIZE(name, NAME) + ERX_THEME_ROLE_##NAME##_SIZE
        _Static_assert(0 ERX_THEME_ROLES(SIZE) == 48 + 20 + 15 + 13 + 13 + 11, "every role");
      C
      run!(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-fsyntax-only',
           '-I', File.join(GENERATED, 'include'), source, chdir: work)
    end
  end

  def test_the_typescript_constants_say_what_the_source_says
    module_path = File.join(GENERATED, Erx::ABI::ThemeEmitter::TS_PATH)
    script = <<~JS
      const { THEME_VERSION, THEME_PROPERTIES } = await import(#{module_path.dump});
      console.log(JSON.stringify([THEME_VERSION, ...THEME_PROPERTIES]));
    JS
    properties = JSON.parse(run!(*Erx::WebStage::NODE, '--input-type=module', '-e', script, chdir: ROOT))
    version = properties.shift
    properties = properties.to_h
    assert_equal 1, version
    assert_equal '#1b1c1e', properties.fetch('--erx-color-text')
    assert_equal 'var(--erx-color-secondary)', properties.fetch('--erx-role-caption-color')
    assert_equal 'tabular-nums', properties.fetch('--erx-role-display-font-variant-numeric')
    assert_equal '600', properties.fetch('--erx-role-title-font-weight')
    assert_equal '12px', properties.fetch('--erx-space-m')
    assert_equal '0px 2px 12px rgb(0 0 0 / 10%)', properties.fetch('--erx-shadow-section')
    assert_equal properties.keys.sort, properties.keys
  end

  private

  def theme_of(text)
    declarations = Erx::ABI::Syntax.parse(text, path: 'abi/theme.txt').select { |item| item.kind == 'theme' }
    Erx::ABI::Theme.validate(declarations)
  end

  # abi/theme.txt with the one occurrence of each key of REPLACEMENTS
  # replaced by its value.
  def seeded(replacements)
    replacements.reduce(SOURCE) do |text, (from, to)|
      assert_equal 1, SOURCE.scan(from).size, "the seed #{from.inspect} occurs once"
      text.sub(from) { to }
    end
  end

  def run!(*command, chdir:)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '300', *command, chdir: chdir, stdin_data: '')
    assert status.success?, output
    output
  end
end
