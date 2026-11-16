# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/host_os'
require_relative '../../tools/lib/erx/memdraw_build'

# Runs test/erlang/erx_win_core_tests.erl, the readers and lines of erx_win_core,
# test/erlang/erx_win_tests.erl, erx_win with erx_pixels against erx_winfs, erx_window
# and erx_screen, and test/erlang/erx_draw_tests.erl, erx_draw and its draw connection
# on such a window, on stock's emulator with erx_memdraw's NIF built for the host
# (Erx::MemdrawBuild.nif). erx's registry, erx_area and erx_log are stand-ins written
# here, the stand-in erx_area's leases returned by a process that watches the holder,
# and erx_win's fids, which prim_file draws on erXos, come from a counter of the
# emulator's. Then each seeded fault, applied to a copy of its module, must fail the
# case named for it.
class ErxWinTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  OTP = File.join(ROOT, 'build/oracle/jit/install/lib/erlang')
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  INCLUDES = %w[otp/lib/kernel/include build/gen/erlang/apps/erx/include erlang/apps/erx/include].map { |dir| File.join(ROOT, dir) }.freeze
  DISPLAY = %w[erx_display erx_screen erx_screen_core erx_wctl erx_window erx_winctl erx_winfs erx_wm
               erx_wm_single erx_input].map { |name| "erlang/apps/erx_display/src/#{name}.erl" } +
            %w[build/gen/erlang/apps/erx_display/src/erx_keymap.erl build/gen/erlang/apps/erx/src/generated/erx_input_codec.erl]
  FILES = %w[erx_fs erx_fs_grant erx_fs_grants erx_fs_node erx_fs_version].map { |name| "erlang/apps/erx_files/src/#{name}.erl" } +
          ['erlang/apps/erx/src/erx_fs_waits.erl']
  CONN_SOURCE = 'erlang/apps/erx_win/src/erx_draw_conn.erl'
  CLIENT = %w[erx_win_core erx_win_sup erx_pixels erx_pixels_core erx_draw erx_draw_core
              erx_draw_image].map { |name| "erlang/apps/erx_win/src/#{name}.erl" } + [CONN_SOURCE]
  # The program's own /dev over this window system (test/erlang/erx_win_dev_tests.erl).
  DEV = %w[erlang/apps/erx_session/src/erx_session_export.erl erlang/apps/erx/src/erx_prog_handler_core.erl].freeze
  TESTS = %w[erx_win_core_tests erx_win_tests erx_draw_tests erx_win_dev_tests].freeze
  MODULES = (%w[erlang/apps/erx_memdraw/src/erx_memdraw.erl erlang/apps/erx_memdraw/src/erx_chan.erl
                build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl otp/erts/preloaded/src/erx_file_remote.erl
                erlang/apps/erx/src/erx_facet.erl] + DISPLAY + FILES + CLIENT + DEV +
             TESTS.map { |name| "test/erlang/#{name}.erl" }).freeze
  FID = 'prim_file:erx_fid()'
  STAND_INS = {
    'erx_log' => <<~ERLANG,
      -module(erx_log).
      -export([debug/1]).
      debug(_Message) -> ok.
    ERLANG
    'erx' => <<~ERLANG,
      -module(erx).
      -export([cap/1, owner/1]).
      cap(Name) -> persistent_term:get({erx_stand_in, cap, Name}, undefined).
      owner(Pid) -> persistent_term:get({erx_stand_in, owner, Pid}).
    ERLANG
    'erx_area' => <<~ERLANG
      -module(erx_area).
      -export([open/1, zero/3, lend/5, unlend/1]).
      open(Peer) -> persistent_term:get({erx_area_stand_in, Peer}, {error, none}).
      zero(_Area, _Offset, _Pages) -> ok.
      %% A held lease: returned to the lender at its holder's exit or its give-back.
      lend(_Area, _Offset, _Pages, Holder, Tag) ->
          Lender = self(),
          Lease = erlang:unique_integer([positive]),
          Watcher = spawn(fun() ->
                                  Monitor = monitor(process, Holder),
                                  receive {'DOWN', Monitor, _, _, _} -> ok; unlend -> ok end,
                                  Lender ! {erx_area_returned, Tag, Lease}
                          end),
          persistent_term:put({erx_area_stand_in, lease, Lease}, Watcher),
          {ok, Lease}.
      unlend(Lease) ->
          persistent_term:get({erx_area_stand_in, lease, Lease}) ! unlend,
          ok.
    ERLANG
  }.freeze
  DEADLINE_SECONDS = '300'

  Seed = Data.define(:fault, :path, :anchor, :replacement, :suite, :catching_case)

  SEEDS = [
    Seed.new(fault: 'a dirty list that holds a seventeenth rectangle',
             path: 'erlang/apps/erx_win/src/erx_win_core.erl',
             anchor: 'add_dirty(Rect, Dirty) when length(Dirty) < ?ERX_WINDOWS_PRESENT_RECTS',
             replacement: 'add_dirty(Rect, Dirty) when length(Dirty) =< ?ERX_WINDOWS_PRESENT_RECTS',
             suite: 'erx_win_core_tests',
             catching_case: 'seventeenth_dirty_rectangle_yields_its_bounding_box_test'),
    Seed.new(fault: 'a connection that keeps one image past its end',
             path: CONN_SOURCE,
             anchor: '{ok, Image} -> {ok, Conn#conn{images = Images#{Id => Image}}};',
             replacement: '{ok, Image} -> persistent_term:put({erx_draw_conn_leak, self()}, Image), ' \
                          '{ok, Conn#conn{images = Images#{Id => Image}}};',
             suite: 'erx_draw_tests',
             catching_case: 'a_connection_frees_its_images_when_its_window_ends_test'),
    Seed.new(fault: "a refused write that applies the messages before the refused one, as devdraw's does",
             path: CONN_SOURCE,
             anchor: "{Core, [{error, Errno, Offset}]} ->\n",
             replacement: "{Core, [{error, Errno, Offset}]} ->\n" \
                          '_ = perform_write(element(2, erx_draw_core:plan(Core, binary:part(Bytes, 0, Offset))), ' \
                          "Conn),\n",
             suite: 'erx_draw_tests',
             catching_case: 'a_refused_write_applies_nothing_test'),
    Seed.new(fault: 'a connection that draws into its window without a lease of the buffer',
             path: CONN_SOURCE,
             anchor: '{ok, _Lease, _Pages} ?= erx_win:lease(Window, Opener),',
             replacement: '',
             suite: 'erx_draw_tests',
             catching_case: 'the_connection_never_draws_into_the_next_window_test'),
    Seed.new(fault: 'a clipboard open whose refused lopen keeps its walked fid',
             path: 'erlang/apps/erx_win/src/erx_win.erl',
             anchor: '{error, _} = Refused -> clunk(Tree, [Fid]), Refused;',
             replacement: '{error, _} = Refused -> Refused;',
             suite: 'erx_win_dev_tests',
             catching_case: 'the_clipboard_opens_on_a_fid_of_its_own_test'),
    Seed.new(fault: "a connection that answers a program's r record before it remakes image 0",
             path: CONN_SOURCE,
             anchor: 'answer(Wait, Answer, Remade)',
             replacement: '_ = Remade, answer(Wait, Answer, Conn)',
             suite: 'erx_win_dev_tests',
             catching_case: 'a_resize_reaches_ctl_before_the_program_sees_its_r_test'),
    Seed.new(fault: "a program's kbd read that waits for its record inside the callback",
             path: 'erlang/apps/erx_session/src/erx_session_export.erl',
             anchor: "read({File, _}, Offset, Count, \#{window := \#{conn := Conn}}) when File =:= kbd; File =:= mouse ->\n" \
                     "    %% A read that waits for a record waits at the draw connection, its keeper.\n" \
                     "    {wait, Conn, {read, File, Offset, Count}};\n",
             replacement: '',
             suite: 'erx_win_dev_tests',
             catching_case: 'a_waiting_kbd_read_holds_up_nothing_of_its_grant_test'),
    Seed.new(fault: "a connection that never sends a program's flush on to the display",
             path: CONN_SOURCE,
             anchor: '{begun, Wait, _Read, Flushing} -> {noreply, flush(Wait, Conn#conn{waits = Flushing})};',
             replacement: '{begun, _Wait, _Read, Flushing} -> {noreply, Conn#conn{waits = Flushing}};',
             suite: 'erx_win_dev_tests',
             catching_case: 'a_waiting_kbd_read_holds_up_nothing_of_its_grant_test'),
    Seed.new(fault: "a connection that sends every read of its program on to the display at once",
             path: CONN_SOURCE,
             anchor: 'Sent = [Of || {Of, _Id} <- maps:values(Reads), Of =:= File],',
             replacement: 'Sent = [],',
             suite: 'erx_win_dev_tests',
             catching_case: 'waiting_kbd_reads_on_two_windows_leave_the_display_grant_free_test'),
    Seed.new(fault: "a connection that sends a read waiting behind another on to the display",
             path: CONN_SOURCE,
             anchor: 'Sent = [Of || {Of, _Id} <- maps:values(Reads), Of =:= File],',
             replacement: 'Sent = [],',
             suite: 'erx_win_dev_tests',
             catching_case: 'a_read_flushed_behind_another_never_reaches_the_display_test'),
    Seed.new(fault: "a program's handler that outlives its draw connection",
             path: 'erlang/apps/erx_session/src/erx_session_export.erl',
             anchor: "        true = link(Conn),\n",
             replacement: '',
             suite: 'erx_win_dev_tests',
             catching_case: 'the_handler_and_its_dev_end_at_the_connection_s_end_test'),
    Seed.new(fault: 'a window that hands a kbd read any record, whatever its count',
             path: 'erlang/apps/erx_display/src/erx_window.erl',
             anchor: '[{Wait, Count} || {Wait, {read, Of, Count}, waiting} <- erx_fs_waits:list(Waits),',
             replacement: '[{Wait, 64} || {Wait, {read, Of, _}, waiting} <- erx_fs_waits:list(Waits),',
             suite: 'erx_win_tests',
             catching_case: 'a_short_kbd_read_leaves_its_record_test')
  ].freeze

  def setup
    skip 'stock OTP not built: make oracle-bootstrap' unless File.directory?(OTP)
    @directory = Dir.mktmpdir('erx-win-')
  end

  def teardown
    FileUtils.rm_rf(@directory) if @directory
  end

  def test_client_cases
    build
    text, status = eunit(TESTS)
    assert status.success?, text
    assert_match(/All \d+ tests passed/, text)
  end

  def test_each_seeded_fault_fails_its_case
    sources = SEEDS.to_h do |seed|
      source = File.read(File.join(ROOT, seed.path))
      assert_equal 1, source.scan(seed.anchor).size, "anchor for #{seed.fault} is not once in #{seed.path}"
      [seed, source]
    end
    build
    runs = SEEDS.each_with_index.map do |seed, index|
      seeded = Dir.mktmpdir("erx-win-seed#{index}-", @directory)
      FileUtils.cp(Dir.glob(File.join(@directory, '*.{beam,so}')), seeded)
      copy = File.join(seeded, File.basename(seed.path))
      # erx_win's fids come from the emulator's counter here, seeded or not (stand_ins).
      File.write(copy, sources.fetch(seed).sub(seed.anchor, seed.replacement).sub(FID, 'erlang:unique_integer([positive])'))
      erlc(seeded, [copy])
      Thread.new { [seed, *eunit([seed.suite], directory: seeded)] }
    end
    runs.map(&:value).each do |seed, output, status|
      refute status.success?, "#{seed.fault} passed every case:\n#{output}"
      assert_includes failed_cases(seed.suite, output), seed.catching_case,
                      "#{seed.catching_case} did not catch #{seed.fault}"
    end
  end

  private

  # The cases of suite EUnit reports failed or timed out: each case's report runs from
  # its "suite: case..." line to the next, with the fixture's crash reports in between.
  def failed_cases(suite, output)
    output.split(/^  #{suite}: /).drop(1).filter_map do |report|
      report[/\A\w+/] if report.include?('*failed*') || report.include?('*timed out*')
    end
  end

  # The NIF, the generated draw codec, MODULES and the stand-ins, compiled into @directory.
  def build
    Erx::MemdrawBuild.nif(root: ROOT, otp: OTP, directory: @directory, compiler: COMPILER)
    codec = File.join(@directory, 'erx_draw_codec.erl')
    File.write(codec, Erx::ABI::Generator.plan(root: ROOT).files.fetch(Erx::ABI::DrawEmitter::ERLANG_PATH))
    erlc(@directory, MODULES.map { |path| File.join(ROOT, path) } + stand_ins + [codec])
  end

  def erlc(directory, sources)
    text, status = Open3.capture2e(Erx::MemdrawBuild::CLEAN_ENVIRONMENT, File.join(OTP, 'bin/erlc'),
                                   *INCLUDES.flat_map { |dir| ['-I', dir] }, '-o', directory, *sources,
                                   stdin_data: '')
    assert status.success?, text
  end

  # The output and status of EUnit over modules, with the beams and the NIF of directory.
  def eunit(modules, directory: @directory)
    environment = Erx::MemdrawBuild::CLEAN_ENVIRONMENT.merge(Erx::HostOs.nif_search_environment(directory))
    Open3.capture2e(environment, 'gtimeout', '-k', '10', DEADLINE_SECONDS, File.join(OTP, 'bin/erl'),
                    '-noshell', '-pa', directory, '-eval',
                    "case eunit:test([#{modules.join(', ')}], [verbose]) of ok -> halt(0); _ -> halt(1) end.",
                    chdir: directory, stdin_data: '')
  end

  # The stand-ins, and erx_win with its fids drawn from a counter of stock's emulator.
  def stand_ins
    client = File.read(File.join(ROOT, 'erlang/apps/erx_win/src/erx_win.erl'))
    raise "no #{FID} in erx_win.erl" unless client.include?(FID)

    STAND_INS.merge('erx_win' => client.sub(FID, 'erlang:unique_integer([positive])')).map do |name, text|
      File.join(@directory, "#{name}.erl").tap { |path| File.write(path, text) }
    end
  end
end
