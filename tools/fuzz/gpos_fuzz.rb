#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'optparse'
require 'timeout'
require 'tmpdir'
require_relative '../lib/erx/gpos'
require_relative '../lib/erx/glyphs'
require_relative '../lib/erx/runner'
require_relative '../../test/fixtures/gpos_tables'

# The glyph step's kerning reader (Erx::Gpos.pairs) over mutated GPOS and GDEF
# tables (docs/design-desktop-programs.md, "Kerning, on the host"). The seeds
# are the theme's Inter fonts' tables as erx-raster reports them, which needs
# erx-raster built (tools/erx build glyphs), and the tables
# test/fixtures/gpos_tables.rb builds. Each round changes, inserts and removes
# bytes, cuts the tables short and writes offsets and counts near and past
# their ends, and passes up to 64 glyph indices, some past any font's glyph
# count. Every input must end in pairs, each naming two of the glyphs given
# with a value that is not 0, or in an Erx::Error; any other exception, or a
# call outlasting ten times the slowest unmutated seed's, fails the run and
# writes the input beneath ARTIFACTS. Whether the pairs are right is
# test/host/gpos_test.rb's.
module Erx
  module GposFuzz
    # A seed: the two tables and the glyph indices worth drawing from.
    Seed = Data.define(:gpos, :gdef, :glyphs)
    MAX_GLYPHS = 64
    ROOT = File.expand_path('../..', __dir__)
    ARTIFACTS = 'build/fuzz-artifacts/gpos'

    # A finding: an exception other than Erx::Error, a pair the reader may
    # not return, or a call past the limit.
    class Failure < StandardError; end

    module_function

    def built_seeds
      t = GposTables
      marks = t.gdef({ t::A => 1, 400 => 3 })
      [t.sample, t.sample(named: [0, 1, 0, 1]), t.self_extension, t.sample(lookups: t.lookups(type: 1))]
        .map { |gpos| Seed.new(gpos: gpos, gdef: marks, glyphs: t::GLYPHS) } +
        [Seed.new(gpos: t.sample, gdef: ''.b, glyphs: t::GLYPHS)]
    end

    # The theme's fonts' tables, with the glyphs of their printable ASCII
    # characters.
    def font_seeds(root:)
      program = Raster.locate(root: root)
      theme = Glyphs.theme(root: root)
      ascii = (0x20..0x7e).map { |point| format('U+%04X', point) }
      Dir.mktmpdir('erx-gpos-fuzz-') do |work|
        runner = Runner.new(owner_root: work, log_dir: File.join(work, 'logs'))
        theme.roles.values.map { |role| Glyphs.font_file(theme, role) }.uniq.map do |font|
          result = program.rasterise(font: File.join(root, font), size: 13, glyphs: ascii, runner: runner)
          Seed.new(gpos: result.gpos, gdef: result.gdef, glyphs: result.glyphs.compact.map(&:index))
        end
      end
    end

    def mutate(bytes, random)
      result = bytes.b.dup
      random.rand(1..4).times do
        next if result.empty?

        at = random.rand(result.bytesize)
        case random.rand(5)
        when 0 then result.setbyte(at, random.rand(256))
        when 1 then result = result.byteslice(0, at)
        when 2 then result.insert(at, random.bytes(random.rand(1..8)))
        when 3 then result.slice!(at, random.rand(1..8))
        else
          size = result.bytesize
          near = [0, 1, size - 1, size, size + 1, 0x7fff, 0xffff].sample(random: random)
          result[at & ~1, 2] = [near & 0xffff].pack('n') if (at & ~1) + 2 <= size
        end
      end
      result
    end

    def glyphs(seed, random)
      Array.new(random.rand(0..MAX_GLYPHS)) do
        case random.rand(4)
        when 0 then random.rand(0x10000)
        when 1 then random.rand(4096)
        else seed.glyphs.sample(random: random)
        end
      end
    end

    # One call of the reader, which must return pairs of GLYPHS, ascending,
    # or raise Erx::Error within LIMIT seconds.
    def exercise(tables, glyphs, limit:)
      gpos, gdef = tables
      pairs = Timeout.timeout(limit, Failure, "a call outlasted #{limit} seconds") do
        Gpos.pairs(gpos: gpos, gdef: gdef, glyphs: glyphs)
      end
      bad = pairs.find do |(first, second), value|
        !(glyphs.include?(first) && glyphs.include?(second) && value.is_a?(Integer) && !value.zero?)
      end
      raise Failure, "a pair outside the glyphs given or of value 0: #{bad.inspect}" if bad
      raise Failure, 'pairs out of ascending order' unless pairs.keys == pairs.keys.sort
    rescue Erx::Error
      nil
    end

    # The call limit: ten times the slowest unmutated seed's time, each
    # seed timed on its second call, once its first has warmed the reader.
    def limit(seeds)
      10 * seeds.map do |seed|
        Array.new(2) do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          exercise([seed.gpos, seed.gdef], seed.glyphs.first(MAX_GLYPHS), limit: 60)
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end.last
      end.max
    end

    # Rounds for SECONDS from the random SEED over SEEDS; returns how many
    # ran, or raises Failure with the path of the input that failed.
    def run(seconds:, seed:, seeds:, artifacts: File.join(ROOT, ARTIFACTS))
      random = Random.new(seed)
      bound = limit(seeds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      count = 0
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        chosen = seeds.sample(random: random)
        tables = [chosen.gpos, chosen.gdef].map { |table| random.rand(3).zero? ? table : mutate(table, random) }
        given = glyphs(chosen, random)
        begin
          exercise(tables, given, limit: bound)
        rescue StandardError, ScriptError, SystemStackError, NoMemoryError => e # the finding, kept with its input
          raise Failure, "#{e.class}: #{e.message}; the input is #{record(artifacts, tables, given)}"
        end
        count += 1
      end
      count
    end

    def record(artifacts, tables, glyphs)
      FileUtils.mkdir_p(artifacts)
      input = Marshal.dump([*tables, glyphs])
      File.join(artifacts, "#{Digest::SHA256.hexdigest(input)}.marshal").tap { |path| File.binwrite(path, input) }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seconds: 3, seed: 1 }
  OptionParser.new do |arguments|
    arguments.on('--seconds N', Integer) { |value| options[:seconds] = value }
    arguments.on('--seed N', Integer) { |value| options[:seed] = value }
  end.parse!(ARGV)
  raise OptionParser::InvalidArgument, 'budget of 1..60 seconds' unless options[:seconds].between?(1, 60)

  seeds = Erx::GposFuzz.font_seeds(root: Erx::GposFuzz::ROOT) + Erx::GposFuzz.built_seeds
  puts "GPOS kerning reader: #{Erx::GposFuzz.run(**options, seeds: seeds)} inputs"
end
