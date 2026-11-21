# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_fs_tests.erl, the control tree's `pair` file (erx_bt_fs_tree)
# served by a real erx_fs grant over the file service erx_bt_fs, with stand-in links and
# store (docs/design-bluetooth.md, "The pairing window"), on stock's emulator (ERX_ERL and
# ERX_ERLC), against the sources as they are and against each seeded fault, where the
# named case must fail.
class ErxBtFsTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  # The grammar is generated into OTP's preloaded sources, outside the applications, so it
  # is compiled with the cases; the stand-ins replace the erx modules the grant calls.
  TESTS = %w[
    build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl
    test/erlang/erx_bt_fs_tests.erl
    test/erlang/stand_in/erx_dist.erl
    test/erlang/stand_in/erx_connections.erl
  ].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '120'
  FS = 'erlang/apps/erx_bt/src/erx_bt_fs.erl'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: "the opening grant not monitored, so a window outlives its opener's end",
             anchor: '{reply, {ok, Id}, Opened#fs{opens = Opens#{monitor(process, Grant) => Id}}};',
             replacement: '{reply, {ok, Id}, Opened#fs{opens = Opens}};',
             catching_case: 'the_openers_end_closes_the_window_test'),
    Seed.new(fault: "the window's monitor of the link not taken, so a killed link is never counted",
             anchor: '{Answer, Fs#fs{links = Links#{Link => monitor(process, Link)}}};',
             replacement: '{Answer, Fs#fs{links = Links#{Link => make_ref()}}};',
             catching_case: 'a_killed_link_fails_the_pairing_disconnected_test'),
    Seed.new(fault: 'the waiting reads not offered the lines a step writes',
             anchor: '    {Answer, wake_up(pump(Done))}.',
             replacement: '    {Answer, wake_up(Done)}.',
             catching_case: 'a_pairing_reaches_the_opener_as_lines_test'),
    Seed.new(fault: 'the state shown whole, with its passkey line',
             anchor: '    maps:map(fun(state, #fs{core = Core}) -> erx_bt_window:facts(Core);',
             replacement: '    maps:map(fun(state, #fs{} = State) -> State;',
             catching_case: 'status_hides_the_lines_test'),
    Seed.new(fault: "the window started without the store's state, so it opens over a store that refuses changes",
             anchor: '    start_link(erx_bt_store:known()).',
             replacement: '    start_link(read).',
             catching_case: 'the_window_starts_with_the_store_and_restarts_with_it_test')
  ].freeze

  def test_pair_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, FS))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ FS => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}\.\.\.(?:(?!erx_bt_fs_tests: ).)*?\*failed\*/m,
                   output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    stand_ins = HOST_BYTES.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-bt-fs-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-kernel', 'logger', '[{handler, default, undefined}]',
                      '-eval', 'halt(case eunit:test(erx_bt_fs_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
