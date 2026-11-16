# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_desk_files_core_tests.erl, the cases of files' core
# (docs/design-desktop-programs.md, "Verification and testing": kinds and sorting, D4,
# paging, the text test and preview, D5), against the erx_desk application compiled from
# source with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies). Each row's seeded fault is then compiled into a copy of the core,
# which must fail the row's case. The cases act on the trees through erx_ui_query, so a
# node a person could not act on fails them.
class ErxDeskFilesCoreTest < Minitest::Test
  SOURCE = 'erlang/apps/erx_desk/src/erx_desk_files_core.erl'
  TEST = 'erx_desk_files_core_tests'
  DEADLINE = '300'
  # The core no longer holds a seeded fault's text.
  class StaleMutant < Erx::Error; end
  # A seeded fault: the core's text, what replaces it, and the case it must fail, in
  # EUnit's terms.
  Mutant = Data.define(:text, :broken, :test) do
    # The case's function, which EUnit's line for it names: the spec's last element.
    def function = test[/\w+(?=\}\z)/]
  end
  MUTANTS = {
    link_listed_as_folder: Mutant.new(
      text: 'kind(_Dir, _Name, #file_info{type = symlink}) -> link;',
      broken: 'kind(_Dir, _Name, #file_info{type = symlink}) -> folder;',
      test: "{#{TEST}, kinds_test}"
    ),
    lookup_by_shown_text: Mutant.new(
      text: '    element(offset(Page) + Index + 1, Names).',
      broken: "    Shown = erx_text:escape_line(shown(element(offset(Page) + Index + 1, Names))),\n" \
              '    hd([N || N <- tuple_to_list(Names), erx_text:escape_line(shown(N)) =:= Shown]).',
      test: "{#{TEST}, names_that_show_alike_open_their_own_files_test}"
    ),
    key_without_generation: Mutant.new(
      text: 'iolist_to_binary(io_lib:format("listing ~b ~b", [Generation, Page])).',
      broken: 'iolist_to_binary(io_lib:format("listing ~b", [Page])).',
      test: "{#{TEST}, an_event_on_a_replaced_listing_is_dropped_test}"
    ),
    core_takes_a_stale_key: Mutant.new(
      text: 'current(Key, #files{listing = #{page := Page}, generation = G}) -> Key =:= listing_key(G, Page);',
      broken: 'current(_Key, #files{listing = #{}}) -> true;',
      test: "{#{TEST}, an_event_chosen_in_a_replaced_listing_is_dropped_by_the_core_test}"
    ),
    page_offset_off_by_one: Mutant.new(
      text: 'offset(Page) -> Page * max_items().',
      broken: 'offset(Page) -> Page * max_items() + 1.',
      test: "{#{TEST}, a_large_folder_pages_by_256_test}"
    ),
    stat_over_every_name: Mutant.new(
      text: '{stat, S#files.dir, Shown}',
      broken: '{stat, S#files.dir, tuple_to_list(Names)}',
      test: "{#{TEST}, a_large_folder_pages_by_256_test}"
    ),
    read_bound_removed: Mutant.new(
      text: '{read, Path, ?READ_MAX}',
      broken: '{read, Path, 1 bsl 30}',
      test: "{#{TEST}, a_large_file_reads_at_most_16_kib_test}"
    ),
    classifier_reads_4_kib: Mutant.new(
      text: 'Read = binary:part(Bytes, 0, min(byte_size(Bytes), ?READ_MAX)),',
      broken: 'Read = binary:part(Bytes, 0, min(byte_size(Bytes), 4096)),',
      test: "{#{TEST}, the_text_test_test}"
    ),
    cut_skipped: Mutant.new(
      text: '    cut_middle(valid_utf8(Name), item_max()).',
      broken: '    valid_utf8(Name).',
      test: "{generator, #{TEST}, valid_trees_whatever_the_input_test_}"
    ),
    back_unnamed: Mutant.new(
      text: '#{name => <<"Back">>}',
      broken: '#{}',
      test: "{#{TEST}, a_folder_too_large_keeps_the_history_test}"
    ),
    list_not_activated: Mutant.new(
      text: 'on_submit => {open, Key}, ',
      broken: '',
      test: "{#{TEST}, a_link_to_a_folder_opens_it_test}"
    )
  }.freeze

  def test_files_core_cases_pass_under_eunit
    output, status = eunit(nil, TEST)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  # One test per seeded fault, named after it: test_seeded_<name>_fails_its_case.
  MUTANTS.each_key do |name|
    define_method("test_seeded_#{name}_fails_its_case") { assert_mutant_fails(name) }
  end

  private

  def assert_mutant_fails(name)
    mutant = MUTANTS.fetch(name)
    output, status = eunit(mutant, mutant.test)
    refute status.success?, output
    # EUnit's line for the case, which names its function, ends in *failed*.
    assert_match(/#{mutant.function}\S*\.\.\.\*failed\*/, output)
  end

  # Compiles erx_desk, with the core edited when there is a mutant, and the cases into a
  # directory of their own, and runs the cases Tests names, in EUnit's terms.
  def eunit(mutant, tests)
    Dir.mktmpdir('erx-desk-files-core-test') do |work|
      replaced = mutant ? { SOURCE => edited(mutant) } : {}
      ErlangBuild.compile(work, applications: %w[erx_desk], tests: ["test/erlang/erx_ui_query.erl", "test/erlang/#{TEST}.erl"],
                                replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "halt(case eunit:test(#{tests}, [verbose]) of ok -> 0; _ -> 1 end).",
                      chdir: work, stdin_data: '')
    end
  end

  def edited(mutant)
    path = File.join(ErlangBuild::ROOT, SOURCE)
    source = File.binread(path)
    raise StaleMutant, "#{path} no longer holds #{mutant.text.inspect}" unless source.include?(mutant.text)

    source.sub(mutant.text, mutant.broken)
  end
end
