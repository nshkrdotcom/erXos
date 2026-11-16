# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/abi_binary'
require_relative '../../tools/lib/erx/manifest'
require_relative '../../tools/lib/erx/platform'
require_relative '../fixtures/manifest_context'

# Enum attributes (docs/design-abi.md, "Declarations"): an enum declares a closed set of
# attribute names, each member line names the ones its member carries, and every
# consumer reads that one fact, the Ruby host tools through Codec#attribute? and Erlang
# through erx_abi_enums's predicates, beside the type and the guard macro every enum
# gets in Erlang.
class AbiEnumAttributesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  ROLES = <<~ABI
    abi 1
    enum role u32
      attribute read_only
      attribute writer
      value boot 1 writer
      value system 2 read_only
      value data 3
  ABI

  def schema(text) = Erx::ABI::Model.validate(Erx::ABI::SourceSet.new(declarations: Erx::ABI::Syntax.parse(text), inputs: {}).freeze)

  def tree_schema(root = ROOT) = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))

  def test_each_member_carries_the_attributes_its_line_names
    codec = Erx::ABI::Codec.new(schema(ROLES))
    assert_equal({ 'read_only' => ['system'], 'writer' => ['boot'] }, codec.schema.types.fetch('role').attributes)
    assert_equal [false, true, false], [1, 2, 3].map { |value| codec.attribute?('role', value, 'read_only') }
    assert_equal [true, false, false], [1, 2, 3].map { |value| codec.attribute?('role', value, 'writer') }
    assert_raises(Erx::ABI::DecodeError) { codec.attribute?('role', 2, 'hidden') }
    assert_raises(Erx::ABI::DecodeError) { codec.attribute?('role', 4, 'read_only') }
  end

  # Strict, as the spec rules ask: a name no attribute line declares fails generation,
  # as do a second declaration, a name twice on one member, a declaration no member
  # carries and an attribute of a flags type.
  def test_an_attribute_the_enum_does_not_declare_refuses_the_schema
    refused = {
      'undeclared' => [ROLES.sub('value data 3', 'value data 3 hidden'), /role declares no attribute hidden/],
      'declared twice' => [ROLES.sub("  attribute writer\n", "  attribute writer\n  attribute writer\n"),
                           /duplicate attribute writer/],
      'carried twice' => [ROLES.sub('value boot 1 writer', 'value boot 1 writer writer'), /boot carries writer twice/],
      'carried by none' => [ROLES.sub('value boot 1 writer', 'value boot 1'), /attribute writer marks no member of role/],
      'on flags' => ["abi 1\nflags mode u32\n  attribute hot\n  bit on 0 hot\n", /attributes belong to an enum, not to flags/],
      'a word after a bit' => ["abi 1\nflags mode u32\n  bit on 0 hot\n", /expected 2 fields for bit/],
      'an attribute line of three words' => [ROLES.sub('attribute writer', 'attribute writer extra'), /expected 1 fields for attribute/],
      'not a name' => [ROLES.sub('attribute writer', 'attribute Writer'), /invalid local identifier/]
    }
    refused.each do |label, (text, message)|
      error = assert_raises(Erx::ABI::SchemaError, label) { schema(text) }
      assert_match message, error.message, label
    end
  end

  # The guard macro of files_rights admits exactly its three members, and the type and
  # the attribute predicates of erx_abi_enums compile beside it.
  def test_the_generated_erlang_guard_admits_exactly_the_members
    Dir.mktmpdir('erx-abi-enums-') do |directory|
      generated = generate_erlang(tree_schema, directory)
      File.write(File.join(directory, 'enum_use.erl'), <<~ERLANG)
        -module(enum_use).
        -export([main/0]).
        -include("generated/erx_abi.hrl").
        -spec rights(term()) -> erx_abi_enums:files_rights() | no.
        rights(Term) when ?ERX_IS_FILES_RIGHTS(Term) -> Term;
        rights(_Term) -> no.
        main() ->
            io:format("~w~n", [[rights(T) || T <- [ro, rw, rx, r, rwx, read, 1, 2, 3, <<"ro">>, "ro", {ro}]]]),
            io:format("~w~n", [[erx_abi_enums:mf_window_role_read_only(R) || {R, _} <- ?ERX_MF_WINDOW_ROLE_MEMBERS]]),
            io:format("~w~n", [try erx_abi_enums:mf_window_role_read_only(record) catch error:Reason -> Reason end]),
            halt().
      ERLANG
      output = run_erlang(directory, [generated, File.join(directory, 'enum_use.erl')], 'enum_use')
      codec = Erx::ABI::Codec.new(tree_schema)
      roles = codec.schema.types.fetch('mf_window_role').members.sort_by { |_name, value| value }
      read_only = roles.map { |_name, value| codec.attribute?('mf_window_role', value, 'read_only') }
      lines = output.lines
      assert_equal "[ro,rw,rx,no,no,no,no,no,no,no,no,no]\n", lines[0]
      assert_equal "[#{read_only.join(',')}]\n", lines[1]
      assert_match(/function_clause/, lines[2])
    end
  end

  # One fact, both consumers: a copy of the ABI whose system role loses read_only lets the
  # manifest check admit a writable system window and erx_blk_table treat a system window
  # as writable, where the tree's ABI refuses the one and reports the other read-only. A
  # consumer that kept its own list would not change.
  def test_a_window_role_s_read_only_fact_changes_both_consumers
    Dir.mktmpdir('erx-abi-roles-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      path = File.join(root, 'abi/manifest.txt')
      text = File.binread(path)
      seeded = text.sub(/^(  value system 8 configured) read_only$/, '\1')
      assert text != seeded, 'the system role carries read_only'
      File.binwrite(path, seeded)
      writable = manifest_source.sub(/(window system\n(?:  .*\n)*?)  rights read\n/, "\\1  rights read,write\n")
      error = assert_raises(Erx::Manifest::Invalid) { admit(writable, Erx::ABI::Codec.new(tree_schema)) }
      assert_equal 'window.rights', error.field
      admit(writable, Erx::ABI::Codec.new(tree_schema(root)))
      assert_equal "true\n", blk_read_only(tree_schema)
      assert_equal "false\n", blk_read_only(tree_schema(root))
    end
  end

  # The slot writer's roles are the ones not marked configured: a copy of the ABI whose
  # fat role loses the attribute refuses a fat window held by a configured domain.
  def test_a_window_role_s_configured_fact_changes_the_manifest_check
    Dir.mktmpdir('erx-abi-roles-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      path = File.join(root, 'abi/manifest.txt')
      text = File.binread(path)
      seeded = text.sub(/^(  value fat 7) configured$/, '\1')
      assert text != seeded, 'the fat role is configured'
      File.binwrite(path, seeded)
      fat = manifest_source + "window seeded\n  holder @domain.storage\n  device \"/virtio_mmio@a003e00\"\n" \
                              "  role fat\n  partition 1\n  rights read\n  image none\n"
      admit(fat, Erx::ABI::Codec.new(tree_schema))
      error = assert_raises(Erx::Manifest::Invalid) { admit(fat, Erx::ABI::Codec.new(tree_schema(root))) }
      assert_equal 'window.holder', error.field
    end
  end

  private

  def manifest_source = Erx::Platform.load(root: ROOT, name: 'qemu-virt').manifest_source(ROOT)

  def admit(source, codec)
    platform = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(codec).merge(platform: platform,
                                                                                         build_kind: 'development'))
    Erx::Manifest.admit(source: source, codec: codec, context: context, planner: ManifestContextFixture.accepting_planner)
  end

  # erx_abi.hrl under generated/, as the tree's modules include it, and erx_abi_enums.
  def generate_erlang(schema, directory)
    outputs = Erx::ABI::ErlangEmitter.outputs(schema)
    FileUtils.mkdir_p(File.join(directory, 'generated'))
    File.binwrite(File.join(directory, 'generated/erx_abi.hrl'),
                  outputs.fetch('erlang/apps/erx/include/generated/erx_abi.hrl'))
    File.join(directory, 'erx_abi_enums.erl').tap do |enums|
      File.binwrite(enums, outputs.fetch('erlang/apps/erx/src/generated/erx_abi_enums.erl'))
    end
  end

  # erx_blk_table:read_only(system), compiled against the Erlang schema generates.
  def blk_read_only(schema)
    Dir.mktmpdir('erx-abi-blk-') do |directory|
      generated = generate_erlang(schema, directory)
      run_erlang(directory, [generated, File.join(ROOT, 'erlang/apps/erx_blk/src/erx_blk_table.erl')],
                 nil, eval: 'io:format("~w~n", [erx_blk_table:read_only(system)]), halt().')
    end
  end

  def run_erlang(directory, sources, main, eval: nil)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-Werror', '-I', directory,
                                     '-o', directory, *sources, stdin_data: '')
    assert status.success?, output
    run = eval ? ['-eval', eval] : ['-s', main, 'main']
    output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', directory,
                                     *run, stdin_data: '')
    assert status.success?, output
    output
  end
end
