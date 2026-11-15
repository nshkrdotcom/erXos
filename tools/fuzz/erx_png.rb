# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_png and erx_inflate, the PNG reader of the Erlang renderer and
# its inflate (docs/design-display.md, "Verification and testing"): arbitrary bytes,
# mutated PNGs and mutated zlib streams through test/erlang/erx_png_fuzz.erl, compiled
# from source with the modules the reader calls and run alone on stock's emulator
# (ERX_ERL and ERX_ERLC, the oracle's). It runs more rounds than the landing test,
# test/host/erx_png_test.rb, which also plants the seeded faults.
module ErxPngFuzz
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[erlang/apps/erx_win/src/erx_png.erl erlang/apps/erx_win/src/erx_inflate.erl
               erlang/apps/erx_win/src/erx_draw_core.erl erlang/apps/erx_win/src/erx_draw_image.erl
               erlang/apps/erx_memdraw/src/erx_chan.erl test/erlang/erx_png_encode.erl
               test/erlang/erx_png_fuzz.erl].map { |path| File.join(ROOT, path) }.freeze
  DEADLINE_SECONDS = '900'

  module_function

  # In a directory of its own, which also takes the crash dump of a failed round.
  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
    Dir.mktmpdir('erx-png-fuzz') do |work|
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'),
                                       '-I', include, '-o', work,
                                       *SOURCES, stdin_data: '')
      abort(output) unless status.success?

      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-run', 'erx_png_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                                       chdir: work, stdin_data: '')
      abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
      puts output
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxPngFuzz.run(seed: seed)
end
