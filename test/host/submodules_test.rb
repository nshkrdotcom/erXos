# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/lib/erx/example_fetch'
require_relative '../../tools/lib/erx/lvgl'
require_relative '../../tools/lib/erx/origin'
require_relative '../../tools/lib/erx/submodules'

# .gitmodules is the one list of the tree's git submodules (Erx::Submodules): every
# other list of them, and each submodule's role, is read from it.
class SubmodulesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  EXTRA = "[submodule \"examples/quake/quake\"]\n\tpath = examples/quake/quake\n" \
          "\turl = https://example.invalid/quake\n\tupdate = none\n" \
          "[submodule \"third_party/zlib/zlib\"]\n\tpath = third_party/zlib/zlib\n\turl = https://example.invalid/zlib\n"
  EXAMPLE = "[submodule \"examples/a/a\"]\n\tpath = examples/a/a\n\turl = u\n\tupdate = none\n"

  def setup = (@directory = Dir.mktmpdir('erx-submodules-'))
  def teardown = FileUtils.remove_entry(@directory)

  def gitmodules(text) = File.join(@directory, '.gitmodules').tap { |path| File.write(path, text) }
  def refusal(text) = assert_raises(Erx::Error) { Erx::Submodules.read(gitmodules(text)) }.message

  def test_the_tree_s_lists_are_those_of_gitmodules
    tree = Erx::Submodules::TREE
    assert_equal File.read(File.join(ROOT, '.gitmodules')).scan(/^\s*path = (.+)$/).flatten, tree.paths
    assert_equal tree.paths, Erx::Origin::SUBMODULES
    assert_equal [Erx::Lvgl::SUBMODULE], tree.built_in.paths
    assert_equal tree.examples.paths, Erx::ExampleFetch::EXAMPLES.paths
  end

  def test_the_update_attribute_gives_the_role
    submodules = Erx::Submodules.read(gitmodules(File.read(File.join(ROOT, '.gitmodules')) + EXTRA))
    assert_equal %w[quake], submodules.examples.names - Erx::Submodules::TREE.examples.names
    assert_equal %w[lvgl zlib], submodules.built_in.names
    assert_equal 'third_party/zlib/zlib', submodules.fetch('zlib').path
  end

  def test_an_unknown_submodule_is_refused
    error = assert_raises(Erx::Error) { Erx::Submodules::TREE.fetch('quake') }
    assert_match(/unknown submodule quake; the submodules are #{Erx::Submodules::TREE.names.join(', ')}/, error.message)
  end

  # Each form git reads differently from the reader would change a role or a path
  # without a word; each is refused instead.
  def test_a_form_the_reader_does_not_read_as_git_does_is_refused
    assert_match(/\.gitmodules:5: a line that is neither/, refusal("#{EXAMPLE}[include]\n"))
    assert_match(/neither/, refusal("#{EXAMPLE}\tpath = examples/a/a # a comment\n"))
    assert_match(/neither/, refusal(EXAMPLE.sub('update = none', 'update = "none"')))
    assert_match(/neither/, refusal(EXAMPLE.sub('update = none', "update = none\\\n")))
    assert_match(/a setting before any submodule/, refusal("\tpath = a\n"))
  end

  def test_an_entry_that_is_not_well_formed_is_refused
    assert_match(/lacks its url/, refusal("[submodule \"a\"]\n\tpath = a\n"))
    assert_match(%r{has path examples/b}, refusal(EXAMPLE.sub('path = examples/a/a', 'path = examples/b')))
    assert_match(/plain components/, refusal(EXAMPLE.gsub('examples/a/a', 'examples/..')))
    assert_match(/plain components/, refusal(EXAMPLE.gsub('examples/a/a', '/examples/a')))
    assert_match(/two submodules are called a/, refusal(EXAMPLE + EXAMPLE.gsub('examples/a/a', 'examples/b/a')))
  end

  # The two facts that say an example, its update setting and its directory, must agree.
  def test_the_two_marks_of_an_example_must_agree
    assert_match(/exactly when it lies under examples/, refusal(EXAMPLE.gsub('examples/a/a', 'third_party/a')))
    assert_match(/exactly when it lies under examples/, refusal(EXAMPLE.sub("\tupdate = none\n", '')))
  end

  # A submodule added to .gitmodules alone reaches the tools' every list of submodules:
  # a copy of the tools beside a .gitmodules that names two more is loaded, and the
  # lists the tools hold are printed.
  def test_a_submodule_added_to_gitmodules_alone_is_seen_by_every_list
    tools = File.join(@directory, 'tools', 'lib')
    FileUtils.mkdir_p(tools)
    FileUtils.cp_r(File.join(ROOT, 'tools', 'lib', 'erx'), tools)
    File.write(File.join(@directory, '.gitmodules'), File.read(File.join(ROOT, '.gitmodules')) + EXTRA)
    program = "require 'json'; require 'erx/example_fetch'; require 'erx/origin'; " \
              'puts JSON.generate([Erx::Origin::SUBMODULES, Erx::ExampleFetch::EXAMPLES.names, ' \
              'Erx::Submodules::TREE.built_in.names])'
    output, status = Open3.capture2e(RbConfig.ruby, '-I', tools, '-e', program)
    assert status.success?, output
    paths, examples, built_in = JSON.parse(output)
    assert_equal [*Erx::Submodules::TREE.paths, 'examples/quake/quake', 'third_party/zlib/zlib'], paths
    assert_equal %w[doom quake], examples
    assert_equal %w[lvgl zlib], built_in
  end
end
