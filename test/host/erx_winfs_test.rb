# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/host_os'
require_relative '../../tools/lib/erx/memdraw_build'

# Runs test/erlang/erx_winfs_tests.erl: erx_winfs, erx_window, erx_screen and erx_fb_sup's
# start of erx_winfs, with the erx_fs grants of erx_files, on stock's emulator with
# erx_memdraw's NIF built for the host (Erx::MemdrawBuild.nif), whose stand-in pixel
# area the windows present from.
class ErxWinfsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OTP = File.join(ROOT, 'build/oracle/jit/install/lib/erlang')
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  GRAMMAR = 'build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl'
  DISPLAY = %w[erx_display erx_screen erx_screen_core erx_wctl erx_window erx_winctl erx_winfs erx_wm
               erx_wm_single erx_wm_rio erx_input].map { |name| "erlang/apps/erx_display/src/#{name}.erl" } +
            %w[build/gen/erlang/apps/erx_display/src/erx_keymap.erl build/gen/erlang/apps/erx/src/generated/erx_input_codec.erl
               build/gen/erlang/apps/erx_memdraw/src/erx_theme.erl]
  FILES = %w[erx_fs erx_fs_grant erx_fs_grants erx_fs_node erx_fs_version].map { |name| "erlang/apps/erx_files/src/#{name}.erl" } +
          ['erlang/apps/erx/src/erx_fs_waits.erl']
  MODULES = (['erlang/apps/erx_memdraw/src/erx_memdraw.erl', 'erlang/apps/erx_memdraw/src/erx_chan.erl', GRAMMAR] + DISPLAY + FILES +
             ['erlang/apps/erx/src/erx_facet.erl', 'erlang/apps/erx_fb/src/erx_fb_sup.erl', 'test/erlang/erx_winfs_tests.erl']).freeze
  # The display's log is the debug log of erx_log's NIF, which stock's emulator has not.
  LOG_STUB = <<~ERLANG
    -module(erx_log).
    -export([debug/1]).
    debug(_Message) -> ok.
  ERLANG
  DEADLINE_SECONDS = '300'
  WINFS = 'erlang/apps/erx_display/src/erx_winfs.erl'
  # The seeded fault: the layout handed to the screen only after a message that changed the
  # table, so a pick that changes none leaves the border where it was.
  PRESENT = '    Presented = present(Next),'
  TABLE_ONLY = '    Presented = case Next#winfs.windows =:= State#winfs.windows of ' \
               'true -> Next; false -> present(Next) end,'
  CLICK_CASE = '{generator, erx_winfs_tests, the_overlapping_policy_s_click_moves_the_border_and_the_keyboard_together_test_}'
  # The seeded fault: a read of kbd or mouse that waits for its record inside the tree's
  # callback, in the grant, instead of at the window process.
  STREAM_READ = '    {wait, Proc, {read, File, Count}};'
  READ_IN_CALLBACK = '    receive {erx_window_record, Record} -> {ok, Record} end;'
  WAITING_CASE = '{generator, erx_winfs_tests, a_waiting_kbd_read_holds_up_nothing_of_its_grant_test_}'

  def setup
    skip 'stock OTP not built: make oracle-bootstrap' unless File.directory?(OTP)
    @directory = Dir.mktmpdir('erx-winfs-')
  end

  def teardown
    FileUtils.rm_rf(@directory) if @directory
  end

  def test_window_system_cases
    text, status = eunit('erx_winfs_tests')
    assert status.success?, text
    assert_match(/All \d+ tests passed/, text)
  end

  # docs/design-display.md, "Verification and testing", the window system: an erx_winfs that
  # hands over the layout only when the table changes fails the click case.
  def test_a_layout_handed_over_only_on_a_table_change_fails_the_click_case
    source = File.read(File.join(ROOT, WINFS))
    raise "#{WINFS} no longer holds #{PRESENT.inspect}" unless source.include?(PRESENT)

    text, status = eunit(CLICK_CASE, replaced: { WINFS => source.sub(PRESENT, TABLE_ONLY) })
    refute status.success?, text
    assert_match(/click_picks/, text)
  end

  # docs/design-display.md, "The window tree": a kbd read that waits inside the callback
  # holds up its grant, so the write on another fid gets no reply.
  def test_a_read_waiting_in_the_callback_fails_the_waiting_case
    source = File.read(File.join(ROOT, WINFS))
    raise "#{WINFS} no longer holds #{STREAM_READ.inspect}" unless source.include?(STREAM_READ)

    text, status = eunit(WAITING_CASE, replaced: { WINFS => source.sub(STREAM_READ, READ_IN_CALLBACK) })
    refute status.success?, text
    assert_match(/no_reply,\{write,2/, text)
  end

  private

  # Compiles the modules, with each path of Replaced compiled from its text instead, and
  # runs the EUnit Tests.
  def eunit(tests, replaced: {})
    Erx::MemdrawBuild.nif(root: ROOT, otp: OTP, directory: @directory, compiler: COMPILER)
    File.write(File.join(@directory, 'erx_log.erl'), LOG_STUB)
    sources = MODULES.map do |path|
      next File.join(ROOT, path) unless replaced.key?(path)

      File.join(@directory, File.basename(path)).tap { |copy| File.write(copy, replaced.fetch(path)) }
    end
    sources << File.join(@directory, 'erx_log.erl')
    text, status = Open3.capture2e(Erx::MemdrawBuild::CLEAN_ENVIRONMENT, File.join(OTP, 'bin/erlc'),
                                   '-I', INCLUDE, '-I', File.join(ROOT, 'erlang/apps/erx_display/src'), '-I', File.join(ROOT, 'erlang/apps/erx/include'),
                                   '-o', @directory, *sources, stdin_data: '')
    assert status.success?, text
    environment = Erx::MemdrawBuild::CLEAN_ENVIRONMENT.merge(Erx::HostOs.nif_search_environment(@directory))
    Open3.capture2e(environment, 'gtimeout', '-k', '10', DEADLINE_SECONDS, File.join(OTP, 'bin/erl'),
                    '-noshell', '-pa', @directory, '-eval',
                    "case eunit:test(#{tests}, [verbose]) of ok -> halt(0); _ -> halt(1) end.",
                    chdir: @directory, stdin_data: '')
  end
end
