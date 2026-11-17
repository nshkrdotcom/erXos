# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of the dashboard's live quotes (examples/dashboard, docs/design-quotes.md,
# "The fuzz target"): erx_quotes_fuzz drives the body reader, over each source of the table
# (erx_quotes_table), the history reader with its join into a series (erx_quotes_core), and the
# answer classifier with untrusted input, compiled from source and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's). It runs the sources as they are, then a copy of erx_quotes_extract without the price's upper bound, which must
# fail: 1.0e300 would then be shown as a price.
module ErxQuotesFuzz
  ROOT = File.expand_path('../..', __dir__)
  EXAMPLE = 'examples/dashboard/lib/erx_dashboard'
  EXTRACT = "#{EXAMPLE}/src/erx_quotes_extract.erl"
  SOURCES = %W[#{EXAMPLE}/src/erx_quotes_table.erl #{EXAMPLE}/src/erx_quotes_http.erl
               #{EXAMPLE}/src/erx_quotes_core.erl
               #{EXAMPLE}/test/erx_quotes_extract_tests.erl #{EXAMPLE}/test/erx_quotes_fuzz.erl].freeze
  BOUND = 'Price when Price >= ?MIN_PRICE, Price < ?MAX_PRICE'
  NO_BOUND = 'Price when Price >= ?MIN_PRICE'
  DEADLINE_SECONDS = '300'
  # A price past the bound is shown (out_of_bounds, or bad_entries for a history's close), or one
  # past a float's range raises in price/1.
  VERDICT = /out_of_bounds|bad_entries|erx_quotes_extract,price,1/

  module_function

  def run(seed:)
    extract = File.binread(File.join(ROOT, EXTRACT))
    raise "no bound in #{EXTRACT}" unless extract.include?(BOUND)

    output, status = fuzz(extract, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ bodies accepted, \d+ histories accepted$/)
    output, status = fuzz(extract.sub(BOUND, NO_BOUND), seed: seed)
    abort("a price past the bound passed:\n#{output}") if status.success? || !output.match?(VERDICT)
    puts 'the live quotes read every body and answer without raising or making an atom, ' \
         'and a price past 10^15 does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(extract_text, seed:)
    Dir.mktmpdir('erx-quotes-fuzz') do |work|
      extract_path = File.join(work, File.basename(EXTRACT))
      File.binwrite(extract_path, extract_text)
      sources = [extract_path, *SOURCES.map { |source| File.join(ROOT, source) }]
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, *sources, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_quotes_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxQuotesFuzz.run(seed: seed)
end
