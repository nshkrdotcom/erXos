# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'pathname'
require 'set'
require 'tmpdir'
require_relative 'book/cmark'
require_relative 'book/contents'
require_relative 'book/html'
require_relative 'book/links'
require_relative 'book/page'
require_relative 'dependencies'
require_relative 'error'

module Erx
  # The book on the website (docs/design-book-site.md): every Markdown file of
  # docs/book becomes a page of the site's book/ directory, parsed by
  # cmark-gfm (Book::Cmark), rendered by one renderer (Book::Page) through one
  # escaping writer (Book::Html), with every target resolved by one resolver
  # (Book::Links). The fonts and color tokens are shared with the landing
  # page (Book.shared_files).
  #
  # A functional core around its effects: Book.plan reads the tree and runs
  # cmark-gfm, then renders every page in memory; Book.write writes a plan's
  # files into a directory. Nothing is written until every page rendered.
  module Book
    SOURCE = 'docs/book'
    TITLE = 'erXos: An Operating System in Erlang'
    # Files whose page name is not their own: the outline and the writing guide.
    RENAMED = { 'README.md' => 'outline.html' }.freeze
    STYLESHEET = 'site/book.css'
    FONTS = 'site/fonts.css'
    TOKENS = 'site/tokens.css'
    # Each font face the site serves, by its deps.lock id, and the license
    # served beside it.
    FONT_FILES = %w[font-source-serif-roman font-source-serif-italic font-plex-mono-regular font-plex-mono-medium
                    font-archivo].freeze
    FONT_LICENSES = { 'font-source-serif-license' => 'OFL-SourceSerif4.txt', 'font-plex-mono-license' => 'OFL-IBMPlexMono.txt',
                      'font-archivo-license' => 'OFL-Archivo.txt' }.freeze
    RECORD = 'book/record.json'
    PLACEHOLDER = /\{\{([a-z][a-z0-9-]*)\}\}/

    # files: the site path of each output file and its bytes; names: the
    # shared stylesheets' published names (shared_files), which the landing
    # page links too; record: the build record's fields but the written
    # files' digests.
    Plan = Data.define(:files, :names, :record)

    module_function

    def page_name(file) = RENAMED.fetch(file) { file.sub(/\.md\z/, '.html') }

    # The fonts and color tokens every page of the site links: a map from
    # site path to bytes, and the names fonts_css and tokens_css under which
    # the two stylesheets are published (digest names, so a deployment never
    # pairs one page with another's stylesheet).
    def shared_files(root:, dependencies:)
      fonts = FONT_FILES.to_h do |id|
        path = dependencies.fetched_file(id)
        bytes = File.binread(path)
        [id, ["fonts/#{digest_name(File.basename(path).sub('.ttf.woff2', '.woff2'), bytes)}", bytes]]
      end
      licenses = FONT_LICENSES.to_h { |id, name| ["fonts/#{name}", File.binread(dependencies.fetched_file(id))] }
      css = fill(File.read(File.join(root, FONTS)), FONTS) { |id| fonts.fetch(id) { raise Error, "#{FONTS}: no font #{id}" }.first }
      tokens = File.binread(File.join(root, TOKENS))
      names = { fonts_css: digest_name('fonts.css', css), tokens_css: digest_name('tokens.css', tokens) }
      files = { names.fetch(:fonts_css) => css, names.fetch(:tokens_css) => tokens, **fonts.values.to_h, **licenses }
      [files, names, fonts.transform_values { |name, bytes| [name, Digest::SHA256.hexdigest(bytes)] }]
    end

    def digest_name(name, bytes)
      extension = File.extname(name)
      "#{File.basename(name, extension)}-#{Digest::SHA256.hexdigest(bytes)[0, 16]}#{extension}"
    end

    # text with each {{name}} replaced by the block's answer for it.
    def fill(text, label)
      text.gsub(PLACEHOLDER) { yield Regexp.last_match(1) }
    rescue KeyError => error
      raise Error, "#{label}: #{error.message}"
    end

    # The whole book in memory: runs cmark-gfm over every file and renders
    # every page; raises Erx::Error at the first refusal.
    def plan(root:, runner:, commit:, repository:, drafts: false, scratch:)
      dependencies = Dependencies.new(root:, runner:)
      cmark = Cmark.prepare(root:, runner:)
      shared, names, fonts = shared_files(root:, dependencies:)
      files = Dir.children(File.join(root, SOURCE)).select { |name| name.end_with?('.md') }.sort
      paths = files.to_h { |name| ["#{SOURCE}/#{name}", page_name(name)] }
      parse = ->(path, smart) { cmark.parse(File.join(root, path), smart:, scratch:) }
      anchors = Hash.new do |memo, path|
        memo[path] = Links.slugs(parse.(path, false).root.get_elements('//heading').map { |node| heading_text(node) })
      end
      tracked = tracked_paths(root, runner, commit, scratch)
      resolver = Links::Resolver.new(repository:, commit:, pages: paths, kind_of: tracked.method(:[]),
                                     anchors_of: ->(path) { anchors[path].to_set },
                                     digest_of: ->(path) { Digest::SHA256.file(File.join(root, path)).hexdigest })
      trees = paths.keys.to_h { |path| [path, parse.(path, true)] }
      results = trees.to_h do |path, tree|
        [path, Page.render(tree, ids: anchors[path], path:, resolver:, drafts:)]
      end
      titles = results.to_h { |path, result| [anchors[path].first, paths.fetch(path)] }
      entries = Contents.derive(trees.fetch("#{SOURCE}/README.md"), titles:, path: "#{SOURCE}/README.md")
      Layout.new(stylesheet: digest_name('book.css', File.binread(File.join(root, STYLESHEET))), names:,
                 entries:, results: results.transform_keys { |path| paths.fetch(path) }, drafts:)
            .then { |layout| assemble(root:, layout:, shared:, names:, results:, fonts:, commit:, cmark:) }
    end

    def assemble(root:, layout:, shared:, names:, results:, fonts:, commit:, cmark:)
      pages = layout.pages.transform_keys { |name| "book/#{name}" }
      media = results.values.flat_map(&:media).uniq.to_h { |address, path| ["book/#{address}", File.binread(File.join(root, path))] }
      files = { **shared, **pages, **media, "book/#{layout.stylesheet}" => File.binread(File.join(root, STYLESHEET)),
                'favicon.svg' => File.binread(File.join(root, 'site/favicon.svg')) }
      Plan.new(files: files.sort.to_h.freeze, names:,
               record: { commit:, cmark_gfm: cmark.version, fonts: fonts.values.sort.to_h, drafts: layout.drafts })
    end

    # Writes the plan's files under out, then the build record listing the
    # SHA-256 of every file written, in sorted order.
    def write(plan, out:)
      plan.files.each do |path, bytes|
        target = File.join(out, path)
        FileUtils.mkdir_p(File.dirname(target))
        File.binwrite(target, bytes)
      end
      digests = plan.files.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
      record = plan.record.merge(files: digests)
      FileUtils.mkdir_p(File.dirname(File.join(out, RECORD)))
      File.write(File.join(out, RECORD), "#{JSON.pretty_generate(record)}\n")
      record
    end

    # Every path of the commit's tree, and every directory above one, each
    # with its kind: the files a book link may name, as the repository host
    # holds them at the commit the links cite.
    def tracked_paths(root, runner, commit, scratch)
      listing = File.join(scratch, 'ls-tree')
      runner.run(['git', '-C', root, 'ls-tree', '-r', '-z', '--name-only', commit], name: 'book-ls-tree', deadline: 60, stdout: listing)
      files = File.binread(listing).force_encoding('UTF-8').split("\0")
      directories = files.flat_map { |path| Pathname.new(path).dirname.descend.map(&:to_s) }.reject { |path| path == '.' }
      directories.to_h { |path| [path, :directory] }.merge(files.to_h { |path| [path, :file] }).freeze
    end

    def heading_text(node)
      node.elements.to_a.map do |child|
        %w[text code].include?(child.name) ? child.text.to_s : heading_text(child)
      end.join
    end
    private_class_method :assemble, :tracked_paths, :heading_text
  end
end

require_relative 'book/layout'
