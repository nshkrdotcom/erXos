# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/doom_program'
require_relative '../../tools/lib/erx/production_image'
require_relative '../../tools/lib/erx/runner'

# The Doom example in the published media (DoomProgram): the build refuses a fork that is
# not fetched, at another commit than the gitlink's, or changed, and the image takes
# /bin/doom with libdoom.a attributed as the example.
class DoomProgramTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PLATFORM = Erx::Platform.development(ROOT)
  FORK = Erx::DoomProgram::EXAMPLE.path

  def setup
    @root = Dir.mktmpdir('erx-doom-')
    @runner = Erx::Runner.new(owner_root: @root, log_dir: File.join(@root, 'logs'))
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def git(directory, *arguments)
    out, status = Open3.capture2e('git', '-C', directory, '-c', 'user.name=t', '-c', 'user.email=t@t', '-c',
                                  'commit.gpgsign=false', *arguments, stdin_data: '')
    raise out unless status.success?

    out.chomp
  end

  # A superproject at @root whose gitlink pins the fork's first commit, the fork checked out
  # beside it with a second commit, and the WAD where the fetch puts it. Returns both
  # commits.
  def superproject
    fork = File.join(@root, FORK)
    FileUtils.mkdir_p(fork)
    git(fork, 'init', '-q')
    commits = %w[first second].map do |text|
      File.write(File.join(fork, 'LICENSE'), text)
      git(fork, 'add', 'LICENSE')
      git(fork, 'commit', '-q', '-m', text)
      git(fork, 'rev-parse', 'HEAD')
    end
    git(@root, 'init', '-q')
    git(@root, 'update-index', '--add', '--cacheinfo', "160000,#{commits.first},#{FORK}")
    git(@root, 'commit', '-q', '-m', 'pin')
    FileUtils.mkdir_p(File.join(@root, File.dirname(Erx::DoomProgram::WAD)))
    File.write(File.join(@root, Erx::DoomProgram::WAD), 'IWAD')
    commits
  end

  def check = Erx::DoomProgram.check_fetched(root: @root, runner: @runner, wad_sha256: Digest::SHA256.hexdigest('IWAD'))

  def test_the_build_refuses_an_example_not_fetched
    error = assert_raises(Erx::Error) { check }
    assert_match(/not fetched: run `tools\/erx fetch --example doom`/, error.message)
  end

  # The source offer names the gitlink's commit, so only that commit, unchanged, builds.
  def test_the_build_takes_only_the_pinned_commit_unchanged
    first, second = superproject
    error = assert_raises(Erx::Error) { check }
    assert_match(/at \S*#{second[0, 12]}, not the commit #{first} the tree's gitlink records/, error.message)

    git(File.join(@root, FORK), 'checkout', '-q', first)
    check
    # Any other file at the WAD's path than Freedoom 0.13.0's is refused.
    error = assert_raises(Erx::Error) { Erx::DoomProgram.check_fetched(root: @root, runner: @runner) }
    assert_match(/freedoom1\.wad has SHA-256 \h{64}, not Freedoom 0\.13\.0's #{Erx::DoomProgram::WAD_SHA256}/, error.message)
    File.write(File.join(@root, FORK, 'LICENSE'), 'changed')
    error = assert_raises(Erx::Error) { check }
    assert_match(/-dirty, not the commit/, error.message)
  end

  # /bin/doom is a program of the domain release, and its archive is attributed whole as
  # the example, with the GPL-2.0 text and Freedoom's license as its notices.
  def test_the_image_takes_bin_doom_as_the_example
    codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: ROOT).schema)
    doom = { program: '/b/doom', receipt: '/b/doom.receipt', inputs: ['/b/doom.o'], archive: '/b/libdoom.a' }
    parts = Erx::ProductionImage.example_parts(doom, codec: codec)
    assert_equal ["#{Erx::ReleaseFiles::DOMAIN_PREFIX}bin/doom"], parts.entries.map { it.fetch('path') }
    assert_equal ['/b/doom.o'], parts.inputs
    assert_equal 1, parts.archives.size
    archive = parts.archives.first
    assert_equal ['/b/libdoom.a', Erx::PackProvenance::EXAMPLE_LABEL, 'example'], [archive.path, archive.label, archive.status]
    assert_includes Erx::PackProvenance::EXAMPLE_LICENSES, archive.license
    assert_equal ["#{FORK}/LICENSE", File.join(File.dirname(Erx::DoomProgram::WAD), 'COPYING.txt')], archive.notices
  end

  # The website's image (InteractiveBoot, `tools/erx boot --without-web`: the site's machine
  # and manifest, through ProductionImage#build) never carries Doom: what it hands the one
  # build asks for no example, so domain_parts adds no bin/doom entry.
  def test_the_site_image_carries_no_doom
    image = Erx::ProductionImage.new(root: ROOT, runner: nil, compiler: '', linker: '',
                                     machine: Erx::ProductionImage::Machine.site(PLATFORM), fiasco: Object.new,
                                     runtime: nil, jit_runtime: nil)
    asked = nil
    image.define_singleton_method(:domain_boots) { |_source, given: []| given }
    image.define_singleton_method(:assemble) { |**arguments| asked = arguments }
    image.build(directory: '/nonexistent', manifest_source: PLATFORM.site_manifest_source(ROOT), record: true)
    refute asked.fetch(:doom, false), 'the site image asks for the Doom example'
    assert_empty(asked.fetch(:added).entries.map { it.fetch('path') }.grep(%r{bin/doom\z}))
  end

  # Only a published medium carries Doom, refused before anything is built.
  def test_only_a_published_medium_carries_doom
    machine = Erx::ProductionImage::Machine.development(PLATFORM)
    image = Erx::ProductionImage.new(root: ROOT, runner: nil, compiler: '', linker: '', machine: machine, fiasco: Object.new,
                                     runtime: nil, jit_runtime: nil)
    error = assert_raises(Erx::Error) { image.build_medium(directory: '/nonexistent', doom: true) }
    assert_equal 'only a published medium carries the Doom example', error.message
  end
end
