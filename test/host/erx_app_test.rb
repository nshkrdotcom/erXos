# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs the EUnit cases of an app's session, erx_app over a fixture /app
# (test/erlang/erx_app_tests.erl), on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies), in the code server's interactive mode, which a session's runtime runs.
#
# The fixtures are compiled here: a release directory holding erx_app_clash, an app that
# starts, and an app that ships its own erx_app_clash, whose start calls a function only
# its copy has, so it starts only if its copy is the one the code server finds.
#
# The seeded faults are a native app's: its program started without its window, and the
# program's end taken as a start, so the session would outlive its program; and a failed
# start's whole reason written to the log, where only its names may go.
class ErxAppTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  MODULE = File.join(ROOT, 'erlang/apps/erx_app/src/erx_app.erl')
  # The report filter, whose reason_name/1 is all erx_app shows of a reason it does not own.
  REPORT = File.join(ROOT, 'erlang/apps/erx/src/erx_report.erl')
  TESTS = File.join(ROOT, 'test/erlang/erx_app_tests.erl')
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')

  # Each seeded fault: a passage of erx_app and what replaces it.
  FAULTS = {
    'window dropped' => ['window(true, Spec, #{display := Display}) -> Spec#{window => Display}.',
                         'window(true, Spec, #{display := _Display}) -> Spec.'],
    'program end ignored' => ['fail({program_exit, Status});', '_ = Status, ok;'],
    'whole reason logged' => ['    {error, io_lib:format("~ts failed: ~ts", [Step, name(Reason)])};',
                              '    {error, io_lib:format("~ts failed: ~0tp", [Step, Reason])};'],
    'error text logged' => ['        {"no such file or directory", File} -> ["no ", File];',
                            '        {Error, File} -> [Error, " ", File];']
  }.freeze

  # Each fixture directory's modules and the application resource file of its app.
  FIXTURES = {
    'release/ebin' => { modules: { 'erx_app_clash' => "which() -> release.\n" } },
    'good/lib/good_app/ebin' => {
      modules: { 'good_app' => "start(_Type, _Args) -> {ok, spawn(fun() -> receive stop -> ok end end)}.\nstop(_State) -> ok.\n" },
      app: 'good_app'
    },
    'clash/lib/clash_app/ebin' => {
      modules: { 'erx_app_clash' => "which() -> app.\nonly_app() -> ok.\n",
                 'clash_app' => "start(_Type, _Args) -> ok = erx_app_clash:only_app(), {ok, self()}.\nstop(_State) -> ok.\n" },
      app: 'clash_app'
    }
  }.freeze

  def test_erx_app_cases_pass_under_eunit
    output, status = eunit
    assert status.success?, output
    assert_match(/All 12 tests passed/, output)
  end

  def test_each_seeded_fault_fails_a_case
    FAULTS.each do |name, (from, to)|
      output, status = eunit(from => to)
      refute status.success?, "#{name} passed:\n#{output}"
    end
  end

  private

  # The cases under EUnit over the fixtures, with erx_app's passages that fault names
  # replaced.
  def eunit(fault = {})
    Dir.mktmpdir('erx-app-test') do |work|
      FIXTURES.each { |directory, fixture| build(File.join(work, directory), **fixture) }
      erlc(work, faulted(work, fault), REPORT, TESTS)
      Open3.capture2e({ 'ERX_APP_CASES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work, '-eval',
                      'case eunit:test(erx_app_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.',
                      stdin_data: '', chdir: work)
    end
  end

  def faulted(work, fault)
    return MODULE if fault.empty?

    text = fault.reduce(File.read(MODULE)) do |source, (from, to)|
      assert_equal 1, source.scan(from).size, "fault passage missing: #{from}"
      source.sub(from) { to }
    end
    File.join(work, 'erx_app.erl').tap { |copy| File.write(copy, text) }
  end

  def build(directory, modules:, app: nil)
    FileUtils.mkdir_p(directory)
    sources = modules.map do |name, body|
      exports = body.scan(/^(\w+)\((.*?)\) ->/).map { |function, args| "#{function}/#{args.empty? ? 0 : args.count(',') + 1}" }
      File.join(directory, "#{name}.erl").tap do |path|
        File.write(path, "-module(#{name}).\n-export([#{exports.join(', ')}]).\n#{body}")
      end
    end
    erlc(directory, *sources)
    return unless app

    File.write(File.join(directory, "#{app}.app"),
               "{application, #{app}, [{vsn, \"1\"}, {modules, [#{modules.keys.join(', ')}]}, " \
               "{applications, [kernel, stdlib]}, {mod, {#{app}, []}}]}.\n")
  end

  def erlc(directory, *sources)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE,
                                     '-o', directory, *sources, stdin_data: '')
    assert status.success?, output
  end
end
