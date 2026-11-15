# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The display suite's lvgl cell client waits for the pattern client's window to end
# before it opens its UI (test/erlang/erx_kiosk_wait.erl says how). Both clients run
# on the stock OTP build the host tests use (ERX_ERL and ERX_ERLC) over stand-ins for
# erx_win and erx_memdraw, so the pattern window is presented and ends at once,
# between two of the kiosk client's looks.
class ErxKioskWaitTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # erx_kiosk_test depends on erx_pattern_test, which ErlangBuild compiles with it.
  APPLICATIONS = %w[erx_kiosk_test].freeze
  TESTS = %w[test/erlang/erx_kiosk_wait.erl].freeze
  # A window that opens, presents, and reads one typed key and one pointer record,
  # each at once.
  WIN = <<~ERLANG
    -module(erx_win).
    -export([open/2, image/1, present/2, kbd/1, mouse/1]).
    open(_Display, _Options) -> {ok, window}.
    image(window) -> {ok, image}.
    present(window, []) -> ok.
    kbd(window) -> {ok, {typed, $a}}.
    mouse(window) -> {ok, {mouse, 0, 0, 0, 0}}.
  ERLANG
  MEMDRAW = <<~ERLANG
    -module(erx_memdraw).
    -export([alloc/5, draw/8]).
    alloc(_Chan, _Rect, _Clip, _Repl, _Color) -> {ok, source}.
    draw(_Dst, _Rect, _Src, _Point, _Mask, _MaskPoint, _Op, _Order) -> {ok, 0}.
  ERLANG
  STAND_INS = { 'erlang/apps/erx_win/src/erx_win.erl' => WIN,
                'erlang/apps/erx_memdraw/src/erx_memdraw.erl' => MEMDRAW }.freeze
  EVAL = 'io:format("outcome ~p~n", [erx_kiosk_wait:run()]), halt(0)'

  def test_the_kiosk_sees_a_pattern_window_that_ended_between_its_looks
    Dir.mktmpdir('erx-kiosk-wait') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: STAND_INS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-eval', EVAL, chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/^outcome opened$/, output)
    end
  end
end
