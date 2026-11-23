# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=600

require 'fileutils'
require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/abi'

# The fuzz target of erx_draw_codec:decode/2 and erx_draw_image:decode/3, the
# decoders of what a draw client writes, and of erx_draw_core:plan/2, which
# checks a whole write against a connection (docs/design-display.md, "Draw
# messages"). The codec is generated from abi/formats/draw.txt and run with
# test/erlang/erx_draw_codec_fuzz.erl, which draws its cases from
# test/erlang/erx_draw_codec_tests.erl, on stock's emulator (ERX_ERL and
# ERX_ERLC, the oracle's).
module ErxDrawCodecFuzz
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[erlang/apps/erx_win/src/erx_draw_image.erl erlang/apps/erx_win/src/erx_draw_core.erl
               erlang/apps/erx_memdraw/src/erx_chan.erl test/erlang/erx_draw_codec_tests.erl test/erlang/erx_draw_core_tests.erl
               test/erlang/erx_draw_codec_fuzz.erl].map { |path| File.join(ROOT, path) }.freeze
  ABI_HEADER = 'erlang/apps/erx/include/generated/erx_abi.hrl'
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    generated = Erx::ABI::Generator.plan(root: ROOT).files
    Dir.mktmpdir('erx-draw-codec-fuzz') do |work|
      module_path = File.join(work, 'erx_draw_codec.erl')
      File.binwrite(module_path, generated.fetch(Erx::ABI::DrawEmitter::ERLANG_PATH))
      # erx_draw_core includes the ABI header as generated/erx_abi.hrl.
      FileUtils.mkdir_p(File.join(work, 'generated'))
      File.binwrite(File.join(work, 'generated/erx_abi.hrl'), generated.fetch(ABI_HEADER))
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-I', work,
                                       '-o', work, module_path, *SOURCES, stdin_data: '')
      abort(output) unless status.success?

      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-run', 'erx_draw_codec_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                                       chdir: work, stdin_data: '')
      abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
      puts output
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxDrawCodecFuzz.run(seed: seed)
end
