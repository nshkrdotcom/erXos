# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'rexml/document'
require_relative '../error'

module Erx
  module Book
    # The contents, derived from the outline's "Contents" section
    # (docs/design-book-site.md, "Pages and addresses"): each link there is an
    # entry, in order; its part is the bold text that opens the paragraph it
    # sits in, or the nearest such paragraph before its list.
    module Contents
      # title: the link's text; slug: the anchor it names; number: "16" or
      # "A", from the slug; page: the page whose title heading has that
      # slug, or nil for a chapter not yet written.
      Entry = Data.define(:part, :title, :slug, :number, :page)
      NUMBERED = /\A(?:chapter|appendix)-([0-9]+|[a-z])-/

      module_function

      # The entries of the outline's tree (REXML), in order. titles maps a
      # page's title-heading slug to the page's file name; every page there
      # whose slug names a chapter or appendix must be an entry, or the
      # page would be unreachable.
      def derive(tree, titles:, path:)
        section = contents_section(tree, path)
        part = nil
        entries = section.flat_map do |node|
          lead = node.elements.to_a.first
          part = text(lead).chomp('.') if node.name == 'paragraph' && lead&.name == 'strong'
          links(node).map { |link| entry(link, part, titles, path) }
        end
        unnamed = titles.keys.select { |slug| NUMBERED.match?(slug) } - entries.map(&:slug)
        raise Error, "#{titles.fetch(unnamed.first)}: no entry of #{path}'s contents names this chapter" unless unnamed.empty?

        entries.freeze
      end

      # Each written page's previous and next pages, in contents order.
      def neighbours(entries)
        written = entries.filter_map(&:page)
        written.each_with_index.to_h { |page, index| [page, [(written[index - 1] if index.positive?), written[index + 1]]] }
      end

      def contents_section(tree, path)
        nodes = tree.root.elements.to_a
        start = nodes.index { |node| node.name == 'heading' && node.attributes['level'] == '2' && text(node) == 'Contents' }
        raise Error, "#{path} has no \"Contents\" section" unless start

        nodes.drop(start + 1).take_while { |node| !(node.name == 'heading' && node.attributes['level'].to_i <= 2) }
      end

      def entry(link, part, titles, path)
        destination = link.attributes['destination'].to_s
        line = link.attributes['sourcepos'].to_s[/\A\d+/]
        raise Error, "#{path}:#{line}: a contents entry must name its chapter by anchor: #{destination}" unless destination.start_with?('#')
        raise Error, "#{path}:#{line}: a contents entry outside a part" unless part

        slug = destination.delete_prefix('#')
        number = NUMBERED.match(slug)&.[](1)&.upcase
        Entry.new(part:, title: text(link).delete_prefix("#{number}. "), slug:, number:, page: titles[slug])
      end

      def links(node) = node.name == 'link' ? [node] : node.elements.to_a.flat_map { |child| links(child) }

      def text(node)
        return node.text.to_s if %w[text code].include?(node.name)

        node.elements.to_a.map { |child| child.name == 'softbreak' ? ' ' : text(child) }.join
      end
      private_class_method :contents_section, :entry, :links, :text
    end
  end
end
