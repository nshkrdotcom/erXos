# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/gpos_tables'
require_relative '../fixtures/seeded_source'
require_relative '../../tools/lib/erx/gpos'
require_relative '../../tools/fuzz/gpos_fuzz'

# Erx::Gpos, the glyph step's kerning reader (docs/design-desktop-programs.md,
# "Kerning" and "Kerning, on the host"), over tables GposTables builds, each
# test paired with the seeded fault it must catch, a copy of
# tools/lib/erx/gpos.rb with one passage replaced (SeededSource).
class GposTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE = File.join(ROOT, 'tools/lib/erx/gpos.rb')
  T = GposTables

  # The seeded faults, each a passage of SOURCE and its replacement.
  FIRST_LOOKUP = ['totals[pair] += times * value', 'totals[pair] = value unless totals.key?(pair)'].freeze
  FIRST_SINGLES = ['matched_pairs.merge(fresh.keys)', 'matched_firsts.merge(fresh.keys.map(&:first))'].freeze
  EACH_NAMING = ['.flat_map { |feature| lookup_indices(feature) }.uniq.sort',
                 '.flat_map { |feature| lookup_indices(feature) }.sort'].freeze
  NO_BOUND = [' if start + size > @bytes.bytesize', ' if false'].freeze
  FLAGS_UNREAD = [' unless (flag & ~MARK_FLAGS).zero?', ' if false'].freeze
  FOLLOWS = [' if inner == EXTENSION', ' if false'].freeze

  def setup
    @work = Dir.mktmpdir('erx-gpos-test-')
  end

  def teardown = FileUtils.remove_entry(@work)

  def test_sample_reads_its_construction
    assert_equal T::EXPECTED, read(T.sample)
  end

  def test_first_lookup_that_matches_fails_the_sum
    pairs = seeded(FIRST_LOOKUP) { read(T.sample) }
    refute_equal T::EXPECTED.fetch([T::A, T::V]), pairs.fetch([T::A, T::V])
  end

  def test_stopping_at_a_covering_format_1_subtable_fails_the_class_value
    pairs = seeded(FIRST_SINGLES) { read(T.sample) }
    refute_equal T::EXPECTED.fetch([T::A, T::O]), pairs[[T::A, T::O]]
  end

  def test_lookups_named_twice_read_as_named_once
    assert_equal T::EXPECTED, read(T.sample(named: [0, 1, 0, 1]))
    doubled = seeded(EACH_NAMING) { read(T.sample(named: [0, 1, 0, 1])) }
    assert_equal 2 * T::EXPECTED.fetch([T::A, T::V]), doubled.fetch([T::A, T::V])
  end

  def test_latn_is_chosen_over_dflt_and_a_font_with_neither_has_no_pairs
    lookups = T.lookups
    table = T.gpos(scripts: [['DFLT', T.script(T.language_system([0]))], ['latn', T.script(T.language_system([1]))]],
                   features: [['kern', T.feature([0, 1])], ['kern', T.feature([1])]], lookups: lookups)
    assert_equal({ [T::A, T::V] => -30 }, read(table))
    assert_equal({}, read(T.sample(scripts: [['cyrl', true]])))
    assert_equal({}, Erx::Gpos.pairs(gpos: ''.b, gdef: ''.b, glyphs: T::GLYPHS))
  end

  def test_a_table_cut_short_is_refused
    table = T.sample
    (1...table.bytesize).each do |size|
      assert_raises(Erx::Gpos::Refused, "cut at #{size}") { read(table.byteslice(0, size)) }
    end
    outcome = seeded(NO_BOUND, outcome: true) { read(table.byteslice(0, table.bytesize / 2)) }
    assert_equal :raised, outcome.first
    refute outcome[2], "the unbounded reader raised #{outcome[1]}, an Erx::Error"
  end

  def test_refusals_name_what_they_refuse
    {
      'value format' => T.sample(lookups: T.lookups(format1: 0x0001)),
      'not a pair adjustment' => T.sample(lookups: T.lookups(type: 1)),
      'lookup flag 0x0004' => T.sample(lookups: T.lookups(flag: 0x0004)),
      'no default language system' => T.sample(scripts: [['DFLT', true], ['latn', false]]),
      'wraps another extension' => T.self_extension,
      'class 3 at or past' => T.sample(lookups: [T.lookup(T::PAIR, [T.pair_classes(firsts: [T::A], class1: {},
                                                                                  class2: { T::V => 3 },
                                                                                  matrix: [[0, -30]])])],
                                       named: [0])
    }.each do |reason, table|
      error = assert_raises(Erx::Gpos::Refused, reason) { read(table) }
      assert_includes error.message, reason
    end
  end

  def test_dflt_is_read_when_the_font_has_no_latn_and_mark_attachment_flags_are_accepted
    assert_equal T::EXPECTED, read(T.sample(scripts: [['DFLT', true], ['cyrl', false]], lookups: T.lookups(flag: 0xff10)))
  end

  def test_malformed_subtables_are_refused
    {
      'leave no class 0' => T.pair_classes(firsts: [T::A], class1: {}, class2: {}, matrix: [], counts: [1, 0]),
      'value formats 0x0004 and 0x0004' => T.pair_singles({ T::A => [[T::V, -50]] }, format2: 0x0004),
      'out of ascending order' => T.pair_classes(firsts: [T::T, T::A], class1: {}, class2: { T::V => 1 }, matrix: [[0, -30]])
    }.each do |reason, subtable|
      error = assert_raises(Erx::Gpos::Refused, reason) { read(T.sample(lookups: [T.lookup(T::PAIR, [subtable])], named: [0])) }
      assert_includes error.message, reason
      assert_includes error.message, 'lookup 0 subtable 0'
    end
  end

  # A subtable over 3,000 glyphs named by 4,000 offsets of one lookup reads
  # as fast as when named once, and gives the same pairs.
  def test_a_subtable_named_many_times_is_read_once
    glyphs = (0...3000).to_a
    subtable = T.pair_classes(firsts: glyphs, class1: glyphs.to_h { |glyph| [glyph, 1] },
                              class2: glyphs.to_h { |glyph| [glyph, 1 + (glyph % 2)] }, matrix: [[0, 0, 0], [-5, -7, 9]])
    drawn = (0...64).map { |number| number * 37 }
    once, many = [1, 4000].map do |times|
      table = T.sample(lookups: [T.repeated_lookup(T::PAIR, subtable, times)], named: [0])
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      [Erx::Gpos.pairs(gpos: table, gdef: ''.b, glyphs: drawn), Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
    end
    assert_equal once.first, many.first
    assert_equal 64 * 64, many.first.size
    assert_operator many.last, :<, 1.0, 'reading the table took more than a second'
  end

  def test_a_lookup_flag_left_unread_accepts_ignore_ligatures
    assert_equal T::EXPECTED, seeded(FLAGS_UNREAD) { read(T.sample(lookups: T.lookups(flag: 0x0004))) }
  end

  def test_a_drawn_glyph_classed_a_mark_is_refused
    error = assert_raises(Erx::Gpos::Refused) { read(T.sample, gdef: T.gdef({ T::O => 3, T::A => 1 })) }
    assert_includes error.message, "glyph #{T::O}"
    assert_equal T::EXPECTED, read(T.sample, gdef: T.gdef({ T::A => 1, 400 => 3 }))
  end

  def test_fuzz_target_catches_an_unbounded_reader
    outcome = seeded(NO_BOUND, outcome: true) do
      Erx::GposFuzz.run(seconds: 2, seed: 1, seeds: Erx::GposFuzz.built_seeds, artifacts: @work)
    end
    assert_equal [:raised, 'Erx::GposFuzz::Failure'], outcome.first(2)
    assert_match(/\A(NoMethodError|TypeError|ArgumentError)/, outcome.last)
  end

  def test_fuzz_target_catches_a_reader_that_follows_a_self_extension
    outcome = seeded(FOLLOWS, outcome: true) { Erx::GposFuzz.exercise([T.self_extension, ''.b], T::GLYPHS, limit: 1) }
    assert_equal :raised, outcome.first
    refute outcome[2], "the fuzz target failed with #{outcome[1]}, an Erx::Error"
  end

  private

  def read(gpos, gdef: ''.b) = Erx::Gpos.pairs(gpos: gpos, gdef: gdef, glyphs: T::GLYPHS)

  # What the block gives with SOURCE's passage FAULT.first replaced by
  # FAULT.last (SeededSource): its value, or with outcome: true, the outcome
  # SeededSource.run gives.
  def seeded(fault, outcome: false)
    result = SeededSource.run(SOURCE, fault, work: @work) { yield }
    return result if outcome
    raise "the seeded reader raised #{result[1]}: #{result.last}" unless result.first == :value

    result.last
  end
end
