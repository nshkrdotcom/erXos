# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/dashboard_screen'
require_relative '../../tools/lib/erx/app_pack'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/screen_reference'
require_relative '../../tools/lib/erx/sdk'

# The kiosk dashboard of examples/dashboard on the host: its pure parts under EUnit, and
# its screen drawn by the host's erx-lvgl compared with its reference picture. The
# example's modules compile from its own directory against an SDK exported from the tree
# (DashboardScreen), with warnings as errors, on the emulator beside stock's compiler
# (ERX_ERLC, which make check supplies).
class ErxDashboardTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DASHBOARD = File.join(ROOT, 'examples/dashboard')
  TESTS = [File.join(DASHBOARD, 'lib/erx_dashboard/test/erx_dashboard_view_tests.erl')].freeze
  DEADLINE = '300'

  def self.runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))

  # The SDK exported from the tree once for the test process, with stock's compiler.
  def self.sdk
    @sdk ||= begin
      work = Dir.mktmpdir('erx-dashboard-sdk-')
      Minitest.after_run { FileUtils.rm_rf(work) }
      directory = File.join(work, 'sdk')
      Erx::Sdk.new(root: ROOT, runner: runner, erlc: ENV.fetch('ERX_ERLC')).export(directory)
      Erx::AppPack::Sdk.new(root: directory, erlc: ENV.fetch('ERX_ERLC'))
    end
  end

  def test_pure_parts_pass_under_eunit
    sdk = self.class.sdk
    Dir.mktmpdir('erx-dashboard-test') do |work|
      DashboardScreen.compile(work, app: DASHBOARD, sdk: sdk, runner: self.class.runner, tests: TESTS)
      output = run!(sdk.erl, '-noshell', *DashboardScreen.code_path(work, sdk: sdk), '-eval',
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
    references = File.join(ROOT, 'test/display/reference')
    image = DashboardScreen.picture(TIME, app: DASHBOARD, sdk: self.class.sdk, runner: self.class.runner)
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
