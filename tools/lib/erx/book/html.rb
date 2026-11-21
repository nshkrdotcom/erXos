# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../error'

module Erx
  module Book
    # A piece of HTML. Only this class's builders make one, so markup on a
    # page comes only from code in the tree: a plain String given to a
    # builder, as a child or as an attribute value, is always escaped, and an
    # address attribute (href, src) takes only an Address, which the
    # resolver builds from parts it checked (docs/design-book-site.md, "The
    # renderer" and "Trust and escaping").
    #
    # Every character above 0x7f is written as a numeric character
    # reference, so every page is ASCII whatever the prose holds.
    class Html
      # Element and attribute names; upper case for SVG's camel-case names (viewBox, clipPath).
      NAME = /\A[a-z][A-Za-z0-9-]*\z/
      VOID = %w[br hr img link meta].freeze
      ADDRESSES = %w[href src].freeze
      ESCAPES = { '&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;' }.freeze
      DOCTYPE = "<!DOCTYPE html>\n"

      private_class_method :new

      def initialize(text)
        @text = text.freeze
      end

      def to_s = @text
      def empty? = @text.empty?

      class << self
        # text as HTML text or an attribute value: the five markup characters
        # and every non-ASCII character as references. Text that is not
        # valid UTF-8 is refused rather than guessed at.
        def escape(text)
          text = text.to_s
          raise Error, "text is not valid UTF-8: #{text.b.inspect[0, 60]}" unless text.dup.force_encoding('UTF-8').valid_encoding?

          text.dup.force_encoding('UTF-8').gsub(/[&<>"']|[^\x00-\x7f]/) { |char| ESCAPES.fetch(char) { "&#x#{char.ord.to_s(16)};" } }
        end

        # The parts in order, each an Html or a String to escape; nil is skipped.
        def join(*parts) = new(parts.flatten.compact.map { |part| piece(part) }.join)

        # <name attributes>children</name>, or <name attributes> for a void element.
        def tag(name, attributes = {}, *children)
          raise Error, "element name not allowed: #{name.inspect}" unless NAME.match?(name)
          raise Error, "void element #{name} given children" if VOID.include?(name) && !children.flatten.compact.empty?

          open = "<#{name}#{attributes.map { |key, value| attribute(key.to_s, value) }.join}>"
          new(VOID.include?(name) ? open : "#{open}#{join(*children)}</#{name}>")
        end

        # A whole page: the doctype and the html element.
        def document(html)
          raise Error, 'a document wraps only markup' unless html.is_a?(Html)

          new("#{DOCTYPE}#{html}\n")
        end

        private

        def piece(part)
          case part
          when Html then part.to_s
          when String then escape(part)
          else raise Error, "not text or markup: #{part.class}"
          end
        end

        # One attribute. nil and false leave it out, true writes its bare
        # name, an address attribute takes only an Address.
        def attribute(name, value)
          raise Error, "attribute name not allowed: #{name.inspect}" unless NAME.match?(name)
          return '' if value.nil? || value == false
          return " #{name}" if value == true
          if ADDRESSES.include?(name) != value.is_a?(Address)
            raise Error, "attribute #{name} takes #{ADDRESSES.include?(name) ? 'only an Address' : 'no Address'}"
          end

          " #{name}=\"#{escape(value.to_s)}\""
        end
      end
    end

    # An address a page names, built only by this class's constructors from
    # parts they checked: a file of the site, relative to the page; the
    # repository host's address of a path at a commit; or an outward https
    # URL written back from its parsed parts.
    class Address
      # A path of the site relative to the page: no scheme, no leading '/',
      # no '..' but as a whole leading step.
      LOCAL = %r{\A(?:\.\./)*[A-Za-z0-9_][A-Za-z0-9._/-]*\z}
      FRAGMENT = /\A[\p{L}\p{N}\p{M}_-]+\z/

      private_class_method :new

      def initialize(text)
        @text = text.freeze
      end

      def to_s = @text
      def ==(other) = other.is_a?(Address) && other.to_s == @text
      alias eql? ==
      def hash = @text.hash

      class << self
        # A file of the site, relative to the page, with an optional fragment.
        def local(path, fragment: nil)
          raise Error, "not a site path: #{path.inspect}" unless LOCAL.match?(path) && !path.split('/').drop_while { |step| step == '..' }.include?('..')

          new(path + fragment_suffix(fragment))
        end

        # A fragment of the page itself.
        def fragment(name) = new(fragment_suffix(name))

        # repository/blob/commit/path or repository/tree/commit/path.
        def repository(base, kind:, commit:, path:, fragment: nil)
          raise Error, "repository address kind: #{kind.inspect}" unless %i[blob tree].include?(kind)
          raise Error, "not a full commit: #{commit.inspect}" unless /\A[0-9a-f]{40}\z/.match?(commit)
          raise Error, "not a repository path: #{path.inspect}" unless %r{\A[A-Za-z0-9_][A-Za-z0-9._/+-]*\z}.match?(path) && !path.split('/').include?('..')

          new("#{base}/#{kind}/#{commit}/#{path}#{fragment_suffix(fragment)}")
        end

        # An https URL rebuilt from parts the caller parsed and checked.
        def https(host:, port:, path:, query:, fragment:)
          text = +"https://#{host}"
          text << ":#{port}" if port && port != 443
          text << path.to_s
          text << "?#{query}" if query
          text << "##{fragment}" if fragment
          new(text)
        end

        private

        def fragment_suffix(name)
          return '' if name.nil?
          raise Error, "not a heading anchor: #{name.inspect}" unless FRAGMENT.match?(name) || /\AL\d+(?:-L\d+)?\z/.match?(name)

          "##{name}"
        end
      end
    end
  end
end
