# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rubygems/package'
require 'stringio'
require 'zlib'
require 'socket'
require_relative '../../tools/lib/erx/dependencies'

# The real runner, which extracts archives, except that it refuses to run docker, which would contact a registry.
class NoDockerRunner < Erx::Runner
  def run(argv, **options)
    raise Erx::Error, "docker must not run: #{argv.join(' ')}" if argv.first == 'docker'

    super
  end
end

class DependenciesTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('erx-deps-')
    # Another checkout's downloads directory: the source cache, which holds the archives.
    @cache = File.join(@directory, 'other/build/downloads')
    FileUtils.mkdir_p(@cache)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def source
    { 'id' => 'fixture', 'kind' => 'tar', 'version' => '1', 'url' => 'https://example.org/source.tar.gz',
      'sha256' => 'a' * 64, 'directory' => 'source-1', 'license' => 'MIT',
      'status' => 'permanent' }
  end

  def parse(sources)
    Erx::DependencySchema.parse(JSON.generate('version' => 1, 'sources' => sources))
  end

  def test_valid_lock_is_immutable
    result = parse([source])
    assert result.frozen?
    assert result.first.frozen?
    assert result.first.fetch('id').frozen?
  end

  def test_pinned_file_has_a_filename_instead_of_archive_directory
    entry = source.reject { |key, _value| key == 'directory' }
                  .merge('kind' => 'file', 'filename' => 'tool.jar')
    assert_equal 'file', parse([entry]).first.fetch('kind')
    assert_raises(Erx::Error) { parse([entry.merge('directory' => 'wrong')]) }
  end

  # A file may pin the image it encodes by the decoded bytes' SHA-256 and size, both or
  # neither, and only a file may.
  def test_a_file_pins_its_decoded_image_by_hash_and_size_together
    entry = source.except('directory').merge('kind' => 'file', 'filename' => 'seed')
    pinned = entry.merge('decoded_sha256' => 'b' * 64, 'decoded_bytes' => 64 << 20)
    assert_equal 64 << 20, parse([pinned]).first.fetch('decoded_bytes')
    [pinned.except('decoded_bytes'), pinned.except('decoded_sha256'),
     pinned.merge('decoded_sha256' => 'B' * 64), pinned.merge('decoded_sha256' => 'b' * 63),
     pinned.merge('decoded_bytes' => '67108864'), pinned.merge('decoded_bytes' => 0),
     pinned.merge('decoded_bytes' => (1 << 30) + 1), pinned.merge('decoded_bytes' => 1.5),
     source.merge('decoded_sha256' => 'b' * 64, 'decoded_bytes' => 1)].each do |bad|
      assert_raises(Erx::Error, bad.inspect) { parse([bad]) }
    end
  end

  # A zip is a prebuilt program for the one host it names, and only that host fetches it.
  def test_a_zip_names_its_host_and_another_host_leaves_it_out
    zip = source.merge('kind' => 'zip', 'host' => 'darwin-arm64')
    assert_equal 'darwin-arm64', parse([zip]).first.fetch('host')
    assert_raises(Erx::Error) { parse([zip.except('host')]) }
    assert_raises(Erx::Error) { parse([zip.merge('host' => 'freebsd-amd64')]) }
    assert_raises(Erx::Error) { parse([source.merge('host' => 'darwin-arm64')]) }
    assert(Erx::DependencySchema.for_host?(zip, platform: 'arm64-darwin25'))
    refute(Erx::DependencySchema.for_host?(zip, platform: 'x86_64-darwin24'))
    refute(Erx::DependencySchema.for_host?(zip, platform: 'amd64-freebsd16'))

    lock = File.join(@directory, 'deps.lock')
    File.write(lock, JSON.generate('version' => 1, 'sources' => [zip]))
    elsewhere = Erx::Dependencies.new(root: @directory, runner: nil, lock_path: lock, platform: 'amd64-freebsd16')
    assert_empty elsewhere.sources, 'every caller that walks sources leaves it out'
    assert_equal [zip], elsewhere.elsewhere
    elsewhere.fetch(cache: @cache)
    refute File.exist?(File.join(@directory, 'build')), 'a program for another host is not fetched'
    error = assert_raises(Erx::Error) { elsewhere.fetch(cache: @cache, source_ids: ['fixture']) }
    assert_includes error.message, 'darwin-arm64'
  end

  def test_unknown_fields_fail
    assert_raises(Erx::Error) { parse([source.merge('unknown' => 'field')]) }
  end

  # A lock entry takes any status of docs/design.md's dependency table, and no other.
  def test_each_status_of_the_dependency_table_is_admitted
    %w[permanent release stopgap example].each do |status|
      assert_equal status, parse([source.merge('status' => status)]).first.fetch('status')
    end
    assert_raises(Erx::Error) { parse([source.merge('status' => 'tools')]) }
  end

  def test_duplicates_fail
    assert_raises(Erx::Error) { parse([source, source]) }
  end

  def test_unsafe_source_fields_fail
    [{ 'id' => '../escape' }, { 'directory' => '/absolute' },
     { 'sha256' => 'short' }, { 'url' => 'http://example.org/source' },
     { 'url' => 'https://user:secret@example.org/source' },
     { 'status' => 'unknown' }].each do |change|
      assert_raises(Erx::Error) { parse([source.merge(change)]) }
    end
  end

  def test_invalid_json_is_a_domain_error
    assert_raises(Erx::Error) { Erx::DependencySchema.parse('{') }
  end

  def test_invalid_utf8_json_is_a_domain_error
    bytes = JSON.generate('version' => 1, 'sources' => [source]).b
    bytes = bytes.sub('fixture'.b, "\xff".b)
    assert_raises(Erx::Error) { Erx::DependencySchema.parse(bytes) }
  end

  def image_source
    { 'id' => 'image', 'kind' => 'oci', 'version' => 'fixture',
      'repository' => 'docker.io/library/ruby', 'platform' => 'linux/arm64',
      'sha256' => 'a' * 64, 'config_sha256' => 'b' * 64,
      'license' => 'development image licenses', 'status' => 'permanent' }
  end

  def test_oci_image_requires_a_platform_manifest_and_configuration_digest
    entry = image_source
    assert_equal 'oci', parse([entry]).first.fetch('kind')
    assert_raises(Erx::Error) { parse([entry.merge('sha256' => 'tag')]) }
    assert_raises(Erx::Error) { parse([entry.merge('repository' => '--privileged')]) }
    assert_raises(Erx::Error) { parse([entry.merge('config_sha256' => 'short')]) }
  end

  def test_oci_fetch_uses_frozen_local_endpoint_and_checks_identity
    socket_path = File.join(@directory, 'docker.sock')
    socket = UNIXServer.new(socket_path)
    runner = DockerFetchFixture.new(directory: @directory, endpoint: "unix://#{socket_path}",
                                    identity: { 'Os' => 'linux', 'Architecture' => 'arm64',
                                                'Id' => "sha256:#{'b' * 64}",
                                                'RepoDigests' => ["ruby@sha256:#{'a' * 64}"] })
    lock = File.join(@directory, 'deps.lock')
    File.write(lock, JSON.generate('version' => 1, 'sources' => [image_source]))
    dependencies = Erx::Dependencies.new(root: @directory, runner: runner)
    definition = dependencies.image_for('image')
    assert_equal "docker.io/library/ruby@sha256:#{'a' * 64}", definition.fetch('reference')
    dependencies.fetch(source_ids: ['image'])
    pull = runner.calls.find { |call| call.fetch(:argv).include?('pull') }
    assert_equal ['docker', '--host', "unix://#{File.realpath(socket_path)}"], pull.fetch(:argv).take(3)
    assert_equal definition.fetch('reference'), pull.fetch(:argv).last
    assert_nil pull.fetch(:options).fetch(:env).fetch('DOCKER_API_VERSION')
    runner.identity['Id'] = "sha256:#{'a' * 64}"
    runner.identity['Descriptor'] = { 'digest' => "sha256:#{'a' * 64}" }
    dependencies.fetch(source_ids: ['image'])
    runner.identity['Id'] = "sha256:#{'c' * 64}"
    assert_raises(Erx::Error) { dependencies.fetch(source_ids: ['image']) }
  ensure
    socket&.close
  end

  def test_oci_fetch_rejects_nonlocal_and_malformed_endpoints_before_pull
    lock = File.join(@directory, 'deps.lock')
    File.write(lock, JSON.generate('version' => 1, 'sources' => [image_source]))
    ['tcp://example.org:2375', 'unix:relative.sock', 'unix://user:secret@/socket'].each do |endpoint|
      runner = DockerFetchFixture.new(directory: @directory, endpoint: endpoint, identity: {})
      dependencies = Erx::Dependencies.new(root: @directory, runner: runner)
      assert_raises(Erx::Error) { dependencies.fetch(source_ids: ['image']) }
      refute runner.calls.any? { |call| call.fetch(:argv).include?('pull') }
    end
  end

  def prepare_cached_source(tar_program: 'tar', members: nil)
    archive = File.join(@cache, 'source.tar.gz')
    stream = StringIO.new(''.b)
    Gem::Package::TarWriter.new(stream) do |tar|
      tar.mkdir('source-1', 0o755)
      tar.add_file_simple('source-1/file', 0o644, 4) { |file| file.write('safe') }
      yield tar if block_given?
    end
    Zlib::GzipWriter.open(archive) { |file| file.write(stream.string) }
    entry = source.merge('directory' => 'source-1',
                         'sha256' => Digest::SHA256.file(archive).hexdigest)
    entry['members'] = members if members
    keep_in_downloads(entry)
    lock = File.join(@directory, 'deps.lock')
    File.write(lock, JSON.generate('version' => 1, 'sources' => [entry]))
    runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    Erx::Dependencies.new(root: @directory, runner: runner, tar_program: tar_program)
  end

  # Files the archive in the downloads directory under the name Dependencies looks for.
  def keep_in_downloads(entry)
    FileUtils.cp(File.join(@cache, 'source.tar.gz'),
                 File.join(@cache, "#{entry.fetch('id')}-#{entry.fetch('sha256')}.tar.gz"))
  end

  def extracted_file
    File.join(@directory, 'build/third_party/fixture/source-1/file')
  end

  # A source pinned with members extracts only those paths below its directory, and a
  # members value that could name anything else is refused before any fetch.
  def test_members_extract_only_the_named_parts
    dependencies = prepare_cached_source(members: 'kept') do |tar|
      tar.mkdir('source-1/kept', 0o755)
      tar.add_file_simple('source-1/kept/inner', 0o644, 4) { |file| file.write('kept') }
    end
    dependencies.fetch(cache: @cache)
    tree = File.join(@directory, 'build/third_party/fixture/source-1')
    assert_equal 'kept', File.read(File.join(tree, 'kept/inner'))
    refute File.exist?(File.join(tree, 'file')), 'a path outside members is not extracted'
    ['', '../up', 'a/../b', 'a a', '/abs', 'a/./b'].each do |members|
      assert_raises(Erx::Error, members) { parse([source.merge('members' => members)]) }
    end
    assert_raises(Erx::Error) { parse([source.merge('directory' => '.', 'members' => 'a')]) }
  end

  def test_fetch_replaces_tampered_derived_source
    dependencies = prepare_cached_source
    dependencies.fetch(cache: @cache)
    File.write(extracted_file, 'tampered')
    dependencies.fetch(cache: @cache)
    assert_equal 'safe', File.read(extracted_file)
  end

  # The real runner, which also records the name of each command it runs.
  class RecordingRunner < Erx::Runner
    attr_reader :names

    def initialize(**options)
      super
      @names = []
    end

    def run(argv, name:, **options)
      @names << name
      super
    end
  end

  # A checkout whose build directory is a copy of this one's, and the
  # Dependencies of it whose runner records what fetch runs there.
  def copied_checkout
    copy = File.join(@directory, 'copy')
    Dir.mkdir(copy)
    FileUtils.cp(File.join(@directory, 'deps.lock'), copy)
    FileUtils.cp_r(File.join(@directory, 'build'), copy)
    runner = RecordingRunner.new(owner_root: copy, log_dir: File.join(copy, 'logs'))
    [Erx::Dependencies.new(root: copy, runner: runner), runner, File.join(copy, 'build/third_party/fixture')]
  end

  # A tree fetch published is kept, not extracted again, wherever its build
  # directory has been copied or moved, as long as it is the pin's and intact.
  def test_a_copied_build_directory_is_not_extracted_again
    prepare_cached_source.fetch(cache: @cache)
    dependencies, runner, destination = copied_checkout
    dependencies.fetch(cache: @cache)
    assert_empty runner.names
    assert_equal 'safe', File.read(File.join(destination, 'source-1/file'))
    assert dependencies.fetched?('fixture')
  end

  # A copied tree whose contents changed, or whose digest of them is missing or
  # wrong, or that other extraction code wrote, is extracted again; one whose record is missing or names another pin
  # or recipe is refused.
  def test_a_copied_tree_that_is_not_intact_is_not_kept
    prepare_cached_source.fetch(cache: @cache)
    dependencies, runner, destination = copied_checkout
    marker = File.join(destination, '.source.json')
    record = JSON.parse(File.read(marker))
    digest = File.join(destination, '.tree.sha256')
    [-> { File.write(File.join(destination, 'source-1/file'), 'tampered') },
     -> { File.write(File.join(destination, 'source-1/added'), 'added') },
     -> { File.chmod(0o755, File.join(destination, 'source-1/file')) },
     -> { File.write(digest, "#{'0' * 64}\n") },
     -> { File.unlink(digest) },
     -> { dependencies.define_singleton_method(:extractor_digest) { 'changed extraction code' } }].each do |damage|
      damage.call
      dependencies.fetch(cache: @cache)
      assert_equal ['extract-source'], runner.names
      assert_equal 'safe', File.read(File.join(destination, 'source-1/file'))
      refute File.exist?(File.join(destination, 'source-1/added'))
      runner.names.clear
    end
    [record.merge('sha256' => 'b' * 64), record.merge('members' => 'file'), record.merge('directory' => 'other')]
      .each do |other|
        File.write(marker, JSON.generate(other))
        assert_raises(Erx::Error) { dependencies.fetch(cache: @cache) }
        refute dependencies.fetched?('fixture')
      end
    File.unlink(marker)
    assert_raises(Erx::Error) { dependencies.fetch(cache: @cache) }
    assert_empty runner.names
  end

  def test_cached_archive_cannot_bypass_a_linked_download_directory
    dependencies = prepare_cached_source
    entry = JSON.parse(File.read(File.join(@directory, 'deps.lock'))).fetch('sources').first
    outside = File.join(@directory, 'external-cache')
    FileUtils.mkdir_p(outside)
    FileUtils.mkdir_p(File.join(@directory, 'build'))
    name = "fixture-#{entry.fetch('sha256')}.tar.gz"
    FileUtils.cp(File.join(@cache, 'source.tar.gz'), File.join(outside, name))
    File.symlink(outside, File.join(@directory, 'build/downloads'))
    assert_raises(Erx::Error) { dependencies.archive_for('fixture') }
  end

  def test_fetch_restores_missing_derived_source
    dependencies = prepare_cached_source
    dependencies.fetch(cache: @cache)
    File.unlink(extracted_file)
    dependencies.fetch(cache: @cache)
    assert_equal 'safe', File.read(extracted_file)
  end

  # Pins of the one cached archive, as fixture and other, and a pin of other
  # bytes, as bad.
  def two_sources
    prepare_cached_source
    entry = JSON.parse(File.read(File.join(@directory, 'deps.lock'))).fetch('sources').first
    sources = [entry, entry.merge('id' => 'other'), entry.merge('id' => 'bad', 'sha256' => '0' * 64)]
    sources.drop(1).each { |pinned| keep_in_downloads(pinned) }
    File.write(File.join(@directory, 'deps.lock'), JSON.generate('version' => 1, 'sources' => sources))
    runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    [Erx::Dependencies.new(root: @directory, runner: runner), entry]
  end

  # A directory an older fetch wrote, whose record lacks a field deps.lock's
  # entry has, is refused with what to do about it, and the sources after it
  # are still fetched. Each failure is reported after its source's id.
  def test_a_stale_source_names_its_fix_and_does_not_stop_the_others
    dependencies, entry = two_sources
    stale = File.join(@directory, 'build/third_party/fixture')
    FileUtils.mkdir_p(stale)
    File.write(File.join(stale, '.source.json'), JSON.generate(entry.except('kind')))
    error = assert_raises(Erx::Error) { dependencies.fetch(cache: @cache) }
    assert_equal "fixture: build/third_party/fixture does not hold deps.lock's pin of fixture; " \
                 'remove it and run `ruby tools/erx fetch --source fixture`; ' \
                 'bad: source SHA-256 mismatch: bad', error.message
    assert_equal 'safe', File.read(File.join(@directory, 'build/third_party/other/source-1/file'))
    refute dependencies.fetched?('fixture')
    assert dependencies.fetched?('other')
  end

  def test_fetched_tree_is_the_pinned_directory_of_a_recorded_fetch
    dependencies, = two_sources
    error = assert_raises(Erx::Error) { dependencies.fetched_tree('other') }
    assert_equal 'source other is not fetched; run `ruby tools/erx fetch --source other`', error.message
    dependencies.fetch(cache: @cache, source_ids: ['other'])
    assert_equal File.join(@directory, 'build/third_party/other/source-1'), dependencies.fetched_tree('other')
    assert_raises(Erx::Error) { dependencies.fetched_tree('unpinned') }
  end

  def test_fetch_refuses_symlink_destination
    dependencies = prepare_cached_source
    dependencies.fetch(cache: @cache)
    destination = File.join(@directory, 'build/third_party/fixture')
    moved = File.join(@directory, 'moved')
    File.rename(destination, moved)
    File.symlink(moved, destination)
    assert_raises(Erx::Error) { dependencies.fetch(cache: @cache) }
    assert_equal 'safe', File.read(File.join(moved, 'source-1/file'))
  end

  def test_tar_refuses_parent_traversal_before_publication
    dependencies = prepare_cached_source do |tar|
      tar.add_file_simple('../escape', 0o644, 3) { |file| file.write('bad') }
    end
    assert_raises(Erx::Error) { dependencies.fetch(cache: @cache) }
    refute File.exist?(File.join(@directory, 'build/third_party/fixture'))
    refute File.exist?(File.join(@directory, 'build/third_party/escape'))
  end

  def test_escaping_symlink_is_refused_before_publication
    dependencies = prepare_cached_source do |tar|
      tar.add_symlink('source-1/link', @directory, 0o777)
    end
    assert_raises(Erx::Error) { dependencies.fetch(cache: @cache) }
    refute File.exist?(File.join(@directory, 'build/third_party/fixture'))
  end

  def test_bad_hash_publishes_neither_archive_nor_tree
    dependencies = prepare_cached_source
    File.write(Dir.glob(File.join(@cache, 'fixture-*')).first, 'bad')
    assert_raises(Erx::Error) { dependencies.fetch(cache: @cache) }
    refute File.exist?(File.join(@directory, 'build/third_party/fixture'))
    assert_empty Dir.glob(File.join(@directory, 'build/downloads/*.tar.gz'))
  end

  # An OCI image is not in a source cache: fetching every source from a cache
  # fills the archives and leaves the image to its own fetch, never running docker. Naming the image with a cache is
  # refused.
  def test_a_cache_fills_the_archives_and_leaves_an_oci_image_unfetched
    prepare_cached_source
    entry = JSON.parse(File.read(File.join(@directory, 'deps.lock'))).fetch('sources').first
    File.write(File.join(@directory, 'deps.lock'), JSON.generate('version' => 1, 'sources' => [image_source, entry]))
    runner = NoDockerRunner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    dependencies = Erx::Dependencies.new(root: @directory, runner: runner)
    dependencies.fetch(cache: @cache)
    assert_equal 'safe', File.read(extracted_file)
    assert_equal [image_source], dependencies.images
    error = assert_raises(Erx::Error) { dependencies.fetch(cache: @cache, source_ids: ['image']) }
    assert_includes error.message, 'without --cache'
  end

  # An archive already in this checkout's build/downloads is used as it is; the cache is not read for it.
  def test_a_cache_fetch_leaves_an_archive_already_in_downloads_alone
    dependencies = prepare_cached_source
    dependencies.fetch(cache: @cache)
    FileUtils.rm(Dir.glob(File.join(@cache, 'fixture-*')))
    File.unlink(extracted_file)
    dependencies.fetch(cache: @cache)
    assert_equal 'safe', File.read(extracted_file)
  end

  def test_a_cache_that_is_not_a_directory_is_refused_once
    dependencies = prepare_cached_source
    ['', File.join(@directory, 'absent')].each do |cache|
      error = assert_raises(Erx::Error) { dependencies.fetch(cache: cache) }
      assert_includes error.message, 'not a directory'
    end
  end

  def test_missing_cache_does_not_fall_back_to_network
    dependencies = prepare_cached_source
    FileUtils.rm(Dir.glob(File.join(@cache, 'fixture-*')))
    assert_raises(Erx::Error) { dependencies.fetch(cache: @cache) }
    refute File.exist?(File.join(@directory, 'build/third_party/fixture'))
  end

  def test_host_tar_option_environment_cannot_change_extraction
    tar = ENV.fetch('PATH').split(File::PATH_SEPARATOR)
             .map { |directory| File.join(directory, 'gtar') }
             .find { |path| File.executable?(path) } || 'tar'
    dependencies = prepare_cached_source(tar_program: tar)
    variables = %w[TAR_OPTIONS TAR_READER_OPTIONS TAR_WRITER_OPTIONS]
    previous = variables.to_h { |name| [name, ENV[name]] }
    ENV['TAR_OPTIONS'] = '--erx-invalid-option'
    ENV['TAR_READER_OPTIONS'] = 'erx-invalid-option'
    ENV['TAR_WRITER_OPTIONS'] = 'erx-invalid-option'
    dependencies.fetch(cache: @cache)
    assert_equal 'safe', File.read(extracted_file)
  ensure
    previous&.each { |name, value| ENV[name] = value }
  end

  def test_absolute_path_cannot_be_written_with_host_tar_options
    tar = ENV.fetch('PATH').split(File::PATH_SEPARATOR)
             .map { |directory| File.join(directory, 'gtar') }
             .find { |path| File.executable?(path) } || 'tar'
    outside = File.join(@directory, 'outside')
    dependencies = prepare_cached_source(tar_program: tar) do |writer|
      writer.add_file_simple(outside, 0o644, 3) { |file| file.write('bad') }
    end
    previous = ENV['TAR_OPTIONS']
    ENV['TAR_OPTIONS'] = '--absolute-names'
    assert_raises(Erx::Error) { dependencies.fetch(cache: @cache) }
    refute File.exist?(outside), 'tar wrote outside its private extraction directory'
  ensure
    ENV['TAR_OPTIONS'] = previous
  end
end

class DockerFetchFixture
  attr_reader :calls, :identity

  def initialize(directory:, endpoint:, identity:)
    @directory = directory
    @endpoint = endpoint
    @identity = identity
    @calls = []
  end

  def run(argv, **options)
    @calls << { argv: argv, options: options }
    text = if argv.include?('show')
             "orbstack\n"
           elsif argv.include?('context')
             @endpoint + "\n"
           elsif argv.include?('pull')
             "pulled fixture\n"
           else
             JSON.generate(@identity)
           end
    log = File.join(@directory, "docker-fixture-#{@calls.size}.log")
    File.write(log, text)
    { 'log' => log, 'state' => 'succeeded', 'exit_status' => 0 }
  end
end
