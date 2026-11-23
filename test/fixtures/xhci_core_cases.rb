# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
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
  TEST_MODULE = 'erx_xhci_core_tests'
  DEADLINE_SECONDS = '600'

  @lock = Mutex.new
  @tests_beams = nil

  # Output and status of one EUnit run; replaced maps a root-relative source path to its
  # replacement source (ErlangBuild.compile). cases names the test functions of the test
  # module to run, every case when empty: a seeded fault names the case that must catch it
  # and need not run the others. Only a replaced module is compiled here; the test
  # module's beam, which does not depend on the module under test, is built once.
  def self.run(replaced: {}, cases: [])
    Dir.mktmpdir('erx-xhci-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, replaced: replaced)
      FileUtils.cp(tests_beam, work)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', "halt(case eunit:test(#{eunit_tests(cases)}, [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end

  # The EUnit test specification for cases: the whole module, or the named functions.
  def self.eunit_tests(cases)
    return TEST_MODULE if cases.empty?

    "[#{cases.map { |name| eunit_case(name) }.join(', ')}]"
  end

  # A function whose name ends in _ is a generator (EUnit's own convention), which EUnit
  # runs as one only when told so.
  def self.eunit_case(name) = name.end_with?('_') ? "{generator, #{TEST_MODULE}, #{name}}" : "{#{TEST_MODULE}, #{name}}"
  private_class_method :eunit_case

  # The beam file of the test module, compiled once per process into a directory removed at exit.
  def self.tests_beam
    @lock.synchronize do
      @tests_beams ||= Dir.mktmpdir('erx-xhci-core-tests').tap do |beams|
        at_exit { FileUtils.rm_rf(beams) }
        ErlangBuild.compile(beams, applications: APPLICATIONS, tests: TESTS)
      end
      File.join(@tests_beams, "#{TEST_MODULE}.beam")
    end
  end
  private_class_method :tests_beam
end
