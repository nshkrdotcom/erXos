# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs the EUnit cases of an app's session, erx_app over a fixture /app
# (test/erlang/erx_app_tests.erl), on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies), in the code server's interactive mode, which a session's runtime runs.
#
# The fixtures are compiled here: a release directory holding erx_app_clash, an app that
# starts, and an app that ships its own erx_app_clash, whose start calls a function only
# its copy has, so it starts only if its copy is the one the code server finds.
class ErxAppTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[erlang/apps/erx_app/src/erx_app.erl test/erlang/erx_app_tests.erl].map { |path| File.join(ROOT, path) }.freeze

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
    Dir.mktmpdir('erx-app-test') do |work|
      FIXTURES.each { |directory, fixture| build(File.join(work, directory), **fixture) }
      erlc(work, *SOURCES)
      output, status = Open3.capture2e({ 'ERX_APP_CASES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                                       '-noshell', '-pa', work, '-eval',
                                       'case eunit:test(erx_app_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.',
                                       stdin_data: '', chdir: work)
      assert status.success?, output
      assert_match(/All 5 tests passed/, output)
    end
  end

  private

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
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-Werror', '-o', directory, *sources,
                                     stdin_data: '')
    assert status.success?, output
  end
end
