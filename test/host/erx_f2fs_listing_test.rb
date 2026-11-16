# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# F2FS's listing, erx_f2fs_listing (docs/design-f2fs.md, "Testing on the host"): its
# EUnit cases on stock's emulator (ERX_ERL and ERX_ERLC), over a tree the cases make on
# the host through OTP's file module and over trees held as maps.
class ErxF2fsListingTest < Minitest::Test
  TESTS = %w[test/erlang/erx_f2fs_listing.erl test/erlang/erx_f2fs_listing_tests.erl].freeze

  def test_eunit_cases_pass
    Dir.mktmpdir('erx-f2fs-listing-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_f2fs], tests: TESTS)
      dev_null = File.stat('/dev/null')
      env = { 'ERX_F2FS_DEV_NULL' => "#{dev_null.rdev_major} #{dev_null.rdev_minor}" }
      output, status =
        Open3.capture2e(env, 'gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                        'halt(case eunit:test(erx_f2fs_listing_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                        chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
