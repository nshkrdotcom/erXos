# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/example_fetch'
require_relative '../../tools/lib/erx/origin'
require_relative '../../tools/lib/erx/setup'

# `tools/erx fetch --example NAME` (docs/design-packaging.md, "Examples"): the example's
# repository, a git submodule, and the downloads its deps.lock pins. The tests use a
# local git repository standing in for the example and a local file standing in for its
# download, which the source cache supplies, so nothing reaches the network.
class ExampleFetchTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  WAD = 'fake wad bytes'
  GIT = ['git', '-c', 'user.name=test', '-c', 'user.email=test@example.org', '-c', 'protocol.file.allow=always'].freeze

  def setup
    @directory = Dir.mktmpdir('erx-example-fetch-')
    @repository = File.join(@directory, 'example')
    @root = File.join(@directory, 'tree')
    @cache = File.join(@directory, 'cache')
    FileUtils.mkdir_p([@repository, @root, @cache])
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def git(directory, *arguments)
    output, status = Open3.capture2e(*GIT, '-C', directory, *arguments)
    raise "git #{arguments.join(' ')}: #{output}" unless status.success?

    output.strip
  end

  def lock(sources) = JSON.generate('version' => 1, 'sources' => sources)

  def download(kind: 'file')
    { 'id' => 'fakewad', 'kind' => kind, 'version' => '1', 'url' => 'https://example.invalid/fake.wad',
      'sha256' => Digest::SHA256.hexdigest(WAD), 'filename' => 'fake.wad', 'license' => 'BSD-3-Clause',
      'status' => 'permanent' }
  end

  # An example repository holding the lock, as the super-repository's gitlink pins it.
  def example(sources: [download])
    git(@repository, 'init', '--quiet')
    File.write(File.join(@repository, 'deps.lock'), lock(sources))
    git(@repository, 'add', 'deps.lock')
    git(@repository, 'commit', '--quiet', '-m', 'the example')
    commit = git(@repository, 'rev-parse', 'HEAD')
    git(@root, 'init', '--quiet')
    path = Erx::ExampleFetch::EXAMPLES.fetch('doom').path
    File.write(File.join(@root, '.gitmodules'), "[submodule \"#{path}\"]\n\tpath = #{path}\n\turl = #{@repository}\n\tupdate = none\n")
    git(@root, 'update-index', '--add', '--cacheinfo', "160000,#{commit},#{path}")
    File.write(File.join(@cache, "fakewad-#{Digest::SHA256.hexdigest(WAD)}.wad"), WAD)
    path
  end

  def fetch(**options) = Erx::ExampleFetch.fetch(name: 'doom', root: @root, runner: @runner, cache: @cache, **options)

  def test_clones_the_example_at_its_pinned_commit_and_fetches_its_downloads_verified
    path = example
    lines = fetch
    assert_equal git(@repository, 'rev-parse', 'HEAD'), git(File.join(@root, path), 'rev-parse', 'HEAD')
    wad = File.join(@root, 'build/examples/doom/build/third_party/fakewad/fake.wad')
    assert_equal WAD, File.binread(wad)
    assert_equal ['doom: cloned examples/doom/doom at the commit its gitlink records',
                  'doom: fakewad 1 fetched to build/examples/doom/build/third_party/fakewad'], lines
  end

  def test_a_checkout_that_is_there_is_left_as_it_is
    path = example
    fetch
    File.write(File.join(@root, path, 'work.txt'), 'in progress')
    assert_equal 'doom: examples/doom/doom is already checked out; left as it is', fetch.first
    assert_equal 'in progress', File.read(File.join(@root, path, 'work.txt'))
  end

  def test_a_download_that_does_not_match_its_pin_is_refused_and_publishes_nothing
    example
    File.write(Dir[File.join(@cache, '*.wad')].first, 'tampered')
    error = assert_raises(Erx::Error) { fetch }
    assert_match(/fakewad/, error.message)
    refute File.exist?(File.join(@root, 'build/examples/doom/build/third_party/fakewad'))
  end

  def test_the_example_cannot_ask_for_a_git_or_image_source
    example(sources: [{ 'id' => 'clone', 'kind' => 'git', 'version' => '1', 'url' => 'https://example.invalid/x.git',
                        'sha256' => 'a' * 64, 'directory' => 'x', 'commit' => 'b' * 40, 'license' => 'MIT',
                        'status' => 'permanent' }])
    error = assert_raises(Erx::Error) { fetch }
    assert_match(/git source/, error.message)
    refute File.exist?(File.join(@root, 'build/examples/doom/build/downloads'))
  end

  def test_a_lock_that_is_a_symbolic_link_is_refused
    path = example
    fetch
    lock = File.join(@root, path, 'deps.lock')
    File.delete(lock)
    File.symlink('/etc/hosts', lock)
    assert_match(/holds no deps.lock/, assert_raises(Erx::Error) { fetch }.message)
  end

  def test_an_unknown_example_is_refused
    error = assert_raises(Erx::Error) { Erx::ExampleFetch.fetch(name: 'quake', root: @root, runner: @runner) }
    assert_match(/unknown example quake/, error.message)
  end

  # make check and the landing gate never need the example: setup, which prepares a
  # tree for them, fetches only deps.lock's sources, and deps.lock pins nothing of it.
  def test_nothing_the_gates_run_fetches_or_builds_the_example
    lock = File.read(File.join(ROOT, 'deps.lock'))
    refute_match(/freedoom|doom/i, lock)
    steps = Erx::Setup.steps(JSON.parse(lock).fetch('sources'))
    assert_empty steps.select { |step| step.name.match?(/doom|example/) || step.argv.join(' ').match?(/doom|example/) }
    refute_match(/examples\/doom|fetch --example/, File.read(File.join(ROOT, 'Makefile')))
  end

  def test_the_example_is_a_submodule_with_its_provenance_beside_it
    path = Erx::ExampleFetch::EXAMPLES.fetch('doom').path
    assert_includes Erx::Origin::SUBMODULES, path
    assert File.file?(File.join(ROOT, File.dirname(path), 'ORIGIN.md'))
  end

  def test_a_zip_source_may_name_every_host
    sources = Erx::DependencySchema.parse(lock([download(kind: 'zip').except('filename')
                                                  .merge('directory' => 'fake-1', 'host' => 'any')]))
    assert Erx::DependencySchema.for_host?(sources.first, platform: 'x86_64-linux')
  end
end
