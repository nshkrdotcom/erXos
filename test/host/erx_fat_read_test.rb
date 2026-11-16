# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/fat_record_volume'
require_relative '../../tools/lib/erx/fsimg'
require_relative '../../tools/lib/erx/pi_medium'
require_relative '../../tools/lib/erx/boot_record'

# The record volume's reader (docs/design-ssh.md, "Verification"):
# test/erlang/erx_fat_read_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies) over the volumes FatRecordVolume writes, against
# erx_fat_read as it is and against each seeded fault below, where the named case must
# fail. One more volume is the record volume as fsimg writes it for the medium,
# Erx::PiMedium::RECORD_VOLUME, which holds the boot-selection record and no
# authorized_keys.
class ErxFatReadTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_storage/src/erx_fat_read.erl'
  APPLICATIONS = %w[erx erx_files erx_blk erx_storage].freeze
  TESTS = %w[test/erlang/erx_fat_read_tests.erl].freeze

  Fault = Data.define(:name, :from, :to, :caught_by)

  # Each fault replaces one passage of erx_fat_read; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'the range check on a link removed',
              from: 'Cluster >= 2 andalso Cluster < Clusters + 2 orelse fail(does_not_read),', to: 'Clusters > 0,',
              caught_by: 'a_chain_that_leaves_the_data_area_is_refused_test'),
    Fault.new(name: 'the deleted-entry marker not checked',
              from: "entry(<<?DELETED, _/binary>>, _Long, _Name) ->\n    none;\n", to: '',
              caught_by: 'a_deleted_entry_is_not_found_test'),
    Fault.new(name: "the region check comparing with the record's cluster alone",
              from: 'Sector >= Start andalso Sector < Start + ?ERX_MEDIUM_ERASE_SECTORS.',
              to: 'Start > 0, Sector =:= ?ERX_MEDIUM_RECORD_SELECT_START.',
              caught_by: 'a_chain_into_the_records_region_is_refused_test'),
    Fault.new(name: 'the last cluster answered whole',
              from: 'binary:copy(binary:part(iolist_to_binary(Sectors), 0, Size))', to: 'iolist_to_binary(Sectors)',
              caught_by: 'the_slack_of_the_last_cluster_is_not_answered_test'),
    Fault.new(name: 'a cluster seen twice not checked',
              from: 'lists:member(Cluster, Seen) andalso fail(does_not_read),', to: '',
              caught_by: 'a_chain_that_loops_or_ends_early_is_refused_test'),
    Fault.new(name: "the reserved area's cover of the reset count not checked",
              from: 'Reserved > ?ERX_MEDIUM_RECORD_COUNT_START andalso', to: 'Reserved > 0 andalso',
              caught_by: 'a_volume_not_laid_out_as_the_record_partition_is_refused_test'),
    Fault.new(name: "the long name's checksum not checked",
              from: 'Sum =:= checksum(Short) andalso', to: 'is_binary(Short) andalso',
              caught_by: 'a_long_name_whose_checksum_does_not_match_its_short_entry_is_not_found_test'),
    Fault.new(name: 'a FAT too small for the clusters admitted',
              from: 'andalso FatSectors * ?SECTOR >= (Clusters + 2) * 2)', to: 'andalso FatSectors > 0)',
              caught_by: 'a_volume_not_laid_out_as_the_record_partition_is_refused_test'),
    Fault.new(name: 'the long name gathered afresh in each sector',
              from: '{next, Next} -> root(Volume, Name, First + ?ENTRIES_PER_SECTOR, Next)',
              to: '{next, _Next} -> root(Volume, Name, First + ?ENTRIES_PER_SECTOR, none)',
              caught_by: 'a_long_name_across_two_sectors_is_found_test')
  ].freeze

  def self.volumes
    @volumes ||= Dir.mktmpdir('erx-fat-volumes').tap do |directory|
      FatRecordVolume.write_cases(directory)
      write_fsimg_record(File.join(directory, 'fsimg_record.img'))
      Minitest.after_run { FileUtils.rm_rf(directory) }
    end
  end

# The record volume the medium build formats, its record file in place.
def self.write_fsimg_record(path)
  Dir.mktmpdir('erx-fsimg-record') do |files|
    File.binwrite(File.join(files, Erx::PiMedium::RECORD_FILE), Erx::BootRecord::SLOTS.fetch(:a).text)
    output, status = Open3.capture2e(Erx::Fsimg.locate(root: ROOT), 'cW', '-f', path, *Erx::PiMedium::RECORD_VOLUME,
                                     '-C', files, '.', stdin_data: '')
    raise "fsimg failed: #{output}" unless status.success?
  end
end

  def test_the_cases_pass
    output, status = eunit(File.read(File.join(ROOT, CORE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, CORE))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit(original.sub(fault.from) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      # EUnit's verbose report of one test: its name, then its verdict before the next
      # test's name.
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_fat_read_tests: ).)*?\*failed\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the reader as core_text, and the suite, and runs the suite.
  def eunit(core_text)
    Dir.mktmpdir('erx-fat-read-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { CORE => core_text })
      Open3.capture2e({ 'ERX_FAT_VOLUMES' => self.class.volumes },
                      'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_fat_read_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
