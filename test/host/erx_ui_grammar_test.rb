# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/web_stage'
require_relative '../fixtures/erlang_build'

# The widget format's list grammar (docs/design-abi.md, "Widget format";
# docs/design-desktop-programs.md, the grammar additions): `list NAME ELEMENT
# MAX [none]` of integers and root enums, `within` on a list of integers and
# `parallel`, over a test declaration, abi/formats/ui.txt, whose graph kind
# takes samples within min and max, with a menu kind added.
# The validator generated from it refuses a list of the wrong length, a value
# outside `within` and a 241st value, each with its reason and path, and a
# validator generated without the `parallel` check accepts the first; one
# record of each list, `none` among the values, round-trips identically
# through the Erlang, C and TypeScript codecs generated from it, and the three
# readers refuse each broken list value for the same reason.
class ErxUIGrammarTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  SCHEMA = Erx::ABI::Generator.plan(root: ROOT).schema
  STOPGAPS = SCHEMA.inspection.stopgaps.keys
  # ui.txt's graph holds the samples, an integer list with none within two
  # bounds. A menu adds its alignments, an enum list as long as its items, and
  # its levels, an integer list without none.
  ADDITIONS = <<~UI
    list levels sample 4
    list aligns @ui_align 8
    prop aligns 41 aligns
    prop levels 42 levels
    kind menu 41
      prop items
      prop aligns parallel items
      prop levels
  UI
  RECORDS = '  # The records the server writes'
  BUILT = File.join(Erx::Generated::OUTPUT, 'erlang/apps/erx_ui/src')
  HARNESS = File.join(ROOT, 'test/fixtures/erx_ui_wire_harness.c')

  # Each tree's validation, and what the validator must answer for it.
  VALIDATIONS = {
    'Graph(#{min => 0, max => 10, samples => [0, none, 10]})' => 'ok',
    'Graph(#{samples => lists:duplicate(240, 100)})' => 'ok',
    'Graph(#{samples => lists:duplicate(241, 100)})' => '{error,{bad_value,{[1],samples}}}',
    'Graph(#{min => 0, max => 10, samples => [3, none, 11]})' => '{error,{bad_value,{[1],samples}}}',
    'Graph(#{samples => [-1]})' => '{error,{bad_value,{[1],samples}}}',
    'Menu(#{levels => [none]})' => '{error,{bad_value,{[1],levels}}}',
    'Menu(#{items => [<<"a">>, <<"b">>], aligns => [start, fill]})' => 'ok',
    'Menu(#{items => [<<"a">>, <<"b">>], aligns => [start]})' => '{error,{bad_value,{[1],aligns}}}',
    'Menu(#{items => [<<"a">>], aligns => [start, center]})' => '{error,{bad_value,{[1],aligns}}}',
    'Menu(#{aligns => [start]})' => '{error,{bad_value,{[1],aligns}}}',
    'Menu(#{items => [<<"a">>], aligns => [none]})' => '{error,{bad_value,{[1],aligns}}}'
  }.freeze
  WRONG_LENGTH = 'Menu(#{items => [<<"a">>, <<"b">>], aligns => [start]})'

  # The records of the round trip, and the lines the C harness, by number, and
  # the TypeScript harness, by name, print for them.
  RECORDS_SENT = '[{insert, 1, 0, 0, graph, #{min => -5, samples => [0, none, 2147483647, none]}}, ' \
                 '{insert, 2, 0, 1, menu, #{items => [<<"a">>, <<"b">>], aligns => [start, fill]}}, ' \
                 '{set, 1, #{samples => []}, []}]'
  C_LINES = ['insert 1 0 0 14 15=0,0,,0:-5 33=0,0,,0:[0,-2147483648,2147483647,-2147483648]',
             'insert 2 0 1 41 18=0,0,,0:[x61,x62] 41=0,0,,0:[0,3]',
             'set 1 33=0,0,,0:[] /'].freeze
  TS_LINES = ['insert 1 0 0 graph min=-5 samples=[0,none,2147483647,none]',
              'insert 2 0 1 menu items=[x61,x62] aligns=[start,fill]',
              'set 1 samples=[] /'].freeze

  # Inserts with one list value broken, each as kind, property number, and
  # the list's bytes: a sample below its type, -2^31 in levels, which allow no
  # none, an alignment no member has, samples cut short inside a value, and
  # nine alignments of at most eight.
  BROKEN_LISTS = [[14, 33, ['vl<', 1, -1]], [41, 42, ['vl<', 1, -(1 << 31)]], [41, 41, ['vC', 1, 9]],
                  [14, 33, ['vl<v', 2, 5, 0]], [41, 41, ['vC9', 9, *[0] * 9]]].freeze

  def test_the_validator_refuses_each_fault_with_reason_and_path
    assert_equal VALIDATIONS.values, validations(ui)
  end

  def test_a_validator_without_the_parallel_check_fails
    seeded = validations(without_parallel(ui))
    assert_equal 'ok', seeded[VALIDATIONS.keys.index(WRONG_LENGTH)]
  end

  def test_the_three_readers_refuse_each_broken_list_value_alike
    records = BROKEN_LISTS.map do |kind, number, (format, *values)|
      body = [1, 1, 0, 0, kind, 1, number].pack('CVVvCCC') + values.pack(format)
      [body.bytesize].pack('V') + body
    end
    Dir.mktmpdir('erx-ui-grammar') do |work|
      binaries = records.map { |bytes| "<<#{bytes.bytes.join(',')}>>" }.join(', ')
      assert_equal ['{error,bad_value}'] * records.size,
                   erlang(work, ui, "[io:format(\"~0p~n\", [erx_ui_wire:read_server(B)]) || B <- [#{binaries}]]").lines(chomp: true)
      refused_alike([c_harness(work, ui)], records)
    end
    Erx::WebStage.with(root: ROOT) do |stage|
      File.write(File.join(stage, Erx::ABI::UIWireTSEmitter::PATH.delete_prefix('web/')),
                 Erx::ABI::UIWireTSEmitter.typescript(ui, stopgaps: STOPGAPS))
      refused_alike([*Erx::WebStage::NODE, File.join(stage, 'test/ui_wire_harness.ts')], records)
    end
  end

  def test_a_list_with_none_round_trips_through_the_three_codecs
    Dir.mktmpdir('erx-ui-grammar') do |work|
      stream = File.join(work, 'stream')
      assert_equal 'true', erlang(work, ui, "Records = #{RECORDS_SENT}, " \
                                            "Bytes = iolist_to_binary([erx_ui_wire:encode(R, fun(_, _) -> <<>> end) || R <- Records]), " \
                                            "ok = file:write_file(\"#{stream}\", Bytes), " \
                                            'Read = fun Read(<<>>) -> []; Read(B) -> {ok, R, Rest} = erx_ui_wire:read_server(B), [R | Read(Rest)] end, ' \
                                            'io:format("~p~n", [Read(Bytes) =:= Records])').strip
      assert_equal C_LINES, read_stream([c_harness(work, ui)], stream)
      Erx::WebStage.with(root: ROOT) do |stage|
        File.write(File.join(stage, Erx::ABI::UIWireTSEmitter::PATH.delete_prefix('web/')),
                   Erx::ABI::UIWireTSEmitter.typescript(ui, stopgaps: STOPGAPS))
        # In "rewrite" mode the harness writes each record back with the
        # TypeScript writer and refuses the stream unless its bytes are the
        # Erlang encoder's.
        assert_equal TS_LINES, read_stream([*Erx::WebStage::NODE, File.join(stage, 'test/ui_wire_harness.ts'), 'rewrite'],
                                           stream)
      end
    end
  end

  private

  def ui
    @ui ||= begin
      source = File.read(File.join(ROOT, Erx::ABI::UI::SOURCE))
      text = source.sub(RECORDS) { "#{ADDITIONS.gsub(/^/, '  ')}#{RECORDS}" }
      declarations = Erx::ABI::Syntax.parse(text, path: Erx::ABI::UI::SOURCE).select { |item| item.kind == 'ui' }
      # The root limits as the generator reads them, so a bound written as @name resolves.
      limits = SCHEMA.constants.transform_values(&:value)
      Erx::ABI::UI.validate(declarations, limits: limits, types: SCHEMA.types)
    end
  end

  # SCHEMA with no kind's property marked parallel: the seeded fault.
  def without_parallel(schema)
    kinds = schema.kinds.map do |kind|
      kind.dup.tap { |copy| copy.takes = kind.takes.map { |entry| entry.dup.tap { |taken| taken.parallel = nil } } }
    end
    schema.dup.tap { |copy| copy.kinds = kinds }
  end

  # What the validator generated from schema answers for each tree of
  # VALIDATIONS, a graph or a menu as the second child of a column.
  def validations(schema)
    Dir.mktmpdir('erx-ui-grammar') do |work|
      calls = VALIDATIONS.keys.map { |tree| "io:format(\"~0p~n\", [erx_ui_schema:validate(#{tree}, 100)])" }
      erlang(work, schema, 'Graph = fun(P) -> {column, #{}, [{spacer, #{}, []}, {graph, P, []}]} end, ' \
                           'Menu = fun(P) -> {column, #{}, [{spacer, #{}, []}, {menu, P, []}]} end, ' \
                           "#{calls.join(', ')}").lines(chomp: true)
    end
  end

  # Runs expression on stock's emulator over erx and erx_ui, compiled with
  # schema's validator and codec in place of the real ones; its output.
  def erlang(work, schema, expression)
    ErlangBuild.compile(work, applications: %w[erx erx_ui], replaced: {
                          File.join(BUILT, 'erx_ui_schema.erl') => Erx::ABI::UIEmitter.erlang(schema, stopgaps: STOPGAPS),
                          File.join(BUILT, 'erx_ui_wire.erl') => Erx::ABI::UIWireEmitter.erlang(schema, stopgaps: STOPGAPS)
                        })
    run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval', "#{expression}, halt(0).", chdir: work)
  end

  # The C harness built with the reader generated from schema, under ASan and UBSan.
  def c_harness(work, schema)
    wire = Erx::ABI::UIWireEmitter
    enums = wire.enums(schema)
    header = File.join(work, 'include', wire::C_HEADER_PATH.delete_prefix('include/'))
    FileUtils.mkdir_p(File.dirname(header))
    File.write(header, wire.c_header(schema, enums: enums))
    File.write(File.join(work, 'erx_ui_wire.c'), wire.c_source(schema, stopgaps: STOPGAPS, enums: enums))
    File.join(work, 'harness').tap do |binary|
      run!(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-I', File.join(work, 'include'),
           HARNESS, File.join(work, 'erx_ui_wire.c'), '-o', binary, chdir: work)
    end
  end

  def refused_alike(reader, records)
    records.each do |bytes|
      _out, error, status = Open3.capture3('gtimeout', '-k', '10', '300', *reader, stdin_data: bytes, binmode: true)
      refute status.success?, "#{reader.last} accepted a broken list"
      assert_equal 'refused at 0: bad value', error.chomp
    end
  end

  def read_stream(reader, path)
    read, error, status = Open3.capture3('gtimeout', '-k', '10', '300', *reader, stdin_data: File.binread(path),
                                         binmode: true)
    assert status.success?, "#{reader.last} refused the stream: #{error}"
    read.lines(chomp: true)
  end

  def run!(*command, chdir:)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '300', *command, chdir: chdir, stdin_data: '')
    assert status.success?, output
    output
  end
end
