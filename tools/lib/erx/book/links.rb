# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'pathname'
require 'set'
require 'uri'
require_relative '../doc_links'
require_relative '../error'
require_relative 'html'

module Erx
  module Book
    # The slug function and the resolver (docs/design-book-site.md, "Heading
    # ids" and "Links"): the one way a target a writer typed becomes an
    # address on a page.
    module Links
      # The ids GitHub gives a file's headings, in order: each heading's
      # anchor as the tree's document-link check forms it (DocLinks.anchor),
      # a repeated one given -1, -2 and so on, as GitHub numbers them.
      def self.slugs(texts)
        occurrences = {}
        texts.map do |text|
          base = DocLinks.anchor(text)
          slug = base
          slug = "#{base}-#{occurrences[base] += 1}" while occurrences.key?(slug)
          occurrences[slug] = 0
          slug
        end
      end

      # Resolves link and image targets written in the book's Markdown.
      #
      # pages maps each book file's repository path to its page's file name;
      # kind_of answers a repository path's kind (:file, :directory or nil);
      # anchors_of gives a Markdown file's heading ids as a Set; digest_of a
      # file's SHA-256. The three callables are the resolver's only view of
      # the tree, so it is a pure function of what they answer.
      class Resolver
        IMAGE_TYPES = %w[.png .jpg .jpeg .svg].freeze
        SCHEME = /\A[A-Za-z][A-Za-z0-9+.-]*:/
        # A path a link may name: the characters Address takes, no step
        # beginning with '.' but '.' and '..' themselves.
        PATH = %r{\A(?:(?:\.\.?|[A-Za-z0-9_][A-Za-z0-9._-]*)/)*(?:\.\.?|[A-Za-z0-9_][A-Za-z0-9._-]*)/?\z}

        def initialize(repository:, commit:, pages:, kind_of:, anchors_of:, digest_of:)
          @repository = repository
          @commit = commit
          @pages = pages
          @kind_of = kind_of
          @anchors_of = anchors_of
          @digest_of = digest_of
        end

        # The address of target, written in the repository file from at line;
        # raises Erx::Error naming both and what is wrong.
        def link(target, from:, line:)
          refuse = ->(why) { raise Error, "#{from}:#{line}: link #{target.inspect}: #{why}" }
          return outward(target, refuse) if target.start_with?('//') || SCHEME.match?(target)

          path, fragment = split(target, refuse)
          return local_anchor(from, fragment, refuse) if path.empty?

          inward(join(from, path, refuse), fragment, refuse)
        end

        # An image's site address under media/ and the repository file it is
        # copied from.
        def image(target, from:, line:)
          refuse = ->(why) { raise Error, "#{from}:#{line}: image #{target.inspect}: #{why}" }
          refuse.('an image must be a file of the repository') if target.start_with?('//') || SCHEME.match?(target)
          path, fragment = split(target, refuse)
          refuse.('an image takes no fragment') if fragment
          file = join(from, path, refuse)
          refuse.('no such file') unless @kind_of.(file) == :file
          refuse.("an image must be one of #{IMAGE_TYPES.join(', ')}") unless IMAGE_TYPES.include?(File.extname(file).downcase)

          [Address.local("media/#{@digest_of.(file)[0, 16]}-#{File.basename(file)}"), file]
        end

        private

        def split(target, refuse)
          refuse.('an empty target') if target.empty?
          path, fragment = target.split('#', 2)
          unless path.empty? || PATH.match?(path)
            refuse.('the path holds a character outside letters, digits and ._-, or a step beginning with .')
          end
          refuse.('an empty fragment') if fragment && fragment.empty?
          [path, fragment]
        end

        # path, written in from, as a path from the repository's root.
        def join(from, path, refuse)
          refuse.('an absolute path') if path.start_with?('/')
          joined = Pathname.new(File.dirname(from)).join(path).cleanpath.to_s
          refuse.('a path outside the repository') if joined == '..' || joined.start_with?('../')
          joined
        end

        def local_anchor(from, fragment, refuse)
          refuse.("no heading with the anchor ##{fragment}") unless @anchors_of.(from).include?(fragment)

          Address.fragment(fragment)
        end

        def inward(path, fragment, refuse)
          kind = @kind_of.(path) || refuse.("no such file or directory: #{path}")
          markdown = kind == :file && File.extname(path) == '.md'
          if fragment && markdown && !@anchors_of.(path).include?(fragment)
            refuse.("#{path} has no heading with the anchor ##{fragment}")
          elsif fragment && !markdown && !/\AL\d+(?:-L\d+)?\z/.match?(fragment)
            refuse.('a fragment into a file that is not Markdown must name lines (#L10, #L10-L20)')
          end
          page = @pages[path]
          return Address.local(page, fragment:) if page

          Address.repository(@repository, kind: kind == :file ? :blob : :tree, commit: @commit, path:, fragment:)
        end

        # An absolute URL: https only, with a host, no user information and
        # nothing outside printable ASCII, written back from its parts.
        def outward(target, refuse)
          refuse.('a scheme-relative address') if target.start_with?('//')
          refuse.('a character outside printable ASCII') unless /\A[\x21-\x7e]+\z/.match?(target)
          uri = begin
            URI.parse(target)
          rescue URI::InvalidURIError => error
            refuse.("not a well-formed URL (#{error.message})")
          end
          refuse.('only https: addresses leave the book') unless uri.is_a?(URI::HTTPS)
          refuse.('an https address without a host') if uri.host.to_s.empty?
          refuse.('an address with user information') if uri.userinfo

          Address.https(host: uri.host.downcase, port: uri.port, path: uri.path, query: uri.query, fragment: uri.fragment)
        end
      end
    end
  end
end
