# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'rexml/document'
require 'tmpdir'
require_relative '../bounded_file'
require_relative '../build_memo'
require_relative '../dependencies'
require_relative '../error'
require_relative '../host_path'
require_relative '../output_directory'

module Erx
  module Book
    # cmark-gfm, the one parser of the book's Markdown
    # (docs/design-book-site.md, "Markdown to HTML"): built for the host from
    # deps.lock's pin into build/book-tools with CMake, and run once per file
    # by argument vector, under a deadline, writing its XML parse tree.
    #
    # The build is a build memo step (BuildMemo#in_place): an earlier build is
    # reused only while it is unchanged and its key (build_key) is the same;
    # otherwise it is replaced whole.
    class Cmark
      SOURCE_ID = 'cmark-gfm'
      OUTPUT = 'build/book-tools/cmark-gfm'
      MEMO_STEP = 'book-cmark'
      COMPILER = 'cc'
      CMAKE = 'cmake'
      CMAKE_OPTIONS = %w[-DCMAKE_BUILD_TYPE=Release -DCMARK_TESTS=OFF -DCMARK_SHARED=OFF -DCMARK_STATIC=ON].freeze
      BUILD_DEADLINE = 600
      PARSE_DEADLINE = 60
      # The extensions the book uses: GFM tables and autolinks.
      EXTENSIONS = %w[table autolink].freeze
      MAX_TREE_BYTES = 64 * 1024 * 1024

      attr_reader :version

      # The pinned cmark-gfm, built now unless the build memo holds a build
      # with the same inputs.
      def self.prepare(root:, runner:)
        dependencies = Dependencies.new(root:, runner:)
        source = dependencies.pinned(SOURCE_ID)
        output = File.join(root, OUTPUT)
        compiler, cmake = [COMPILER, CMAKE].map { |name| program(name) }
        key = build_key(sha256: source.fetch('sha256'), options: CMAKE_OPTIONS, compiler: BuildMemo.program_identity(compiler),
                        compiler_version: compiler_line(runner, compiler), cmake: BuildMemo.program_identity(cmake),
                        recipe: Digest::SHA256.file(__FILE__).hexdigest)
        BuildMemo.new(root:).in_place(MEMO_STEP, key:, outputs: [output]) do
          build(root:, runner:, tree: dependencies.fetched_tree(SOURCE_ID), compiler:, cmake:)
        end
        new(binary: File.join(output, 'cmark-gfm'), version: source.fetch('version'), runner:)
      end

      # The build's memo key: the archive, the fixed CMake options, the
      # compiler and CMake that run, by identity, and the recipe, this file,
      # which holds every argument vector of the build. The compiler is also
      # named by its version line, since /usr/bin/cc on macOS runs the
      # developer tools' clang, which an update replaces under the same
      # system release.
      def self.build_key(sha256:, options:, compiler:, compiler_version:, cmake:, recipe:)
        BuildMemo.key('sha256' => sha256, 'options' => options, 'compiler' => compiler,
                      'compiler_version' => compiler_version, 'cmake' => cmake, 'recipe' => recipe)
      end

      def initialize(binary:, version:, runner:)
        @binary = binary
        @version = version
        @runner = runner
      end

      # file's parse tree as a REXML document, with source positions; smart
      # turns straight quotes and dashes into typographic ones. scratch is a
      # directory for the tool's output.
      def parse(file, smart:, scratch:)
        out = File.join(scratch, "cmark-#{File.basename(file)}.xml")
        argv = [@binary, '-t', 'xml', '--sourcepos', *(smart ? ['--smart'] : []), *EXTENSIONS.flat_map { |name| ['-e', name] }, file]
        @runner.run(argv, name: 'book-cmark', deadline: PARSE_DEADLINE, stdout: out)
        REXML::Document.new(BoundedFile.read(out, maximum: MAX_TREE_BYTES))
      rescue REXML::ParseException => error
        raise Error, "cmark-gfm wrote a parse tree of #{file} that does not parse: #{error.message.lines.first}"
      end

      class << self
        private

        # name's absolute path on this process's PATH, which the build runs.
        def program(name)
          HostPath.find_program(name, directories: HostPath.directories(ENV.fetch('PATH', ''))) ||
            raise(Error, "#{name} is not on PATH; the book's cmark-gfm build needs it")
        end

        def compiler_line(runner, compiler)
          log = runner.run([compiler, '--version'], name: 'book-cc-version', deadline: 30).fetch('log')
          BoundedFile.read(log, maximum: 65_536).lines.first.to_s.strip
        end

        # Configures and builds out of tree in a fresh sibling of the
        # output, then replaces the output whole.
        def build(root:, runner:, tree:, compiler:, cmake:)
          parent = OutputDirectory.prepare(root:, path: File.join(root, File.dirname(OUTPUT)))
          Dir.mktmpdir('.cmark-', parent) do |work|
            objects = File.join(work, 'objects')
            output = File.join(work, 'out')
            [objects, output].each { |path| Dir.mkdir(path) }
            runner.run([cmake, '-S', tree, '-B', objects, "-DCMAKE_C_COMPILER=#{compiler}", *CMAKE_OPTIONS],
                       name: 'book-cmark-configure', deadline: BUILD_DEADLINE)
            runner.run([cmake, '--build', objects, '--target', 'cmark-gfm', '-j', '4'],
                       name: 'book-cmark-build', deadline: BUILD_DEADLINE)
            FileUtils.cp(File.join(objects, 'src', 'cmark-gfm'), File.join(output, 'cmark-gfm'))
            destination = File.join(root, OUTPUT)
            raise Error, "cmark-gfm output is a symbolic link: #{destination}" if File.symlink?(destination)

            File.rename(destination, File.join(work, 'previous')) if File.exist?(destination)
            File.rename(output, destination)
          end
        end
      end
    end
  end
end
