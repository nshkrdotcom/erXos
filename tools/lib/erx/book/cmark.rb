# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'rexml/document'
require 'tmpdir'
require_relative '../bounded_file'
require_relative '../dependencies'
require_relative '../error'
require_relative '../output_directory'

module Erx
  module Book
    # cmark-gfm, the one parser of the book's Markdown
    # (docs/design-book-site.md, "Markdown to HTML"): built for the host from
    # deps.lock's pin into build/book-tools with CMake, and run once per file
    # by argument vector, under a deadline, writing its XML parse tree.
    #
    # An earlier build is reused only when the record beside it names the
    # same archive SHA-256, the same CMake options and the same C compiler
    # version line; any other build is replaced whole.
    class Cmark
      SOURCE_ID = 'cmark-gfm'
      OUTPUT = 'build/book-tools/cmark-gfm'
      RECORD = 'build.json'
      COMPILER = 'cc'
      CMAKE_OPTIONS = %w[-DCMAKE_BUILD_TYPE=Release -DCMARK_TESTS=OFF -DCMARK_SHARED=OFF -DCMARK_STATIC=ON].freeze
      BUILD_DEADLINE = 600
      PARSE_DEADLINE = 60
      # The extensions the book uses: GFM tables and autolinks.
      EXTENSIONS = %w[table autolink].freeze
      MAX_TREE_BYTES = 64 * 1024 * 1024

      attr_reader :version

      # The pinned cmark-gfm, built now unless a matching build exists.
      def self.prepare(root:, runner:)
        dependencies = Dependencies.new(root:, runner:)
        source = dependencies.pinned(SOURCE_ID)
        record = { 'sha256' => source.fetch('sha256'), 'options' => CMAKE_OPTIONS, 'compiler' => compiler_line(runner) }
        output = File.join(root, OUTPUT)
        build(root:, runner:, tree: dependencies.fetched_tree(SOURCE_ID), record:) unless built?(output, record)
        new(binary: File.join(output, 'cmark-gfm'), version: source.fetch('version'), runner:)
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

        def compiler_line(runner)
          log = runner.run([COMPILER, '--version'], name: 'book-cc-version', deadline: 30).fetch('log')
          BoundedFile.read(log, maximum: 65_536).lines.first.to_s.strip
        end

        def built?(output, record)
          path = File.join(output, RECORD)
          File.file?(File.join(output, 'cmark-gfm')) && File.file?(path) &&
            JSON.parse(BoundedFile.read(path, maximum: 65_536)) == record
        rescue JSON::ParserError
          false
        end

        # Configures and builds out of tree in a fresh sibling of the
        # output, then replaces the output whole.
        def build(root:, runner:, tree:, record:)
          parent = OutputDirectory.prepare(root:, path: File.join(root, File.dirname(OUTPUT)))
          Dir.mktmpdir('.cmark-', parent) do |work|
            objects = File.join(work, 'objects')
            output = File.join(work, 'out')
            [objects, output].each { |path| Dir.mkdir(path) }
            runner.run(['cmake', '-S', tree, '-B', objects, "-DCMAKE_C_COMPILER=#{COMPILER}", *CMAKE_OPTIONS],
                       name: 'book-cmark-configure', deadline: BUILD_DEADLINE)
            runner.run(['cmake', '--build', objects, '--target', 'cmark-gfm', '-j', '4'],
                       name: 'book-cmark-build', deadline: BUILD_DEADLINE)
            FileUtils.cp(File.join(objects, 'src', 'cmark-gfm'), File.join(output, 'cmark-gfm'))
            File.write(File.join(output, RECORD), "#{JSON.pretty_generate(record)}\n")
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
