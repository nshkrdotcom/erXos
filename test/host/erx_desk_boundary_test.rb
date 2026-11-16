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
# functions. A whole-module line of public.txt, erx_win's, is left out: erx_desk draws
# nothing itself, so the check is only stricter for it.
class ErxDeskBoundaryTest < Minitest::Test
  ROOT = ErlangBuild::ROOT
  DESK = File.join(ROOT, 'erlang/apps/erx_desk/src')
  CLOCK = 'erx_desk_clock_core.erl'
  DEADLINE = '120'
  # The calls the check finds in the tree as it is: files' core reads the widget schema's
  # bounds through erx_ui_schema:property/1, which public.txt does not list (TODO.md,
  # "desktop, D1 and the widget schema's bounds").
  KNOWN = '[{{erx_desk_files_core,caption_max,0},{erx_ui_schema,property,1}},' \
          '{{erx_desk_files_core,item_max,0},{erx_ui_schema,property,1}},' \
          '{{erx_desk_files_core,max_items,0},{erx_ui_schema,property,1}}]'

  def test_erx_desk_calls_only_the_public_surface
    assert_equal KNOWN, outside
  end

  def test_a_call_of_the_inspector_router_fails_the_check
    seeded = File.read(File.join(DESK, CLOCK))
                 .sub('-export([init/1, step/2, view/1, next_deadline/1]).',
                      "-export([init/1, step/2, view/1, next_deadline/1, seeded/1]).") +
             "\nseeded(Query) -> erx_inspector:route(false, undefined, Query, 1).\n"
    assert_includes outside(CLOCK => seeded), '{{erx_desk_clock_core,seeded,1},{erx_inspector,route,4}}'
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
