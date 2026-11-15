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

# erx_ui_host, the SDK's stand-in display (docs/design-packaging.md, "The
# SDK"), on stock's emulator (ERX_ERL and ERX_ERLC): test/erlang/erx_ui_host_check.erl
# plays an app that opens its UI with erx_ui:open/1 and drives it through
# erx_ui_host with the LVGL renderer, the host build of erx-lvgl, which the
# environment variable ERX_LVGL names. The check says what it checks; here
# its first frame must equal the reference picture
# test/display/reference/ui-host-lvgl, and the frame after the click must
# show another label.
class ErxUiHostTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx erx_ui].freeze
  HOST = 'sdk/erx_ui_host.erl'
  TESTS = [HOST, 'test/erlang/erx_ui_host_check.erl'].freeze
  REFERENCES = File.join(ROOT, 'test/display/reference')
  REFERENCE = 'ui-host-lvgl'
  WIDTH = 240
  HEIGHT = 160

  def setup
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    @program = Erx::Lvgl::Build.new(root: ROOT, runner: runner).call
  end

  def test_an_app_frame_equals_the_reference_and_input_changes_it
    Dir.mktmpdir('erx-ui-host-test') do |work|
      compile(work)
      output, status = check(work)
      assert status.success?, output
      assert_match(/before => none/, output)
      assert_match(/clicked => pressed/, output)
      Erx::ScreenReference.check(image(File.join(work, 'first.xrgb')), directory: REFERENCES, name: REFERENCE)
    end
  end

  # Seeded: frame/1 answering the window's buffer before the first present
  # fails the check, which reads `none` there.
  def test_a_frame_before_the_first_present_fails
    source = File.read(File.join(ROOT, HOST))
    seeded = source.sub('frame = none}', 'frame = read_frame(W, H, Buffer)}')
    refute_equal source, seeded, 'the seeded fault names no clause of erx_ui_host'
    Dir.mktmpdir('erx-ui-host-seeded') do |work|
      compile(work, replaced: { HOST => seeded })
      output, status = check(work)
      refute status.success?, output
      assert_match(/\{badmatch,\{ok,240,160,/, output)
    end
  end

  private

  # The applications and the check, compiled, with each application's file,
  # since erx_ui_host starts erx_ui as an app's test starts it.
  def compile(work, replaced: {})
    ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
    APPLICATIONS.each do |application|
      File.write(File.join(work, "#{application}.app"), Erx::ErlangApps.read_sources(root: ROOT, application: application).resource)
    end
  end

  def check(work)
    Open3.capture2e({ 'ERX_LVGL' => @program, 'TMPDIR' => work }, 'gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'),
                    '-noshell', '-pa', work, '-eval',
                    "io:format(\"~p~n\", [erx_ui_host_check:run(#{work.inspect})]), halt(0)",
                    chdir: work, stdin_data: '')
  end

  # A frame the check wrote, x8r8g8b8 rows from the top, as the picture it shows.
  def image(path)
    xrgb = File.binread(path)
    assert_equal WIDTH * HEIGHT * 4, xrgb.bytesize, path
    rgb = xrgb.unpack('V*').map { |pixel| [pixel >> 16, pixel >> 8, pixel].map { |c| c & 0xff } }.flatten.pack('C*')
    Erx::Ppm::Image.new(width: WIDTH, height: HEIGHT, pixels: rgb)
  end
end
