# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/dashboard_screen'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/screen_reference'

# The kiosk dashboard of examples/dashboard on the host: its pure parts under EUnit, and
# its screen drawn by the host's erx-lvgl compared with its reference picture. The
# example's modules compile from its own directory over erx and erx_ui (ErlangBuild), the
# applications it calls, with warnings as errors, on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies).
class ErxDashboardTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  EXAMPLE = DashboardScreen::EXAMPLE
  APPLICATIONS = DashboardScreen::APPLICATIONS
  TESTS = ["#{EXAMPLE}/test/erx_dashboard_view_tests.erl"].freeze
  DEADLINE = '300'

  def test_pure_parts_pass_under_eunit
    Dir.mktmpdir('erx-dashboard-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: DashboardScreen.example_modules + TESTS)
      output = run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                    'halt(case eunit:test(erx_dashboard_view_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                    chdir: work)
      assert_match(/All \d+ tests passed/, output)
    end
  end

  # The dashboard's screen at the display suite's size (test/display/reference/
  # display-lvgl.ppm.gz), at a fixed time with the sample board, as the host's erx-lvgl
  # draws it (DashboardScreen), against test/display/reference/dashboard.
  # ERX_RECORD_REFERENCE=1 writes the reference from the render instead, for a person who
  # has looked at the picture.
  REFERENCE = 'dashboard'
  TIME = [[2026, 11, 15], [9, 41, 0]].freeze
  def test_the_screen_is_the_reference
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    references = File.join(ROOT, 'test/display/reference')
    image = DashboardScreen.picture(TIME, runner: runner, erl: ENV.fetch('ERX_ERL'), erlc: ENV.fetch('ERX_ERLC'))
    if ENV['ERX_RECORD_REFERENCE'] == '1'
      digest, picture = Erx::ScreenReference.encode(image)
      File.write(File.join(references, "#{REFERENCE}.sha256"), digest)
      File.binwrite(File.join(references, "#{REFERENCE}.ppm.gz"), picture)
    end
    assert_nil Erx::ScreenReference.check(image, directory: references, name: REFERENCE)
  end

  private

  def run!(*command, chdir:)
    output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, *command, chdir: chdir, stdin_data: '')
    assert status.success?, output
    output
  end
end
