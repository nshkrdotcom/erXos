# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/lib/erx/lvgl'
require_relative '../../tools/lib/erx/oracle'
require_relative '../../tools/lib/erx/ppm'

# The kiosk dashboard's screen with the sample board at a given wall-clock minute, as the
# host's erx-lvgl draws it at the display suite's size: the picture the host test compares
# with test/display/reference/dashboard and the kiosk cell (tools/lib/erx/kiosk.rb)
# compares the guest's screen with. The caller names the dashboard's app directory and an
# SDK exported from the tree (Erx::AppPack::Sdk); the app's modules compile with the SDK's
# erlc against the SDK's applications alone, as a third party's build does
# (docs/design-packaging.md, "Examples"), and the screen model
# (test/erlang/erx_lvgl_screen.erl) runs on the SDK's erl over them.
module DashboardScreen
  ROOT = File.expand_path('../..', __dir__)
  SCREEN = File.join(ROOT, 'test/erlang/erx_lvgl_screen.erl')
  LAUNCHER = File.join(ROOT, 'test/fixtures/erx_lvgl_buffer.rb')
  FLAGS = %w[-Werror +debug_info].freeze
  WIDTH = 1280
  HEIGHT = 800
  DEADLINE = 300

  module_function

  # The screen at time, [[year, month, day], [hour, minute, second]], as an Erx::Ppm::Image,
  # of the dashboard at app over sdk.
  def picture(time, app:, sdk:, runner:)
    program = Erx::Lvgl::Build.new(root: ROOT, runner: runner).call
    Dir.mktmpdir('erx-dashboard-screen') do |work|
      compile(work, app: app, sdk: sdk, runner: runner, tests: [SCREEN])
      runner.run([sdk.erl, '-noshell', *code_path(work, sdk: sdk), '-eval',
                  "ok = file:write_file(\"picture.rgb\", erx_lvgl_screen:picture(#{screen(program)}, " \
                  "erx_dashboard_view:tree(#{model(time)}), {#{WIDTH}, #{HEIGHT}})), halt(0)"],
                 name: 'dashboard-screen', deadline: DEADLINE, chdir: work, env: Erx::Oracle::CLEAN_ERLANG_ENV)
      Erx::Ppm::Image.new(width: WIDTH, height: HEIGHT, pixels: File.binread(File.join(work, 'picture.rgb')))
    end
  end

  # Compiles the dashboard's modules at app, then tests (absolute paths of further
  # modules), into work, an existing directory, with sdk's erlc against sdk's
  # applications, warnings as errors; returns work.
  def compile(work, app:, sdk:, runner:, tests: [])
    runner.run([sdk.erlc, *FLAGS, '-o', work, *code_path(work, sdk: sdk), *modules(app), *tests],
               name: 'dashboard-compile', deadline: DEADLINE, env: Erx::Oracle::CLEAN_ERLANG_ENV)
    work
  end

  # The code path of what compile wrote into work: work first, the SDK's applications
  # after it.
  def code_path(work, sdk:) = ['-pa', work, *sdk.ebins.flat_map { ['-pz', it] }]

  # The modules of the applications at app, each behaviour before the modules that implement
  # it, the order erlc needs them in.
  def modules(app)
    Dir.glob(File.join(app, 'lib/*/src/*.erl')).sort_by do |path|
      [File.foreach(path).any? { |line| line.start_with?('-callback ') } ? 0 : 1, path]
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
