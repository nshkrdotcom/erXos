# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/lvgl'
require_relative '../../tools/lib/erx/ppm'
require_relative '../../tools/lib/erx/screen_reference'

# The kiosk dashboard of examples/dashboard on the host: its pure parts under EUnit, and
# its screen drawn by the host's erx-lvgl compared with its reference picture. The
# example's modules compile from its own directory over erx and erx_ui (ErlangBuild), the
# applications it calls, with warnings as errors, on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies).
class ErxDashboardTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  EXAMPLE = 'examples/dashboard/lib/erx_dashboard'
  APPLICATIONS = %w[erx erx_ui].freeze
  TESTS = ["#{EXAMPLE}/test/erx_dashboard_view_tests.erl"].freeze
  SCREEN = %w[test/erlang/erx_lvgl_screen.erl].freeze
  LAUNCHER = File.join(ROOT, 'test/fixtures/erx_lvgl_buffer.rb')
  DEADLINE = '300'

  def test_pure_parts_pass_under_eunit
    Dir.mktmpdir('erx-dashboard-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: example_modules + TESTS)
      output = run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                    'halt(case eunit:test(erx_dashboard_view_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                    chdir: work)
      assert_match(/All \d+ tests passed/, output)
    end
  end

  # The dashboard's screen at the display suite's size (test/display/reference/
  # display-lvgl.ppm.gz), at a fixed time with the sample board, as the host's erx-lvgl
  # draws it, against test/display/reference/dashboard. ERX_RECORD_REFERENCE=1 writes
  # the reference from the render instead, for a person who has looked at the picture.
  REFERENCE = 'dashboard'
  WIDTH = 1280
  HEIGHT = 800
  MODEL = '#{time => {{2026, 11, 15}, {9, 41, 0}}, board => erx_dashboard_sample:board()}'
  def test_the_screen_is_the_reference
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    program = Erx::Lvgl::Build.new(root: ROOT, runner: runner).call
    references = File.join(ROOT, 'test/display/reference')
    Dir.mktmpdir('erx-dashboard-screen') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: SCREEN + example_modules)
      run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
           "ok = file:write_file(\"picture.rgb\", erx_lvgl_screen:picture(#{screen(program)}, " \
           "erx_dashboard_view:tree(#{MODEL}), {#{WIDTH}, #{HEIGHT}})), halt(0)",
           chdir: work)
      image = Erx::Ppm::Image.new(width: WIDTH, height: HEIGHT, pixels: File.binread(File.join(work, 'picture.rgb')))
      if ENV['ERX_RECORD_REFERENCE'] == '1'
        digest, picture = Erx::ScreenReference.encode(image)
        File.write(File.join(references, "#{REFERENCE}.sha256"), digest)
        File.binwrite(File.join(references, "#{REFERENCE}.ppm.gz"), picture)
      end
      assert_nil Erx::ScreenReference.check(image, directory: references, name: REFERENCE)
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

  # The model screen's map of the program and how to start it, as an Erlang term.
  def screen(program)
    pairs = { program: program, ruby: RbConfig.ruby, launcher: LAUNCHER }.map { |key, path| "#{key} => #{path.inspect}" }
    "\#{#{pairs.join(', ')}}"
  end

  def run!(*command, chdir:)
    output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, *command, chdir: chdir, stdin_data: '')
    assert status.success?, output
    output
  end
end
