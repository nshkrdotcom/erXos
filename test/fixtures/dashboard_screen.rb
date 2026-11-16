# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'rbconfig'
require 'tmpdir'
require_relative 'erlang_build'
require_relative '../../tools/lib/erx/lvgl'
require_relative '../../tools/lib/erx/ppm'

# The kiosk dashboard's screen (examples/dashboard) with the sample board at a given
# wall-clock minute, as the host's erx-lvgl draws it at the display suite's size: the
# picture the host test compares with test/display/reference/dashboard and the kiosk
# cell (tools/lib/erx/kiosk.rb) compares the guest's screen with. The example's
# modules compile from its own directory over erx and erx_ui (ErlangBuild) with stock's
# compiler, and the screen model (test/erlang/erx_lvgl_screen.erl) runs on stock's
# emulator.
module DashboardScreen
  ROOT = File.expand_path('../..', __dir__)
  EXAMPLE = 'examples/dashboard/lib/erx_dashboard'
  APPLICATIONS = %w[erx erx_ui].freeze
  SCREEN = %w[test/erlang/erx_lvgl_screen.erl].freeze
  LAUNCHER = File.join(ROOT, 'test/fixtures/erx_lvgl_buffer.rb')
  WIDTH = 1280
  HEIGHT = 800
  DEADLINE = 300

  module_function

  # The screen at time, [[year, month, day], [hour, minute, second]], as an Erx::Ppm::Image,
  # erl and erlc being stock's emulator and compiler.
  def picture(time, runner:, erl:, erlc:)
    program = Erx::Lvgl::Build.new(root: ROOT, runner: runner).call
    Dir.mktmpdir('erx-dashboard-screen') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: SCREEN + example_modules, erlc: erlc)
      runner.run([erl, '-noshell', '-pa', work, '-eval',
                  "ok = file:write_file(\"picture.rgb\", erx_lvgl_screen:picture(#{screen(program)}, " \
                  "erx_dashboard_view:tree(#{model(time)}), {#{WIDTH}, #{HEIGHT}})), halt(0)"],
                 name: 'dashboard-screen', deadline: DEADLINE, chdir: work, env: Erx::Oracle::CLEAN_ERLANG_ENV)
      Erx::Ppm::Image.new(width: WIDTH, height: HEIGHT, pixels: File.binread(File.join(work, 'picture.rgb')))
    end
  end

  # The example's modules, root-relative, each behaviour before the modules that
  # implement it, the order erlc needs them in.
  def example_modules
    Dir.glob("#{EXAMPLE}/src/*.erl", base: ROOT).sort_by do |path|
      [File.foreach(File.join(ROOT, path)).any? { |line| line.start_with?('-callback ') } ? 0 : 1, path]
    end
  end

  # The view's model at time with the sample board, as an Erlang term.
  def model(time)
    (year, month, day), (hour, minute, second) = time
    "\#{time => {{#{Integer(year)}, #{Integer(month)}, #{Integer(day)}}, " \
      "{#{Integer(hour)}, #{Integer(minute)}, #{Integer(second)}}}, board => erx_dashboard_sample:board()}"
  end

  # The model screen's map of the program and how to start it, as an Erlang term.
  def screen(program)
    pairs = { program: program, ruby: RbConfig.ruby, launcher: LAUNCHER }.map { |key, path| "#{key} => #{path.inspect}" }
    "\#{#{pairs.join(', ')}}"
  end
end
