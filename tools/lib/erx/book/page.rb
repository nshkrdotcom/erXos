# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'rexml/document'
require_relative '../error'
require_relative 'code'
require_relative 'html'

module Erx
  module Book
    # The page renderer (docs/design-book-site.md, "The renderer"): walks one
    # file's cmark-gfm parse tree once and returns its body as Html. Each node
    # kind has one rendering; a node kind it does not know is refused, so a
    # new Markdown construct cannot reach a page unrendered.
    class Page
      # title: the title heading's text without its label; label: "Chapter
      # 16", "Appendix A" or nil; number: "16", "A" or nil; body: the Html;
      # sections: [id, number, text] for each second-level heading, for the
      # contents rail; media: [address, repository path] of each image.
      Result = Data.define(:title, :label, :number, :body, :sections, :media)

      DRAFT_MARKERS = ['<!-- unverified', '<!-- check:'].freeze
      TITLE = /\A(Chapter|Appendix) ([0-9]+|[A-Z])\. (.+)\z/
      SECTION_NUMBER = /\A((?:[0-9]+|[A-Z])(?:\.[0-9]+)+) /
      CAPTION = /\AFigure ((?:[0-9]+|[A-Z])\.[0-9]+)\. /
      BOX = { 'Status.' => 'status' }.freeze
      # What a mermaid block becomes until the diagram step draws it: a
      # figure body holding the source as preformatted text. The diagram
      # step's drawing replaces this one callable (Page.new's diagram:).
      SOURCE_DIAGRAM = ->(source, _line) { Html.tag('pre', { class: 'diagram-source' }, Html.tag('code', {}, source)) }

      # tree: the smart parse's REXML document; ids: the heading ids of the
      # plain parse, in order (Links.slugs); path: the file's repository
      # path; resolver: a Links::Resolver; drafts: show draft markers as
      # notes instead of refusing them; diagram: a callable from a mermaid
      # block's source and line to the figure's body.
      def self.render(tree, ids:, path:, resolver:, drafts: false, diagram: SOURCE_DIAGRAM)
        new(ids:, path:, resolver:, drafts:, diagram:).call(tree)
      end

      def initialize(ids:, path:, resolver:, drafts:, diagram:)
        @ids = ids.dup
        @path = path
        @resolver = resolver
        @drafts = drafts
        @diagram = diagram
        @counters = []
        @sections = []
        @media = []
        @title = nil
      end

      def call(tree)
        body = blocks(elements(tree.root), 1)
        raise Error, "#{@path}: the file has no title heading" unless @title

        Result.new(title: @title[:text], label: @title[:label], number: @title[:number], body:,
                   sections: @sections.freeze, media: @media.uniq.freeze)
      end

      private

      def elements(node) = node.elements.to_a

      def line(node)
        node.attributes['sourcepos'].to_s[/\A\d+/]&.to_i || 0
      end

      def refuse(node, why) = raise(Error, "#{@path}:#{line(node)}: #{why}")

      # A sequence of blocks, with each figure-able block and the caption
      # paragraph that directly follows it made one figure.
      def blocks(nodes, at)
        parts = []
        index = 0
        while index < nodes.size
          node = nodes[index]
          caption = figure_body?(node) && caption(nodes[index + 1])
          if caption
            parts << figure(node, nodes[index + 1], caption)
            index += 2
          else
            parts << block(node, at)
            index += 1
          end
        end
        Html.join(*parts)
      end

      def figure_body?(node) = %w[code_block table].include?(node.name) || image_paragraph?(node)

      def image_paragraph?(node)
        node.name == 'paragraph' && elements(node).map(&:name) == ['image'] && plain_text_only?(node)
      end

      def plain_text_only?(node) = node.texts.all? { |text| text.value.strip.empty? }

      # The figure number of a paragraph that is all emphasis and begins
      # "Figure N.M. ", or nil.
      def caption(node)
        return nil unless node&.name == 'paragraph' && elements(node).map(&:name) == ['emph'] && plain_text_only?(node)

        CAPTION.match(text_of(elements(node).first))&.[](1)
      end

      def figure(node, paragraph, number)
        emph = elements(paragraph).first
        label = "Figure #{number}."
        Html.tag('figure', { id: "figure-#{number.tr('.', '-')}" },
                 block(node, 1),
                 Html.tag('figcaption', {}, Html.tag('span', { class: 'label' }, label),
                          inlines(elements(emph), strip: "#{label} ")))
      end

      def block(node, at)
        case node.name
        when 'heading' then heading(node)
        when 'paragraph'
          image_paragraph?(node) ? Html.tag('p', { class: 'image' }, inlines(elements(node))) : Html.tag('p', {}, inlines(elements(node)))
        when 'block_quote' then quote(node, at)
        when 'list' then list(node, at)
        when 'code_block' then code_block(node)
        when 'thematic_break' then Html.tag('hr')
        when 'table' then table(node)
        when 'html_block' then html(node, block: true)
        else refuse(node, "a Markdown block the renderer does not know: #{node.name}")
        end
      end

      def heading(node)
        level = node.attributes['level'].to_i
        id = @ids.shift || refuse(node, 'more headings than the plain parse found')
        text = text_of(node)
        return title(node, id, text) if level == 1

        number = section_number(node, level, text)
        @sections << [id, number, number ? text.delete_prefix("#{number} ") : text] if level == 2
        Html.tag("h#{level}", { id: },
                 (Html.tag('span', { class: 'num' }, number) if number),
                 inlines(elements(node), strip: number && "#{number} "))
      end

      def title(node, id, text)
        refuse(node, 'a second title heading') if @title
        _, kind, number, name = TITLE.match(text)&.to_a
        @title = { text: name || text, label: kind && "#{kind} #{number}", number: }
        Html.tag('h1', { id: },
                 (Html.tag('span', { class: 'label' }, @title[:label]) if kind),
                 Html.tag('span', { class: 'title' }, kind ? inlines(elements(node), strip: "#{kind} #{number}. ") : inlines(elements(node))))
      end

      # A heading's section number, as written, checked against the number
      # the heading tree gives it: the chapter's number, then one counter per
      # level below the title. An unnumbered heading (a chapter's summary)
      # takes no number and moves no counter.
      def section_number(node, level, text)
        written = SECTION_NUMBER.match(text)&.[](1)
        return nil unless written

        refuse(node, "section #{written} in a page without a chapter or appendix number") unless @title&.[](:number)
        depth = level - 2
        @counters = @counters.take(depth + 1)
        @counters << 0 while @counters.size <= depth
        @counters[depth] += 1
        derived = [@title[:number], *@counters.take(depth + 1)].join('.')
        refuse(node, "heading numbered #{written}, but the heading tree gives #{derived}") unless written == derived
        written
      end

      def quote(node, at)
        first = elements(node).first
        strong = first&.name == 'paragraph' && elements(first).first
        lead = strong && strong.name == 'strong' ? text_of(strong) : ''
        kind = BOX[lead] || ('background' if lead.start_with?('Background'))
        return Html.tag('blockquote', {}, blocks(elements(node), at)) unless kind

        Html.tag('aside', { class: kind }, blocks(elements(node), at))
      end

      def list(node, at)
        tight = node.attributes['tight'] == 'true'
        items = elements(node).map do |item|
          refuse(item, "a list holds #{item.name}") unless item.name == 'item'
          children = elements(item)
          Html.tag('li', {}, tight ? Html.join(*children.map { |child| child.name == 'paragraph' ? inlines(elements(child)) : block(child, at) }) : blocks(children, at))
        end
        return Html.tag('ul', {}, items) if node.attributes['type'] == 'bullet'

        start = node.attributes['start'].to_i
        Html.tag('ol', { start: (start.to_s if start != 1) }, items)
      end

      def code_block(node)
        language = node.attributes['info'].to_s.split.first
        source = text_of(node)
        return @diagram.(source, line(node)) if language == 'mermaid'

        code = Code.language?(language) ? Code.highlight(language, source) : source
        Html.tag('pre', { class: ('code' if language) }, Html.tag('code', {}, code))
      end

      def table(node)
        rows = elements(node).map do |row|
          cell = row.name == 'table_header' ? 'th' : 'td'
          Html.tag('tr', {}, elements(row).map { |item| Html.tag(cell, {}, inlines(elements(item))) })
        end
        Html.tag('div', { class: 'table' }, Html.tag('table', {}, Html.tag('thead', {}, rows.first), Html.tag('tbody', {}, rows.drop(1))))
      end

      # Raw HTML: a comment is dropped after the draft check; anything else
      # is refused, so a page never differs from what GitHub shows.
      def html(node, block:)
        text = text_of(node).strip
        refuse(node, "raw HTML is not allowed: #{text[/<\/?[A-Za-z][A-Za-z0-9-]*/] || text[0, 20]}") unless text.start_with?('<!--') && text.end_with?('-->')
        marker = DRAFT_MARKERS.find { |prefix| text.start_with?(prefix) }
        return Html.join unless marker
        refuse(node, "draft marker #{marker}: settle it, or build with --drafts to preview") unless @drafts

        Html.tag(block ? 'p' : 'mark', { class: 'draft' }, text)
      end

      # Inline nodes as Html. strip removes a prefix the caller sets apart
      # (a section number, a figure label) from the first text node.
      def inlines(nodes, strip: nil)
        Html.join(*nodes.each_with_index.map do |node, index|
          strip && index.zero? && node.name == 'text' ? Html.join(node.text.to_s.delete_prefix(strip)) : inline(node)
        end)
      end

      def inline(node)
        case node.name
        when 'text' then Html.join(node.text.to_s)
        when 'softbreak' then Html.join("\n")
        when 'linebreak' then Html.tag('br')
        when 'code' then Html.tag('code', {}, node.text.to_s)
        when 'emph' then Html.tag('em', {}, inlines(elements(node)))
        when 'strong' then Html.tag('strong', {}, inlines(elements(node)))
        when 'strikethrough' then Html.tag('del', {}, inlines(elements(node)))
        when 'link' then Html.tag('a', { href: @resolver.link(node.attributes['destination'].to_s, from: @path, line: line(node)) }, inlines(elements(node)))
        when 'image' then image(node)
        when 'html_inline' then html(node, block: false)
        else refuse(node, "a Markdown inline the renderer does not know: #{node.name}")
        end
      end

      def image(node)
        address, file = @resolver.image(node.attributes['destination'].to_s, from: @path, line: line(node))
        @media << [address, file]
        Html.tag('img', { src: address, alt: text_of(node) })
      end

      # The plain text of a node: its text and code descendants, a soft break
      # as a space.
      def text_of(node)
        return node.text.to_s if %w[text code code_block html_block html_inline].include?(node.name)

        elements(node).map { |child| child.name == 'softbreak' || child.name == 'linebreak' ? ' ' : text_of(child) }.join
      end
    end
  end
end
