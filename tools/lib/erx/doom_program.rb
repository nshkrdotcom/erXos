# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require_relative 'compile_memo'
require_relative 'error'
require_relative 'example_fetch'
require_relative 'git_environment'
require_relative 'native_root'
require_relative 'pack_provenance'
require_relative 'source_revision'
require_relative 'submodules'

module Erx
  # Doom, the example 0.1's published media carry as the program /bin/doom of the domain
  # release (docs/design.md's dependency table, status example): doomgeneric with erXos's
  # platform layer, from the example's fork checked out by `tools/erx fetch --example doom`
  # (ExampleFetch), and Freedoom's WAD, which the fork's wad.S links into the program. Only
  # a published medium carries it (ProductionImage#build_medium's doom:), so no other build
  # reads the fork and a tree without it builds every other image.
  #
  # The image's source offer names the fork at the commit the tree's gitlink records, so
  # the build refuses a checkout at any other commit, or one with changes (check_fetched),
  # and compiles that commit's own files, written from git's objects into a snapshot in
  # the build tree (snapshot), never the checkout's working files, which can differ from
  # the commit where git status does not show it. No file of the fork enters the tree.
  module DoomProgram
    NAME = 'doom'
    EXAMPLE = Submodules::TREE.examples.fetch(NAME)
    # The WAD, where ExampleFetch puts the release archive deps.lock pins, and its own
    # SHA-256, Freedoom 0.13.0's freedoom1.wad: the build refuses any other file at that
    # path (a fork that moved to another release changes deps.lock's directory, so the
    # WAD is then missing), and the digest is in wad.S's compile command, so the compile
    # memo, which cannot see an .incbin file, keys the object by the WAD's content.
    WAD = File.join(ExampleFetch::WORKSPACE, NAME, 'build/third_party/freedoom/freedoom-0.13.0/freedoom1.wad')
    WAD_SHA256 = '7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d'
    # Doom's archive, at one path the build alone writes, which PackProvenance admits as
    # the one input registered example (PackProvenance#example_archive?).
    ARCHIVE = PackProvenance::EXAMPLE_ARCHIVE
    OBJECTS = 'build/doom/obj'
    # The pinned commit's files (snapshot), which the build compiles and whose LICENSE the
    # image's notices take.
    SNAPSHOT = 'build/doom/source'
    # git as SourceRevision runs it, with replace objects off, so no object of the fork's
    # refs/replace stands in for one the commit names.
    GIT = [*SourceRevision::GIT, '--no-replace-objects'].freeze
    # A record of `git ls-tree -r -z`: a regular file's blob and its path. The file's mode,
    # which nothing the build runs needs, is not kept.
    TREE_ENTRY = /\A100(?:644|755) blob (\h{40})\t(.+)\z/m
    # A part of a path the snapshot writes: plain ASCII, so no two parts that differ in
    # bytes can name one file on a case-insensitive or normalizing filesystem except by
    # case, which creating each file exclusively catches (write_blob). `.`, `..` and `.git`
    # in any case are refused besides.
    PATH_PART = /\A[A-Za-z0-9._+-]+\z/
    # The header `git cat-file --batch` writes before each object's bytes.
    BATCH_HEADER = /\A(\h{40}) blob (\d+)\n\z/
    Entry = Data.define(:oid, :path)
    # The archive holds doomgeneric (GPL-2.0-or-later; the fork's LICENSE is the GPL-2.0
    # text) and the WAD (BSD-3-Clause; Freedoom's COPYING.txt).
    LICENSE = 'GPL-2.0-or-later AND BSD-3-Clause'
    NOTICES = [File.join(SNAPSHOT, 'LICENSE'), File.join(File.dirname(WAD), 'COPYING.txt')].freeze

    # doomgeneric's portable sources (its Makefile's SRC_DOOM) less the X11 platform part,
    # whose job erXos's doomgeneric_erxos.c does.
    DOOM_SOURCES = %w[dummy am_map doomdef doomstat dstrings d_event d_items d_iwad d_loop d_main d_mode d_net
                      f_finale f_wipe g_game hu_lib hu_stuff info i_cdmus i_endoom i_joystick i_scale i_sound
                      i_system i_timer memio m_argv m_bbox m_cheat m_config m_controls m_fixed m_menu m_misc
                      m_random p_ceilng p_doors p_enemy p_floor p_inter p_lights p_map p_maputl p_mobj p_plats
                      p_pspr p_saveg p_setup p_sight p_spec p_switch p_telept p_tick p_user r_bsp r_data r_draw
                      r_main r_plane r_segs r_sky r_things sha1 sounds statdump st_lib st_stuff s_sound tables
                      v_video wi_stuff w_checksum w_file w_main w_wad z_zone w_file_stdc i_input i_video
                      doomgeneric].freeze
    # The platform layer and its key table, which compile with warnings as errors.
    GLUE_SOURCES = %w[doomgeneric_erxos erxdoom_keys].freeze
    DEADLINE = 120

    module_function

    # Where the build reads Doom's sources: their directory in the snapshot.
    def source_directory(root) = File.join(root, SNAPSHOT, 'doomgeneric')

    # Refuses a published build in a tree whose fork is not fetched, is checked out at a
    # commit other than the gitlink's, or holds changes, or whose WAD is not WAD_SHA256's,
    # before anything is built. The bytes compiled are the gitlink's commit whatever the
    # checkout holds (snapshot); this refusal is the published build's diagnostic for a
    # checkout that does not match it, which the image's record would otherwise mark as a
    # tree that differs from its commit (SourceRevision) and refuse to publish without
    # naming the fork. wad_sha256 is a test's stand-in for WAD_SHA256.
    def check_fetched(root:, runner:, wad_sha256: WAD_SHA256)
      fork = File.join(root, EXAMPLE.path)
      unless File.exist?(File.join(fork, '.git')) && File.file?(File.join(root, WAD))
        raise Error, "the published medium carries Doom, which is not fetched: run `tools/erx fetch --example #{NAME}` " \
                     "(#{EXAMPLE.path} and #{WAD})"
      end
      wad = Digest::SHA256.file(File.join(root, WAD)).hexdigest
      raise Error, "#{WAD} has SHA-256 #{wad}, not Freedoom 0.13.0's #{wad_sha256}: fetch it again" unless wad == wad_sha256

      pinned = pinned_commit(root: root, runner: runner)
      revision = SourceRevision.read(root: fork, runner: runner)
      return if revision.commit == pinned && !revision.dirty

      raise Error, "#{EXAMPLE.path} is at #{revision}, not the commit #{pinned} the tree's gitlink records, which the " \
                   'published medium offers as its source: check that commit out, with no changes'
    end

    # Writes the pinned commit's files into SNAPSHOT under root, made afresh, each with the
    # bytes of its blob in the fork's object store, and answers source_directory. What the
    # build compiles is then that commit, as the fetch verified its objects, by
    # construction: neither the checkout's working files (an edit under assume-unchanged
    # or skip-worktree, an ignored file) nor what git does when it writes a file out (the
    # filters and line-end conversion that the checkout's own attributes and configuration
    # name, which `git archive` applies too) reach it.
    def snapshot(root:, runner:)
      commit = pinned_commit(root: root, runner: runner)
      directory = File.join(root, SNAPSHOT)
      FileUtils.rm_rf(directory)
      FileUtils.mkdir_p(directory)
      Dir.mktmpdir('erx-doom-snapshot-') do |work|
        listing, wanted, answers = %w[listing wanted answers].map { File.join(work, it) }
        fork_git(['ls-tree', '-r', '-z', '--full-tree', commit], root: root, runner: runner, name: 'doom-tree', stdout: listing)
        entries = File.binread(listing).split("\0").map { tree_entry(it) }
        File.write(wanted, entries.map { "#{it.oid}\n" }.join)
        fork_git(%w[cat-file --batch], root: root, runner: runner, name: 'doom-blobs', stdin: wanted, stdout: answers)
        File.open(answers, 'rb') do |batch|
          entries.each { write_blob(batch, it, directory: directory) }
          raise Error, "git cat-file answered more than the #{entries.size} blobs of #{commit}" unless batch.eof?
        end
      end
      source_directory(root)
    end

    def pinned_commit(root:, runner:)
      result = runner.run([*GIT, 'rev-parse', '--verify', "HEAD:#{EXAMPLE.path}"],
                          name: 'doom-gitlink', deadline: SourceRevision::DEADLINE, chdir: root, env: GitEnvironment.isolated)
      commit = File.binread(result.fetch('log')).chomp
      raise Error, "the tree's gitlink for #{EXAMPLE.path} is not a commit: #{commit.dump}" unless commit.match?(/\A\h{40}\z/)

      commit
    end
    private_class_method :pinned_commit

    def fork_git(arguments, root:, runner:, name:, stdin: nil, stdout: nil)
      runner.run([*GIT, *arguments], name: name, deadline: SourceRevision::DEADLINE, chdir: File.join(root, EXAMPLE.path),
                                     env: GitEnvironment.isolated, stdin: stdin, stdout: stdout)
    end
    private_class_method :fork_git

    # A regular file of the commit's tree, at a path of PATH_PART parts below the snapshot.
    def tree_entry(record)
      oid, path = TREE_ENTRY.match(record)&.captures
      unless oid && path.split('/', -1).all? { |part| PATH_PART.match?(part) && !%w[. ..].include?(part) && !part.casecmp?('.git') }
        raise Error, "#{EXAMPLE.path}'s pinned commit holds #{record.dump}, which is not a regular file at a plain path"
      end

      Entry.new(oid: oid, path: path)
    end
    private_class_method :tree_entry

    # Reads entry's blob from batch, `git cat-file --batch`'s answer, as a cursor: the
    # header naming the object, its type and size, then the bytes and a newline. The file
    # is created exclusively, so two paths that name one file fail instead of overwriting.
    def write_blob(batch, entry, directory:)
      oid, size = BATCH_HEADER.match(batch.gets("\n").to_s)&.captures
      bytes = batch.read(size.to_i) if oid == entry.oid
      unless bytes&.bytesize == size.to_i && batch.read(1) == "\n"
        raise Error, "git cat-file did not answer #{entry.oid}, #{entry.path}'s blob"
      end

      path = File.join(directory, entry.path)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY) { it.write(bytes) }
    rescue SystemCallError => error
      raise Error, "cannot write #{entry.path} of #{EXAMPLE.path}'s pinned commit into #{SNAPSHOT}: #{error.message}"
    end
    private_class_method :write_blob

    # /bin/doom, linked as a task over libdoom.a and archives, musl's libc.a and the
    # compiler's runtime, by native (NativeRoot), into directory.
    class Program
      def initialize(root:, runner:, native:, compiler:, archives:, directory:)
        @root = File.expand_path(root)
        @runner = runner
        @native = native
        @compiler = compiler
        @archives = archives
        @directory = directory
      end

      # NativeRoot#build_task_receipted's result, with archive, libdoom.a's path. The fork
      # and the WAD are checked first (DoomProgram.check_fetched, which
      # ProductionImage#build_medium runs), and the sources compiled are a snapshot of the
      # pinned commit taken here (DoomProgram.snapshot).
      def call
        archive = library
        @native.build_task_receipted(name: NAME, sources: NativeRoot::PROGRAM, directory: @directory,
                                     archives: [archive, *@archives])
               .merge(archive: archive).freeze
      end

      private

      # libdoom.a from Doom, the glue and wad.S, with the task code generation and musl's
      # headers.
      def library
        source = DoomProgram.snapshot(root: @root, runner: @runner)
        objects = File.join(@root, OBJECTS)
        FileUtils.mkdir_p(objects)
        memo = CompileMemo.new(root: @root, runner: @runner)
        units = [*DOOM_SOURCES.map { |name| [name, %w[-w]] }, *GLUE_SOURCES.map { |name| [name, %w[-Wall -Werror]] }]
        built = units.map do |name, warnings|
          compile(memo, [*c_flags(source), *warnings], source: File.join(source, "#{name}.c"), objects: objects)
        end
        wad = compile(memo, [*NativeRoot::CODE_FLAGS, %(-DERXDOOM_WAD_PATH="#{File.join(@root, WAD)}"),
                             "-DERXDOOM_WAD_SHA256=#{WAD_SHA256}"],
                      source: File.join(source, 'wad.S'), objects: objects)
        archive = File.join(@root, ARCHIVE)
        FileUtils.rm_f(archive)
        @runner.run([File.join(File.dirname(@compiler), 'llvm-ar'), 'rcs', archive, *built, wad],
                    name: 'doom-archive', deadline: DEADLINE, chdir: @root)
        archive
      end

      # Doom's C flags, as the fork's own build has them, with the fork's tree mapped to
      # doom/ in what the objects record, so no image holds the build's path (BuildPath).
      def c_flags(source)
        [*NativeRoot::CODE_FLAGS, "-ffile-prefix-map=#{source}=doom", '-isystem',
         File.join(@root, NativeRoot.libc_headers(@root)), '-D_DEFAULT_SOURCE', '-DNORMALUNIX', '-DLINUX',
         '-Dfopen=erxdoom_fopen', '-std=gnu17', '-I', source]
      end

      def compile(memo, flags, source:, objects:)
        object = File.join(objects, "#{File.basename(source, '.*')}.o")
        argv = [@compiler, *flags, '-MMD', '-MF', "#{object}.d", '-c', source, '-o', object]
        memo.compile(argv, chdir: @root, object: object, depfile: "#{object}.d") do |command, environment|
          @runner.run(command, name: "doom-#{File.basename(source).tr('.', '-').downcase}", deadline: DEADLINE,
                               chdir: @root, env: environment)
        end
        object
      end
    end
  end
end
