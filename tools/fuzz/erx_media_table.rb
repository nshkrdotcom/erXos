# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=600

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of the partition table's reader, erx_media_table
# (test/erlang/erx_media_table_fuzz.erl, docs/design-drives.md "Fuzz targets"),
# compiled from source and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the
# oracle's), so it needs no hosted build, over the media erx_media_table_cases writes
# as its seeds. It runs the reader as it is, then a copy whose integrity check lets an
# entry end past the medium, which must fail: a mutated entry is then served outside
# the medium.
module ErxMediaTableFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_media/src/erx_media_table.erl'
  SOURCES = %w[test/erlang/erx_media_table_cases.erl test/erlang/erx_media_table_fuzz.erl].freeze
  CHECKED = 'Last =< LastUsable orelse fail({past_the_end, [Number]})'
  UNCHECKED = 'is_integer(Last)'
  DEADLINE_SECONDS = '300'
  VERDICT = 'served_outside'

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    core = File.binread(File.join(ROOT, CORE))
    raise "no end check on an entry in #{CORE}" unless core.scan(CHECKED).size == 1

    output, status = fuzz(core, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(core.sub(CHECKED, UNCHECKED), seed: seed)
    abort("an entry past the medium passed:\n#{output}") if status.success? || !output.include?(VERDICT)
    puts 'erx_media_table serves only volumes inside the medium, and the unchecked copy does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(core_text, seed:)
    Dir.mktmpdir('erx-media-table-fuzz') do |work|
      core_path = File.join(work, File.basename(CORE))
      File.binwrite(core_path, core_text)
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', include, '-o', work, core_path,
                                       *SOURCES.map { |source| File.join(ROOT, source) }, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_media_table_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxMediaTableFuzz.run(seed: seed)
end
