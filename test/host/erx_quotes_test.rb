# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The live quotes of examples/dashboard on the host (docs/design-quotes.md, "Verification
# and testing"): the pure modules' EUnit cases, and the live source fetching end to end
# over HTTPS from ssl servers on the loopback, reached by address, with no internet and no
# name resolved. The example's modules compile from its own
# directory over erx and erx_ui (ErlangBuild), with warnings as errors, on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies), whose ssl and inets the fetch uses.
class ErxQuotesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  EXAMPLE = 'examples/dashboard/lib/erx_dashboard'
  APPLICATIONS = %w[erx erx_ui].freeze
  SUITES = %w[erx_quotes_http_tests erx_quotes_extract_tests erx_quotes_core_tests
              erx_quotes_fetch_tests].freeze
  DEADLINE = '300'

  def test_live_quotes_pass_under_eunit
    Dir.mktmpdir('erx-quotes-test') do |work|
      tests = SUITES.map { |suite| "#{EXAMPLE}/test/#{suite}.erl" }
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: example_modules + tests)
      output = run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                    "halt(case eunit:test([#{SUITES.join(', ')}], [verbose]) of ok -> 0; _ -> 1 end).",
                    chdir: work)
      assert_match(/All \d+ tests passed/, output)
    end
  end

  private

  # The example's modules, root-relative, each behaviour before the modules that
  # implement it, the order erlc needs them in.
  def example_modules
    Dir.glob("#{EXAMPLE}/src/*.erl", base: ROOT).sort_by do |path|
      [File.foreach(File.join(ROOT, path)).any? { |line| line.start_with?('-callback ') } ? 0 : 1, path]
    end
  end

  def run!(*command, chdir:)
    output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, *command, chdir: chdir, stdin_data: '')
    assert status.success?, output
    output
  end
end
