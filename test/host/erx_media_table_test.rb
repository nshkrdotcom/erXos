# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The partition table's reader (docs/design-drives.md, "Host tests"):
# test/erlang/erx_media_table_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies) against erx_media_table as it is and against each seeded
# fault below, where the named case must fail.
class ErxMediaTableTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_media/src/erx_media_table.erl'
  APPLICATIONS = %w[erx erx_media].freeze
  TESTS = %w[test/erlang/erx_media_table_cases.erl test/erlang/erx_media_table_tests.erl].freeze

  Fault = Data.define(:name, :from, :to, :caught_by)

  # Each fault replaces one passage of erx_media_table; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'the status-byte test dropped',
              from: 'Status =:= ?ERX_MBR_STATUS_INACTIVE orelse Status =:= ?ERX_MBR_STATUS_ACTIVE end,',
              to: 'is_integer(Status) end,',
              caught_by: 'a_boot_sector_whose_status_bytes_are_code_is_no_table_test'),
    Fault.new(name: 'the overlap check made order-dependent',
              from: 'A < B, FirstA =< LastB andalso FirstB =< LastA],', to: 'A < B, FirstA =< FirstB andalso FirstB =< LastA],',
              caught_by: 'overlapping_entries_refuse_the_table_in_either_order_test'),
    Fault.new(name: 'the backwards check dropped',
              from: "First =< Last orelse fail({backwards, [Number]}),\n", to: '',
              caught_by: 'an_entry_running_backwards_refuses_the_table_test'),
    Fault.new(name: 'a missing primary signature taken as no GPT',
              from: '{true, _} -> {gpt, gpt(Medium)};',
              to: '{true, _} -> case binary:part(sector(1, Medium), 0, ?ERX_GPT_SIGNATURE_SIZE) of ?ERX_GPT_SIGNATURE_BYTES -> {gpt, gpt(Medium)}; ' \
                  '_ -> {none, whole(Medium)} end;',
              caught_by: 'a_primary_header_without_its_signature_is_read_from_the_backup_test'),
    Fault.new(name: 'the status-byte test made before the 0xEE test',
              from: '{true, _} -> {gpt, gpt(Medium)};', to: '{true, true} -> {gpt, gpt(Medium)}; {true, false} -> {none, whole(Medium)};',
              caught_by: 'a_protective_entry_over_a_fat_boot_sector_is_never_mounted_whole_test'),
    Fault.new(name: "the usable area's bounds dropped",
              from: 'andalso First >= 2 andalso First =< LastUsable andalso LastUsable < Last', to: '',
              caught_by: 'a_primary_usable_area_out_of_bounds_is_read_from_the_backup_test'),
    Fault.new(name: 'the backup read at the last sector after a passing header',
              from: 'alternate({ok, #header{alternate = Alternate}}, _Medium) -> Alternate;',
              to: 'alternate({ok, _}, #medium{last = Last}) -> Last;',
              caught_by: 'a_failing_primary_array_is_read_from_the_backup_at_the_alternate_test'),
    Fault.new(name: 'the array compared by its ends alone',
              from: 'fun({From, To}) -> From =< Last andalso First =< To end',
              to: 'fun({From, To}) -> (From >= First andalso From =< Last) orelse (To >= First andalso To =< Last) end',
              caught_by: 'an_array_that_encloses_the_usable_area_is_refused_test'),
    Fault.new(name: "the other copy's array left out of the metadata",
              from: 'array_range(Taken) | other_array(Other)]', to: 'array_range(Taken) | other_array({error, Other})]',
              caught_by: 'a_usable_area_that_meets_the_other_array_is_refused_test'),
    Fault.new(name: "the array's place bounded by the medium alone",
              from: 'andalso array_placed(Header, Last),', to: 'andalso array_last(Header) =< Last,',
              caught_by: 'an_array_out_of_its_place_fails_its_header_test'),
    Fault.new(name: 'the array bound removed',
              from: 'andalso Entries * EntrySize =< ?ERX_GPT_ARRAY_MAX', to: '',
              caught_by: 'an_array_of_17_kib_is_refused_test'),
    Fault.new(name: 'the end check a sector short',
              from: 'Last =< LastUsable orelse fail({past_the_end, [Number]})',
              to: 'Last =< LastUsable + 1 orelse fail({past_the_end, [Number]})',
              caught_by: 'every_written_table_reads_back_inside_the_medium_test'),
    Fault.new(name: "place/3's bound a sector short",
              from: 'Sector + Count =< Length ->', to: 'Sector + Count =< Length + 1 ->',
              caught_by: 'place_keeps_a_request_inside_its_volume_test')
  ].freeze

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
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_media_table_tests: ).)*?\*failed\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the reader as core_text, and the suite, and runs the suite.
  def eunit(core_text)
    Dir.mktmpdir('erx-media-table-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { CORE => core_text })
      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_media_table_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
