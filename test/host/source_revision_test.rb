# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/source_revision'
require_relative '../../tools/lib/erx/submodules'

# The source revision a build records (Erx::SourceRevision): read from a
# scratch git checkout with a fixed commit date, so each case knows the
# answer; and the pure parse, which refuses an answer of the wrong shape.
class SourceRevisionTest < Minitest::Test
  SourceRevision = Erx::SourceRevision
  # 2026-11-08 18:42:33 UTC.
  COMMITTED = 1_794_163_353
  IDENTITY = { 'GIT_AUTHOR_NAME' => 'erXos test', 'GIT_AUTHOR_EMAIL' => 'test@example.invalid',
               'GIT_COMMITTER_NAME' => 'erXos test', 'GIT_COMMITTER_EMAIL' => 'test@example.invalid',
               'GIT_AUTHOR_DATE' => "#{COMMITTED} +0000", 'GIT_COMMITTER_DATE' => "#{COMMITTED} +0000",
               'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_CONFIG_NOSYSTEM' => '1' }.freeze

  def setup
    @scratch = File.realpath(Dir.mktmpdir('erx-source-revision-'))
    @tree = File.join(@scratch, 'tree')
    @runner = Erx::Runner.new(owner_root: @scratch, log_dir: File.join(@scratch, 'logs'))
    FileUtils.mkdir_p(@tree)
  end

  def teardown
    FileUtils.remove_entry(@scratch) if @scratch
  end

  def git(*arguments)
    output, status = Open3.capture2e(IDENTITY, 'git', '-C', @tree, *arguments, in: File::NULL)
    raise "git #{arguments.join(' ')} failed: #{output}" unless status.success?

    output.chomp
  end

  def commit(text)
    File.write(File.join(@tree, 'file'), text)
    git('add', 'file')
    git('commit', '--quiet', '-m', text)
  end

  def checkout_of_two_commits
    git('init', '--quiet', '--initial-branch=main')
    commit('one')
    commit('two')
  end

  def read = SourceRevision.read(root: @tree, runner: @runner)

  def test_a_clean_checkout_gives_the_count_and_the_hash
    checkout_of_two_commits
    revision = read
    hash = git('rev-parse', '--short=12', 'HEAD')
    assert_equal [2, hash, false, Time.at(COMMITTED).utc],
                 [revision.count, revision.hash, revision.dirty, revision.committed_at]
    assert_equal "n2-#{hash}", revision.to_s
    assert_equal 12, revision.hash.size
  end

  def test_a_tracked_change_staged_or_not_marks_the_revision_dirty
    checkout_of_two_commits
    File.write(File.join(@tree, 'file'), 'three')
    assert read.dirty, 'an unstaged change'
    git('add', 'file')
    assert read.dirty, 'a staged change'
    assert_match(/-dirty\z/, read.to_s)
  end

  # The packer and the build glob directories, so an untracked source file is
  # built into the image or the card although no commit holds it.
  def test_an_untracked_file_that_git_does_not_ignore_marks_the_revision_dirty
    checkout_of_two_commits
    File.write(File.join(@tree, 'untracked'), 'x')
    assert read.dirty, 'an untracked file in the top directory'
    FileUtils.rm(File.join(@tree, 'untracked'))
    refute read.dirty
    FileUtils.mkdir_p(File.join(@tree, 'src/deep'))
    File.write(File.join(@tree, 'src/deep/module.erl'), 'x')
    assert read.dirty, 'an untracked file in an untracked directory'
    assert_match(/-dirty\z/, read.to_s)
  end

  def test_an_ignored_file_leaves_the_revision_clean
    checkout_of_two_commits
    File.write(File.join(@tree, '.gitignore'), "build/\n*.log\n")
    git('add', '.gitignore')
    git('commit', '--quiet', '-m', 'ignore')
    FileUtils.mkdir_p(File.join(@tree, 'build'))
    File.write(File.join(@tree, 'build/out'), 'x')
    File.write(File.join(@tree, 'run.log'), 'x')
    refute read.dirty
  end

  def test_one_commit_reads_the_same_revision_on_any_branch_or_none
    checkout_of_two_commits
    on_main = read
    git('checkout', '--quiet', '-b', 'fix#123')
    assert_equal on_main, read, 'another branch, of a name no revision shape admits'
    git('checkout', '--quiet', '--detach')
    assert_equal on_main, read, 'a detached head'
    assert_equal "n2-#{git('rev-parse', '--short=12', 'HEAD')}", read.to_s
  end

  def test_the_same_tree_reads_the_same_revision_twice
    checkout_of_two_commits
    File.write(File.join(@tree, 'file'), 'three')
    assert_equal read, read
  end

  def test_a_tree_that_is_not_a_checkout_has_no_revision
    assert_nil read
  end

  # A repository at path below the tree with two commits, the tree's gitlink pinning the
  # first and the checkout left at it; answers both commits.
  def submodule_at(path)
    directory = File.join(@tree, path)
    FileUtils.mkdir_p(directory)
    git('-C', directory, 'init', '--quiet', '--initial-branch=main')
    commits = %w[pinned later].map do |text|
      File.write(File.join(directory, 'file'), text)
      git('-C', directory, 'add', 'file')
      git('-C', directory, 'commit', '--quiet', '-m', text)
      git('-C', directory, 'rev-parse', 'HEAD')
    end
    git('-C', directory, 'checkout', '--quiet', commits.first)
    git('update-index', '--add', '--cacheinfo', "160000,#{commits.first},#{path}")
    git('commit', '--quiet', '-m', "pin #{path}")
    commits
  end

  # An example's checkout is the example's own repository, under its own configuration
  # and attributes, so git never enters it for the tree's status: a clean filter they
  # name does not run, and the checkout away from its gitlink leaves the tree clean.
  def test_an_example_submodule_is_not_entered
    checkout_of_two_commits
    path = Erx::Submodules::TREE.examples.paths.first
    _, later = submodule_at(path)
    example = File.join(@tree, path)
    marker = File.join(@scratch, 'filter-ran')
    File.write(File.join(example, '.git/info/attributes'), "* filter=mark\n")
    File.open(File.join(example, '.git/config'), 'a') { it.write("[filter \"mark\"]\n\tclean = \"touch #{marker}; cat\"\n") }
    # The same bytes at another time, which git can tell apart from the index's only by
    # running the file through its clean filter.
    File.utime(Time.at(COMMITTED), Time.at(COMMITTED), File.join(example, 'file'))
    refute read.dirty, 'an example checkout at its gitlink'
    refute File.exist?(marker), "git ran the example's clean filter"
    git('-C', example, 'checkout', '--quiet', later)
    refute read.dirty, 'an example checkout away from its gitlink'
  end

  # A built-in submodule is part of what the build compiles, so one checked out away
  # from its gitlink marks the tree dirty.
  def test_a_built_in_submodule_away_from_its_gitlink_marks_the_revision_dirty
    checkout_of_two_commits
    path = Erx::Submodules::TREE.built_in.paths.first
    _, later = submodule_at(path)
    refute read.dirty, 'a built-in submodule at its gitlink'
    git('-C', File.join(@tree, path), 'checkout', '--quiet', later)
    assert read.dirty, 'a built-in submodule away from its gitlink'
  end

  def answers(**changed)
    { commit: "0123456789abcdef0123456789abcdef01234567\n", shallow: "false\n", count: "7\n",
      committed: "#{COMMITTED}\n", changes: '' }.merge(changed)
  end

  def test_parse_reads_a_shallow_clone_without_its_count
    assert_equal '0123456789ab', SourceRevision.parse(answers(shallow: "true\n")).to_s
  end

  def test_parse_reads_an_untracked_line_as_a_change
    assert SourceRevision.parse(answers(changes: "?? src/new.erl\n")).dirty
  end

  def test_parse_refuses_an_answer_of_the_wrong_shape
    [{ commit: "main\n" }, { commit: "0123456789ab\n" }, { count: "-1\n" }, { count: "7a\n" },
     { committed: "soon\n" }, { shallow: "maybe\n" },
     { changes: "warning: could not open directory 'x/'\n" }].each do |changed|
      error = assert_raises(Erx::Error, changed.inspect) { SourceRevision.parse(answers(**changed)) }
      assert_includes error.message, changed.keys.first.to_s
    end
  end
end
