# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/probe_volumes'

# The probe of a volume's format (docs/design-drives.md, "Host tests"):
# test/erlang/erx_media_probe_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies) over volumes it writes and over the FAT12, FAT16 and
# FAT32 volumes fsimg writes, against erx_media_probe as it is and against each seeded
# fault below, where the named case must fail.
class ErxMediaProbeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PROBE = 'erlang/apps/erx_media/src/erx_media_probe.erl'
  APPLICATIONS = %w[erx erx_fat erx_media].freeze
  TESTS = %w[test/erlang/erx_media_probe_tests.erl].freeze

  Fault = Data.define(:name, :from, :to, :caught_by)

  # Each fault replaces one passage of erx_media_probe; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'the order reversed',
              from: 'Found = [Name || {Name, Test} <- order(), found(Test, Sectors)],',
              to: 'Found = [Name || {Name, Test} <- lists:reverse(order()), found(Test, Sectors)],',
              caught_by: 'a_fat32_volume_holding_erofs_magic_selects_erofs_test'),
    Fault.new(name: 'the written-formats check dropped',
              from: 'also => [Name || Name <- Others, lists:member(Name, Written)]', to: 'also => [] -- Written',
              caught_by: 'a_fat32_volume_that_kept_a_littlefs_superblock_selects_littlefs_test'),
    Fault.new(name: 'the FAT type left to the mount',
              from: 'Probe#{fat => Type};', to: 'Probe#{fat => Type =/= 12 andalso Type};',
              caught_by: 'a_fat12_volume_is_named_with_its_type_test'),
    Fault.new(name: 'littlefs read in block 0 alone',
              from: '|| Block <- [0, ?ERX_PROBE_LITTLEFS_BLOCK]]},', to: '|| Block <- [0]]},',
              caught_by: 'a_fat32_volume_that_kept_a_littlefs_superblock_selects_littlefs_test'),
    Fault.new(name: "the volume's length ignored",
              from: "read(_Read, Lba, Length) when Lba >= Length ->\n    past_the_volume;\n", to: '',
              caught_by: 'a_volume_too_short_lacks_the_signatures_past_it_test'),
    Fault.new(name: 'a failed read taken as a missing signature',
              from: '{error, Reason} -> throw({?MODULE, Reason})', to: '{error, _} -> past_the_volume',
              caught_by: 'a_failed_read_fails_the_probe_test')
  ].freeze

  def self.volumes
    @volumes ||= Dir.mktmpdir('erx-probe-volumes').tap do |directory|
      ProbeVolumes.write(directory)
      Minitest.after_run { FileUtils.rm_rf(directory) }
    end
  end

  def test_the_cases_pass
    output, status = eunit(File.read(File.join(ROOT, PROBE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, PROBE))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit(original.sub(fault.from) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_media_probe_tests: ).)*?\*failed\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the probe as probe_text, and the suite, and runs the suite.
  def eunit(probe_text)
    Dir.mktmpdir('erx-media-probe-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { PROBE => probe_text })
      Open3.capture2e({ 'ERX_PROBE_VOLUMES' => self.class.volumes },
                      'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_media_probe_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
