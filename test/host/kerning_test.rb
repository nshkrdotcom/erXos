# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/gpos_tables'
require_relative '../fixtures/seeded_source'
require_relative '../../tools/lib/erx/glyphs'

# The glyph step's kerning over the theme's Inter fonts
# (docs/design-desktop-programs.md, "Kerning" and "Kerning, on the host"),
# with erx-raster built once from the fetched FreeType pin into a temporary
# directory: Inter Regular's units for AV, To, Ty and quote-comma, and the
# widths erx_font:width/2 gives them from the body subfont against the
# rounding rule in exact arithmetic, where a seeded step with the
# adjustment's sign flipped, or with k rounded on its own, fails; the pair
# section as the subfont file holds it; the step's refusals of a legacy kern
# table and of a drawn glyph GDEF classes a mark; no pair naming a tabular
# digit; and the line-length check over the tree's README.md, each line
# measured by erx_font:width/2, which prints each role's numbers for the pens
# of Open decisions, 3. erx_font runs on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies).
class KerningTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  GLYPHS_SOURCE = File.join(ROOT, 'tools/lib/erx/glyphs.rb')
  ADJUSTMENT = 'pixels = kerned - (advance + HALF).floor'
  SIGN = [ADJUSTMENT, 'pixels = (advance + HALF).floor - kerned'].freeze
  ROUNDED_K = [ADJUSTMENT, 'pixels = (Rational(units * role.size, face.units_per_em) + HALF).floor'].freeze
  # The body role's widths of AV, To, Ty and quote-comma by the rule.
  BODY_TEXTS = ['AV', 'To', 'Ty', '",'].freeze
  BODY_WIDTHS = [17, 15, 15, 9].freeze
  HALF = Rational(1, 2)
  # The line-length check's lines: the first 400 ASCII lines of 8 to 70
  # characters ("Whole pixels and the pen").
  LINES = 400
  LINE_LENGTH = 8..70
  PHASES = 4
  DIGITS = 0x30..0x39
  DEADLINE_SECONDS = '300'
  # erx_font's widths of the lines in lines.term, of the subfont in role.subfont.
  WIDTHS = '{ok, Bytes} = file:read_file("role.subfont"), {ok, Subfont} = erx_font:parse(Bytes), ' \
           '{ok, [Lines]} = file:consult("lines.term"), ' \
           'io:format("~w~n", [[erx_font:width(Subfont, Line) || Line <- Lines]]), halt(0)'

  # A role as the step reads it: its theme entry, its requests, erx-raster's
  # result, the subfont, its code points and the font's kerning in units of
  # its drawn glyphs.
  Role = Data.define(:role, :requests, :result, :subfont, :points, :units)

  def self.roles
    @roles ||= begin
      work = Dir.mktmpdir('erx-kerning-test-')
      Minitest.after_run { FileUtils.remove_entry(work) }
      runner = Erx::Runner.new(owner_root: work, log_dir: File.join(work, 'logs'))
      program = Erx::Raster::Build.new(root: ROOT, runner: runner, output_root: work).call
      theme = Erx::Glyphs.theme(root: ROOT)
      theme.roles.transform_values do |role|
        font = theme.fonts.fetch(role.font)
        requests = Erx::Glyphs.requests(role, font)
        result = program.rasterise(font: File.join(ROOT, Erx::Glyphs.font_file(theme, role)), size: role.size,
                                   glyphs: requests, runner: runner)
        subfont = Erx::Glyphs.subfont(role, requests: requests, result: result)
        drawn = result.glyphs.zip(subfont.glyphs).filter_map { |coverage, glyph| coverage.index if glyph.width.positive? }
        Role.new(role: role, requests: requests, result: result, subfont: subfont, points: Erx::Glyphs.code_points(font),
                 units: Erx::Gpos.pairs(gpos: result.gpos, gdef: result.gdef, glyphs: drawn))
      end.freeze
    end
  end

  # erx_font and what it calls, compiled once for every case.
  def self.erlang
    @erlang ||= Dir.mktmpdir('erx-kerning-erlang-').tap do |work|
      Minitest.after_run { FileUtils.remove_entry(work) }
      ErlangBuild.compile(work, applications: %w[erx_win])
    end
  end

  def setup
    @work = Dir.mktmpdir('erx-kerning-case-')
  end

  def teardown = FileUtils.remove_entry(@work)

  def test_body_units_and_widths_follow_the_rounding_rule
    body = role('body')
    assert_equal [-140, -160, -128, -168], BODY_TEXTS.map { |text| body.units.fetch(fonts(body, text)) }
    assert_equal BODY_WIDTHS, widths(body, body.subfont.encode, BODY_TEXTS)
    assert_equal BODY_WIDTHS, BODY_TEXTS.map { |text| exact_rule_width(body, text) }
    refute pair?(body, 'Ty'), 'Ty has a pair at 13 pixels'
    assert pair?(role('title'), 'Ty'), 'Ty has no pair at 20 pixels'
  end

  def test_a_wrong_sign_or_k_rounded_alone_fails_the_widths
    body = role('body')
    [SIGN, ROUNDED_K].each do |fault|
      outcome = SeededSource.run(GLYPHS_SOURCE, fault, work: @work) do
        Erx::Glyphs.subfont(body.role, requests: body.requests, result: body.result).encode
      end
      assert_equal :value, outcome.first, outcome.inspect
      refute_equal BODY_WIDTHS, widths(body, outcome.last, BODY_TEXTS), fault.last
    end
  end

  # The bytes after the glyph table: the word kern and the count as header
  # fields, then 5 bytes a pair, strictly ascending, each naming two drawn
  # glyphs, with an adjustment that is not 0 and a kerned advance in 0 to 255.
  def test_pair_section_follows_the_glyph_table
    subfont = role('body').subfont
    bytes = subfont.encode
    table_end = 5 * 12 + subfont.pixels.bytesize + 3 * 12 + 6 * (subfont.glyphs.size + 1)
    section = bytes.byteslice(table_end..)
    assert_equal "#{'kern'.rjust(11)} #{subfont.pairs.size.to_s.rjust(11)} ", section.byteslice(0, 24)
    entries = section.byteslice(24..).unpack('vvc' * subfont.pairs.size).each_slice(3).to_a
    assert_equal 24 + 5 * entries.size, section.bytesize
    assert_equal subfont.pairs, entries
    assert(entries.each_cons(2).all? { |(a, b), (c, d)| ([a, b] <=> [c, d]).negative? })
    entries.each do |first, second, adjustment|
      assert [first, second].all? { |index| subfont.glyphs.fetch(index).width.positive? }
      refute_equal 0, adjustment
      assert_includes 0..255, subfont.glyphs.fetch(first).width + adjustment
    end
  end

  def test_a_legacy_kern_table_and_a_drawn_mark_are_refused
    body = role('body')
    legacy = body.result.with(legacy_kern: true)
    error = assert_raises(Erx::Glyphs::Refused) { Erx::Glyphs.subfont(body.role, requests: body.requests, result: legacy) }
    assert_match(/role body: .*legacy kern table/, error.message)
    marked = body.result.with(gdef: GposTables.gdef({ fonts(body, 'A').first => 3 }))
    error = assert_raises(Erx::Glyphs::Refused) { Erx::Glyphs.subfont(body.role, requests: body.requests, result: marked) }
    assert_match(/role body: its kerning: glyph \d+ is classed a mark/, error.message)
  end

  # An adjustment outside a signed byte, and a kerned advance below 0, are
  # refused rather than cut to fit.
  def test_a_pair_out_of_range_is_refused
    body = role('body')
    a = body.result.glyphs.fetch(indices(body, 'A').first)
    { 100_000 => /adjustment of \d+ pixels/, -1575 => /kerned advance of -\d+ pixels/ }.each do |units, reason|
      error = assert_raises(Erx::Glyphs::Refused) { Erx::Glyphs.adjustment(body.role, body.result.face, a, units) }
      assert_match(reason, error.message)
    end
  end

  def test_tabular_roles_kern_no_digit
    %w[numeric display].each do |name|
      entry = role(name)
      digits = entry.subfont.pairs.select { |a, b, _| [a, b].any? { |index| DIGITS.cover?(entry.points[index]) } }
      assert_empty digits, "role #{name}"
    end
    refute_empty role('body').subfont.pairs.select { |a, _, _| DIGITS.cover?(role('body').points[a]) }
  end

  # Ten i measure 30 pixels in caption and body, where a width that adds
  # exact advances and rounds the line once gives 27 and 32; each README line
  # measures, by erx_font:width/2, the rule's rounded kerned advances in
  # exact arithmetic. Prints each role's numbers for the three pens.
  def test_line_length_check
    lines = File.foreach(File.join(ROOT, 'README.md')).map(&:chomp)
                .select { |line| LINE_LENGTH.cover?(line.size) && line.match?(/\A[\x20-\x7e]+\z/) }.first(LINES)
    measured = %w[caption body heading title].to_h do |name|
      entry = role(name)
      [name, widths(entry, entry.subfont.encode, ['i' * 10, *lines])]
    end
    %w[caption body].zip([27, 32]).each do |name, rounded_once|
      assert_equal 30, measured.fetch(name).first, "role #{name}"
      assert_equal rounded_once, (exact_advances(role(name), 'i' * 10).sum + HALF).floor, "role #{name}"
    end
    measured.each do |name, (_, *line_widths)|
      entry = role(name)
      lines.zip(line_widths).each { |line, width| assert_equal exact_rule_width(entry, line), width, "#{name}: #{line}" }
      report(name, entry, lines, line_widths)
    end
  end

  private

  def role(name) = self.class.roles.fetch(name)

  def indices(entry, text) = text.chars.map { |char| entry.points.index(char.ord) || raise("#{char} is outside the ranges") }

  def fonts(entry, text) = indices(entry, text).map { |index| entry.result.glyphs.fetch(index).index }

  def pair?(entry, text) = entry.subfont.pairs.any? { |a, b, _| [a, b] == indices(entry, text) }

  # The width erx_font:width/2 gives each of TEXTS, in the role's subfont
  # whose file is BYTES, on stock's emulator in the case's directory.
  def widths(entry, bytes, texts)
    File.binwrite(File.join(@work, 'role.subfont'), bytes)
    File.write(File.join(@work, 'lines.term'), "#{texts.map { |text| indices(entry, text) }.inspect}.\n")
    output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                     '-pa', self.class.erlang, '-eval', WIDTHS, chdir: @work, stdin_data: '')
    assert status.success?, output
    JSON.parse(output.lines.last)
  end

  # The font's exact advance of each glyph of TEXT, kerned by the next.
  def exact_advances(entry, text)
    fonts = fonts(entry, text)
    fonts.each_with_index.map do |font, number|
      units = number + 1 < fonts.size ? entry.units.fetch([font, fonts[number + 1]], 0) : 0
      advance = entry.result.glyphs.fetch(indices(entry, text)[number]).advance
      Rational(advance, 64) + Rational(units * entry.role.size, entry.result.face.units_per_em)
    end
  end

  # The rule in exact arithmetic: each kerned advance rounded half up.
  def exact_rule_width(entry, text) = exact_advances(entry, text).sum { |advance| (advance + HALF).floor }

  # Each role's mean and largest difference of a line's width from its exact
  # length, and the share of neighbour distances more than half a pixel off
  # the font's under each pen: whole pixels (this rule), fractional origins
  # each rounded, and fractional origins at PHASES phases a pixel.
  def report(name, entry, lines, line_widths)
    differences = lines.zip(line_widths).map { |line, width| width - exact_advances(entry, line).sum }
    pens = { 'rounded origins' => ->(origin) { (origin + HALF).floor },
             "#{PHASES} phases" => ->(origin) { (origin * PHASES + HALF).floor.quo(PHASES) } }
    distances = lines.sum { |line| line.size - 1 }
    shares = { 'whole pixels' => lines.sum { |line| rule_far(entry, line) } }
             .merge(pens.transform_values { |place| lines.sum { |line| far_distances(entry, line, place) } })
             .transform_values { |far| far.quo(distances) }
    puts format('%-8s %3d lines: width - exact %+.2f px on average, %+.2f px at most; distances more than half a pixel off: %s',
                name, lines.size, differences.sum.quo(lines.size).to_f, differences.max_by(&:abs).to_f,
                shares.map { |pen, share| format('%s %.0f%%', pen, 100 * share.to_f) }.join(', '))
  end

  # The distances more than half a pixel off the font's in a line whose
  # glyph origins, exact, PLACE moves.
  def far_distances(entry, line, place)
    exact = exact_advances(entry, line)
    origins = exact.each_with_object([0]) { |advance, all| all << all.last + advance }.first(line.size)
    placed = origins.map { |origin| place.call(origin) }
    placed.each_cons(2).zip(exact).count { |(a, b), advance| (b - a - advance).abs > HALF }
  end

  # The whole-pixel pen's distances more than half a pixel off the font's.
  def rule_far(entry, line)
    exact = exact_advances(entry, line)
    exact.first(line.size - 1).count { |advance| ((advance + HALF).floor - advance).abs > HALF }
  end
end
