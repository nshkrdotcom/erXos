# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=600

require 'fileutils'
require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/abi'

# The fuzz target of erx_font:parse/1, the reader of Plan 9 subfont files,
# which are untrusted (docs/design-display.md, "Erlang clients"). It runs
# test/erlang/erx_font_fuzz.erl, which makes its well-formed files with
# test/erlang/erx_font_tests.erl and loads what it accepts into
# erx_draw_core, on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's),
# in a directory holding the subfonts of display/font/fixed: first with
# erx_font as it is, then as two copies that each let a glyph leave its
# image, one by its columns and one by its rows, which must fail. That shows the inputs reach
# both checks and the invariants catch what they let through.
module ErxFontFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_win/src/erx_font.erl')
  SOURCES = %w[erlang/apps/erx_memdraw/src/erx_chan.erl erlang/apps/erx_win/src/erx_draw_image.erl
               erlang/apps/erx_win/src/erx_draw_core.erl test/erlang/erx_font_tests.erl
               test/erlang/erx_font_fuzz.erl].map { |path| File.join(ROOT, path) }.freeze
  ABI_HEADER = 'erlang/apps/erx/include/generated/erx_abi.hrl'
  FONTS = Dir.glob(File.join(ROOT, 'display/font/fixed/6x13.*')).freeze
  SEEDED = {
    'the right edge' => [' andalso X1 =< W end', ' end'],
    'the bottom row' => ['Rows = min(Bottom, H)', 'Rows = Bottom']
  }.freeze
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
    SEEDED.each do |check, (text, wrong)|
      raise "#{check} (#{text}) is not once in #{MODULE_SOURCE}" unless source.scan(text).size == 1

      output, status = fuzz(source.sub(text, wrong), seed: seed)
      abort("a parser without #{check} passed:\n#{output}") if status.success? || !output.include?('breaks_invariant')
    end
    puts "erx_font:parse/1 keeps its invariants, and parsers without #{SEEDED.keys.join(' or ')} do not"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    generated = Erx::ABI::Generator.plan(root: ROOT).files
    Dir.mktmpdir('erx-font-fuzz') do |work|
      File.binwrite(File.join(work, 'erx_draw_codec.erl'), generated.fetch(Erx::ABI::DrawEmitter::ERLANG_PATH))
      # erx_draw_core includes the ABI header as generated/erx_abi.hrl.
      FileUtils.mkdir_p(File.join(work, 'generated'))
      File.binwrite(File.join(work, 'generated/erx_abi.hrl'), generated.fetch(ABI_HEADER))
      File.binwrite(File.join(work, 'erx_font.erl'), module_text)
      FileUtils.cp(FONTS, work)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-I', work,
                                       '-o', work,
                                       File.join(work, 'erx_draw_codec.erl'), File.join(work, 'erx_font.erl'),
                                       *SOURCES, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_font_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxFontFuzz.run(seed: seed)
end
