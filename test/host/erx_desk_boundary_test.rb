# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/sdk'

# D1's source check (docs/design-desktop-programs.md, D1): every call erx_desk's modules
# make into an erXos module is one of sdk/public.txt's functions or erx:inspect/2. It runs
# the SDK's boundary check, test/erlang/erx_sdk_boundary.erl, over erx_desk compiled from
# source with debug information, beside the applications it depends on, against those
# functions, and pins the calls whose callee the check cannot name to VARIABLE. A
# whole-module line of public.txt, erx_win's, is left out: erx_desk draws nothing itself,
# so the check is only stricter for it.
class ErxDeskBoundaryTest < Minitest::Test
  ROOT = ErlangBuild::ROOT
  DESK = File.join(ROOT, 'erlang/apps/erx_desk/src')
  CLOCK = 'erx_desk_clock_core.erl'
  DEADLINE = '120'
  # The calls whose callee the check cannot name, each reviewed, as xref names them. The
  # window calls the injected inspector, its one injected effect (fun erx:inspect/2 under
  # erx_desk_sup, a model in tests), in effect/2; its core's init/1, view/1 and step/2 by
  # module name, so a reload reaches the newest version; and each worker's answer, a fun
  # it built itself, in worker/4. Stats' core applies a fun it builds itself in combine/2.
  # A new call through a variable fails the check until it is reviewed and listed here.
  VARIABLE = "[{{erx_desk_stats_core,combine,2},{'$M_EXPR','$F_EXPR',1}}," \
             "{{erx_desk_window,effect,2},{'$M_EXPR','$F_EXPR',2}}," \
             "{{erx_desk_window,init,3},{'$M_EXPR',init,1}}," \
             "{{erx_desk_window,present,1},{'$M_EXPR',view,1}}," \
             "{{erx_desk_window,stepped,2},{'$M_EXPR',step,2}}," \
             "{{erx_desk_window,worker,4},{'$M_EXPR','$F_EXPR',0}}]"

  def test_erx_desk_calls_only_the_public_surface
    assert_equal "{[],#{VARIABLE}}", outside
  end

  def test_a_call_of_the_inspector_router_fails_the_check
    seeded = File.read(File.join(DESK, CLOCK))
                 .sub('-export([init/1, step/2, view/1, next_deadline/1]).',
                      "-export([init/1, step/2, view/1, next_deadline/1, seeded/1]).") +
             "\nseeded(Query) -> erx_inspector:route(false, undefined, Query, 1).\n"
    assert_includes outside(CLOCK => seeded), '{{erx_desk_clock_core,seeded,1},{erx_inspector,route,4}}'
  end

  def test_a_call_through_a_variable_module_fails_the_check
    seeded = File.read(File.join(DESK, CLOCK))
                 .sub('-export([init/1, step/2, view/1, next_deadline/1]).',
                      "-export([init/1, step/2, view/1, next_deadline/1, seeded/1]).") +
             "\nseeded(Router) -> Router:route(false, undefined, [], 1).\n"
    answer = outside(CLOCK => seeded)
    assert_includes answer, "{{erx_desk_clock_core,seeded,1},{'$M_EXPR',route,4}}"
    refute_equal "{[],#{VARIABLE}}", answer
  end

  private

  # The boundary check's answer, printed by Erlang, with the sources of Replaced (a
  # basename of erx_desk's to its text) in place of the tree's.
  def outside(replaced = {})
    Dir.mktmpdir('erx-desk-boundary-') do |work|
      ErlangBuild.compile(work, applications: %w[erx_ui], tests: ['test/erlang/erx_sdk_boundary.erl'])
      ebin = File.join(work, 'desk')
      FileUtils.mkdir_p(ebin)
      erlc(work, ebin, sources(work, replaced))
      File.write(File.join(work, 'public.txt'), public_functions.join("\n") + "\n")
      eval = 'io:format("~0p", [erx_sdk_boundary:outside(["desk"], "public.txt")]), halt().'
      out, err, status = Open3.capture3('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell',
                                        '-pa', work, '-eval', eval, chdir: work, stdin_data: '')
      assert status.success?, "#{out}\n#{err}"
      out
    end
  end

  def sources(work, replaced)
    Dir.glob(File.join(DESK, '*.erl')).map do |path|
      text = replaced[File.basename(path)]
      next path unless text

      File.join(work, File.basename(path)).tap { File.write(it, text) }
    end
  end

  def erlc(work, ebin, sources)
    out, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERLC'), '+debug_info',
                                  '-pa', work, '-o', ebin, *sources, stdin_data: '')
    assert status.success?, out
  end

  # public.txt's function lines, and the inspector call D1 adds to them.
  def public_functions
    entries = Erx::Sdk.entries(File.read(File.join(ROOT, Erx::Sdk::PUBLIC)))
    (entries.grep(Erx::Sdk::Function).map(&:to_s) + ['erx:inspect/2']).sort
  end
end
