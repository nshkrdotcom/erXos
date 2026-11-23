# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require_relative 'erlang_build'

# The controller core's EUnit pass (test/erlang/erx_xhci_core_tests.erl) against the
# module compiled from source, or against a copy of it with a seeded fault: the one run
# that test/host/erx_xhci_core_test.rb and erx_xhci_core_seeds_test.rb share.
module XhciCoreCases
  APPLICATIONS = %w[erx_usb].freeze
  CORE = 'erlang/apps/erx_usb/src/erx_xhci_core.erl'
  TESTS = %w[test/erlang/erx_xhci_core_tests.erl].freeze
  DEADLINE_SECONDS = '600'

  # Output and status of one EUnit run; replaced maps a root-relative source path to its
  # replacement source (ErlangBuild.compile).
  def self.run(replaced: {})
    Dir.mktmpdir('erx-xhci-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_xhci_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
