# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'build_memo'
require_relative 'error'
require_relative 'json_input'
require_relative 'web_build'

module Erx
  module Book
    # The book site's diagram step (docs/design-book-site.md, "The import" and
    # "The diagram step"): every Mermaid block of the book, drawn to an SVG
    # string by the imported beautiful-mermaid in one Node process.
    #
    # The driver, tools/book/diagrams.ts, is bundled by the pinned esbuild with
    # the library and the two packages it imports into one module under
    # build/book-tools. Node runs that module under its permission model with
    # read access to the module alone, so it can write no file, reach no
    # network, start no process or worker and load no add-on. It gets none of
    # the caller's environment beyond PATH, so no NODE_* variable widens that
    # and the bundled code reads no token or setting from it. The request goes to
    # its standard input and the reply comes back on its standard output, one
    # JSON document each.
    #
    # The pure part (request, results, refusal, the bundle's inputs) decides
    # what is sent and what the reply means; render and bundle only run the
    # tools and move files.
    module Diagrams
      PACKAGES = WebBuild::Packages.new(name: 'book', title: "the book's diagram step", source: 'tools/book',
                                        modules: 'build/book-modules')
      LIBRARY = 'tools/book/beautiful-mermaid'
      DRIVER = 'tools/book/diagrams.ts'
      TOOLS = 'build/book-tools'
      BUNDLE = 'diagrams.mjs'
      MEMO_STEP = 'book-diagrams'
      # The installed packages whose code the bundle holds or that make it.
      BUNDLED = %w[elkjs entities esbuild].freeze
      ESBUILD_OPTIONS = %w[--bundle --format=esm --platform=node --target=node25 --charset=ascii
                           --legal-comments=inline --log-level=warning].freeze
      # The render options, the same for every diagram (docs/design-book-site.md,
      # "The diagram step"). No color is passed: the page's style colors the drawing.
      OPTIONS = { 'charWidth' => 0.6, 'labelSize' => 12, 'groupTitle' => 'bottom',
                  'font' => 'IBM Plex Mono', 'transparent' => true }.freeze
      DEADLINE = 300
      # Node's whole environment, with the caller's PATH added to find it.
      NODE_ENV = { 'LANG' => 'C', 'TZ' => 'UTC' }.freeze
      REPLY_BYTES = 64 * 1024 * 1024
      STAGES = %w[parse render].freeze

      # A Mermaid block of the book: the file, the line of its opening fence and its text.
      Diagram = Data.define(:file, :line, :source)
      # The drawings, one SVG string per diagram in order, and the versions of
      # what drew them: Node's as the driver reported it, the bundled packages'
      # and the SHA-256 of the bundle's sources.
      Drawn = Data.define(:svgs, :versions)

      module_function

      # The request for sources, as the driver reads it.
      def request(sources, options:) = JSON.generate('options' => options, 'diagrams' => sources)

      # The reply's versions and its results, one per diagram, each
      # { 'svg' => String } or { 'error' => { 'stage', 'message', 'line' } };
      # a reply of any other shape, or with another number of results, is the
      # driver's fault and refused.
      def reply(bytes, count:)
        reply = JsonInput.parse(bytes, max_bytes: REPLY_BYTES, label: 'the diagram driver\'s reply')
        versions = reply.is_a?(Hash) ? reply['versions'] : nil
        results = reply.is_a?(Hash) ? reply['results'] : nil
        unless reply.is_a?(Hash) && reply.keys.sort == %w[results versions] && versions.is_a?(Hash) &&
               versions.keys == ['node'] && versions['node'].is_a?(String) && results.is_a?(Array) && results.size == count
          raise Error, "the diagram driver's reply is not a versions object and #{count} results"
        end
        bad = results.index { |result| !result?(result) }
        raise Error, "the diagram driver's result #{bad + 1} is neither a drawing nor an error" if bad

        [versions, results]
      end

      # Whether result is a drawing or an error, as reply describes them.
      def result?(result)
        return false unless result.is_a?(Hash) && result.size == 1
        return result['svg'].is_a?(String) if result.key?('svg')

        error = result['error']
        error.is_a?(Hash) && error.keys.sort == %w[line message stage] && STAGES.include?(error['stage']) &&
          error['message'].is_a?(String) && (error['line'].nil? || error['line'].is_a?(Integer))
      end

      # The refusal for the first failed result, in book order, naming the
      # diagram's file and line: the fence's line plus the line the error
      # names, counted from the diagram's first line, or the fence's line when
      # it names none. nil when every diagram was drawn.
      def refusal(diagrams, results)
        index = results.index { |result| result.key?('error') }
        return nil unless index

        diagram = diagrams.fetch(index)
        error = results.fetch(index).fetch('error')
        line = diagram.line + error.fetch('line').to_i
        "#{diagram.file}:#{line}: the diagram failed at its #{error.fetch('stage')} stage: #{error.fetch('message')}"
      end

      # The SHA-256 naming the bundle's sources: the import's files, the driver
      # and the package files the modules were installed from, as a sha256sum
      # inventory in sorted path order.
      def sources_digest(root)
        paths = Dir.glob('**/*', base: File.join(root, LIBRARY)).sort
                   .select { |path| File.file?(File.join(root, LIBRARY, path)) }
                   .map { |path| File.join(LIBRARY, path) }
        files = [*paths, DRIVER, *WebBuild::PACKAGE_FILES.map { |name| File.join(PACKAGES.source, name) }]
        Digest::SHA256.hexdigest(WebBuild.inventory(files.to_h { |path| [path, File.binread(File.join(root, path))] }))
      end

      # Every diagram drawn, in order, or the refusal of the first that was not.
      def render(diagrams, root:, runner:, options: OPTIONS)
        drawn, results = draw(diagrams.map(&:source), root: root, runner: runner, options: options)
        failed = refusal(diagrams, results)
        raise Error, failed if failed

        Drawn.new(svgs: results.map { |result| result.fetch('svg') }, versions: drawn)
      end

      # The driver's versions and results for sources, failures included.
      def draw(sources, root:, runner:, options: OPTIONS)
        bundle, versions = bundle(root: root, runner: runner)
        # --allow-fs-read takes a comma-separated list, so a comma would widen the grant.
        raise Error, "the diagram bundle's path holds a comma, which Node's --allow-fs-read would split: #{bundle}" if
          bundle.include?(',')
        FileUtils.mkdir_p(File.join(root, 'build'))
        Dir.mktmpdir('book-diagrams-', File.join(root, 'build')) do |directory|
          input = File.join(directory, 'request.json')
          output = File.join(directory, 'reply.json')
          File.write(input, request(sources, options: options))
          runner.run(['node', '--permission', "--allow-fs-read=#{bundle}", bundle], name: 'book-diagrams',
                     deadline: DEADLINE, chdir: directory, env: NODE_ENV.merge('PATH' => ENV.fetch('PATH')),
                     clear_env: true, stdin: input, stdout: output)
          reported, results = reply(File.binread(output), count: sources.size)
          [versions.merge(reported), results]
        end
      end

      # The bundle's path and the versions of what it was built from. The
      # bundle is a build memo step (BuildMemo#in_place), built unless it is
      # unchanged since a build with the same versions and esbuild options.
      def bundle(root:, runner:)
        WebBuild.verify_lockfile(root, PACKAGES)
        WebBuild.check_versions(root: root, runner: runner, tools: %w[node], packages: PACKAGES)
        raise Error, "#{PACKAGES.title}'s packages are not installed for #{PACKAGES.source}'s package files; " \
                     'run `tools/erx fetch`' unless WebBuild.fetched?(root: root, packages: PACKAGES)

        path = File.join(root, TOOLS, BUNDLE)
        versions = bundled_versions(root).merge('sources' => sources_digest(root))
        BuildMemo.new(root: root).in_place(MEMO_STEP, key: bundle_key(versions:, options: ESBUILD_OPTIONS), outputs: [path]) do
          build_bundle(root: root, runner: runner, path: path)
        end
        [path, versions]
      end

      # The bundle's memo key: the versions bundle reports, which name its
      # sources and the bundled packages, and esbuild's options.
      def bundle_key(versions:, options:) = BuildMemo.key('versions' => versions, 'options' => options)

      # esbuild bundles the driver from the tree's top, so the paths its
      # output names are the same in every checkout, and resolves the
      # library's bare imports from the installed modules through NODE_PATH.
      def build_bundle(root:, runner:, path:)
        modules = File.join(root, PACKAGES.modules, 'node_modules')
        FileUtils.mkdir_p(File.dirname(path))
        Dir.mktmpdir('.bundle-', File.dirname(path)) do |work|
          built = File.join(work, BUNDLE)
          runner.run(['node', File.join(modules, 'esbuild/bin/esbuild'), DRIVER, *ESBUILD_OPTIONS, "--outfile=#{built}"],
                     name: 'book-esbuild', deadline: DEADLINE, chdir: root,
                     env: WebBuild::OFFLINE_ENV.merge('NODE_PATH' => modules))
          File.rename(built, path)
        end
      end

      # The version of each package of BUNDLED, from the package.json esbuild resolved.
      def bundled_versions(root)
        BUNDLED.to_h do |name|
          file = File.join(root, PACKAGES.modules, 'node_modules', name, 'package.json')
          package = JsonInput.parse(File.binread(file), max_bytes: 256 * 1024, label: file)
          version = package.is_a?(Hash) ? package['version'] : nil
          raise Error, "#{file} names no version" unless version.is_a?(String)

          [name, version]
        end
      end
    end
  end
end
