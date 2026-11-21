# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'rexml/document'
require_relative '../book_diagrams'
require_relative '../error'
require_relative 'html'

module Erx
  module Book
    # The SVG writer (docs/design-book-site.md, "From SVG to page"): one
    # drawing the diagram step returned becomes markup of the page in five
    # steps over its parsed tree. The drawing is third-party output, so it is
    # rewritten, never pasted:
    #
    # 1. parse it as XML;
    # 2. keep what is known: an element, attribute or class outside
    #    ELEMENTS and CLASSES is refused with its name, and so is text
    #    outside a label, an svg below the root, and a style element
    #    anywhere but directly under the root;
    # 3. keep it self-contained: the library's style text, which loads its
    #    font from another host and sets its colors, is replaced by STYLE;
    #    in every attribute the browser reads as CSS, every url() must name
    #    an id of the same drawing and every var() a color variable of
    #    COLORS, and a backslash, which would let CSS spell either another
    #    way, is refused;
    # 4. restyle it (Book::Style);
    # 5. rename every id to dK.name, K the drawing's place on its page, so
    #    two drawings on a page never share an id and none meets a heading
    #    anchor, whose slug never holds a '.'.
    #
    # The result is written by Book::Html, which escapes every text and
    # attribute as it does for the page. Every refusal is an Erx::Error,
    # prefixed once, in write, with the diagram's file and line.
    module Svg
      # An element of the drawing: its name, its attributes in order (a
      # frozen Hash from name to value) and its children, each a Node or a
      # String of label text. Every step builds new Nodes; none is changed.
      Node = Data.define(:name, :attributes, :children) do
        def [](key) = attributes[key]
        def elements = children.grep(Node)
        def kind?(name, kind = nil) = self.name == name && (kind.nil? || attributes['class'] == kind)
        def merge(changes) = with(attributes: attributes.merge(changes).freeze)
        def except(*keys) = with(attributes: attributes.except(*keys).freeze)
      end

      XMLNS = 'http://www.w3.org/2000/svg'
      # The elements and attributes beautiful-mermaid 1.1.3 draws for the
      # book's flowcharts, sequence diagrams and state diagrams, read off its
      # output for the whole book. The data- attributes carry the library's
      # names for what it drew; they are text the browser does not read as
      # CSS, and are kept.
      ELEMENTS = {
        'svg' => %w[xmlns viewBox width height style],
        'defs' => [],
        'marker' => %w[id markerWidth markerHeight refX refY orient],
        'g' => %w[class data-actors data-arrow-head data-from data-id data-label data-line-style data-position
                  data-self data-shape data-to data-type],
        'rect' => %w[x y width height rx ry fill stroke stroke-width],
        'circle' => %w[cx cy r fill stroke stroke-width],
        'ellipse' => %w[cx cy rx ry fill stroke stroke-width],
        'line' => %w[class data-actor x1 y1 x2 y2 stroke stroke-width stroke-dasharray marker-end],
        'polyline' => %w[class data-arrow-end data-arrow-start data-from data-label data-style data-to points fill
                         stroke stroke-width stroke-dasharray marker-start marker-end],
        'polygon' => %w[points fill stroke stroke-width stroke-linejoin],
        'text' => %w[x y dy font-size font-weight text-anchor fill],
        'tspan' => %w[x dy]
      }.transform_values(&:freeze).freeze
      # Every class the library gives a shape, so a renamed class, which the
      # restyle would pass over, is refused instead.
      CLASSES = %w[activation actor block edge edge-label lifeline message node note subgraph].freeze
      # The elements whose text is a label the page shows.
      LABELS = %w[text tspan].freeze
      # Each color variable the library's drawing names, as the page token
      # that colors it: lines and text in ink, fills in paper.
      COLORS = {
        '--_text' => '--ink', '--_text-sec' => '--ink', '--_text-muted' => '--ink', '--_text-faint' => '--ink',
        '--_line' => '--ink', '--_arrow' => '--ink', '--_node-stroke' => '--ink', '--_inner-stroke' => '--ink',
        '--fg' => '--ink', '--_node-fill' => '--paper', '--_group-fill' => '--paper', '--_group-hdr' => '--paper',
        '--_key-badge' => '--paper', '--bg' => '--paper'
      }.freeze
      # The page tokens the drawing is colored by; site/tokens.css must declare each.
      TOKENS = COLORS.values.uniq.sort.freeze
      # The writer's own style text, in place of the library's: the face, and
      # each color variable resolved to its token.
      STYLE = "text{font-family:\"#{Diagrams::OPTIONS.fetch('font')}\",monospace}" \
              "svg{#{COLORS.map { |name, token| "#{name}:var(#{token})" }.join(';')}}"
      # The library's style attribute on the drawing sets only its two base
      # colors, which STYLE replaces; anything else there is refused.
      ROOT_STYLE = /\A--bg:#\h{6};--fg:#\h{6}\z/
      # An address or a variable in CSS, in any case, and the one spelling of
      # each the writer admits. A value is admitted only when every url( is
      # url(#name) and every var( is var(--name), so a case change, a space
      # or an outside address makes the counts differ.
      URL = /url\(/i
      FRAGMENT_URL = /url\(#([A-Za-z0-9_.-]+)\)/
      VAR = /var\(/i
      NAMED_VAR = /var\((--[A-Za-z0-9_-]+)\)/

      module_function

      # The drawing svg as Html, its K-th on the page; caption is the id of
      # the figure caption that labels it, or nil. origin, "file:line" of the
      # diagram's fence, prefixes every refusal.
      def write(svg, place:, caption:, origin:)
        drawing = self_contained(known(parse(svg), root: true))
        html(rename(Style.call(drawing), "d#{place}."), root: { 'role' => 'img', 'aria-labelledby' => caption })
      rescue Error => error
        raise Error, "#{origin}: the diagram's drawing: #{error.message}"
      end

      # Refuses a token TOKENS names that the token stylesheet css does not
      # declare, since an undeclared token would draw ink on ink.
      def check_tokens(css, label:)
        declared = css.scan(/(--[a-z][a-z0-9-]*)\s*:/).flatten
        missing = TOKENS - declared
        raise Error, "#{label} does not declare #{missing.join(', ')}, which the diagrams are colored by" unless missing.empty?
      end

      # 1. The drawing's root element; a string that is not one SVG element is refused.
      def parse(svg)
        document = REXML::Document.new(svg)
        raise Error, 'a document type declaration' if document.doctype
        raise Error, "the root is not svg: #{document.root&.name.inspect}" unless document.root&.name == 'svg'

        document.root
      rescue REXML::ParseException => error
        raise Error, "it does not parse: #{error.message.lines.first&.strip}"
      end

      # 2. element as a Node, refusing what ELEMENTS does not hold. Blank
      # text between elements is dropped, and so is the root's style
      # element, whose text step 3 replaces unread.
      def known(element, root: false)
        raise Error, 'an svg inside the drawing' if element.name == 'svg' && !root

        allowed = ELEMENTS.fetch(element.name) { raise Error, "element #{element.expanded_name} is not allowed" }
        attributes = []
        element.attributes.each_attribute do |attribute|
          name = attribute.expanded_name
          raise Error, "attribute #{name} of #{element.name} is not allowed" unless allowed.include?(name)

          attributes << [name, attribute.value]
        end
        node = Node.new(name: element.name, attributes: attributes.to_h.freeze,
                        children: element.children.filter_map { |child| known_child(element, child, root:) }.freeze)
        raise Error, "#{element.name} class #{node['class']} is not one the library draws" if node['class'] && !CLASSES.include?(node['class'])
        raise Error, "the svg's namespace is #{node['xmlns']}" if node['xmlns'] && node['xmlns'] != XMLNS

        node
      end

      def known_child(parent, child, root:)
        case child
        when REXML::Element
          return known(child) unless child.name == 'style'
          raise Error, "a style element in #{parent.name}" unless root

          nil
        when REXML::CData then raise Error, "CDATA in #{parent.name}"
        when REXML::Text
          text = child.value
          return nil if text.strip.empty?
          raise Error, "text outside a label, in #{parent.name}" unless LABELS.include?(parent.name)

          text.freeze
        else raise Error, "#{child.class.name.split('::').last.downcase} in #{parent.name}"
        end
      end

      # 3. svg with STYLE in place of the library's style text, after every
      # reference in its attributes is checked and the ids the restyle adds
      # are found free.
      def self_contained(svg)
        ids = nodes(svg).filter_map { |node| node['id'] }
        taken = ids & Style::IDS
        raise Error, "id #{taken.first}, which the restyle gives its own element" unless taken.empty?

        nodes(svg).each do |node|
          node.attributes.each { |name, value| check_value(node, name, value, ids) unless name.start_with?('data-') }
        end
        style = svg['style']
        raise Error, "the svg's style attribute is not the library's colors: #{style}" if style && !ROOT_STYLE.match?(style)

        own = Node.new(name: 'style', attributes: {}.freeze, children: [STYLE].freeze)
        svg.except('style').with(children: [own, *svg.children].freeze)
      end

      def check_value(node, name, value, ids)
        raise Error, "a backslash in #{node.name} #{name}: #{value}" if value.include?('\\')

        urls = value.scan(FRAGMENT_URL).flatten
        if value.scan(URL).size != urls.size || !(urls - ids).empty?
          raise Error, "#{node.name} #{name} names an address that is not an id of the drawing: #{value}"
        end
        names = value.scan(NAMED_VAR).flatten
        return if value.scan(VAR).size == names.size && (names - COLORS.keys).empty?

        raise Error, "#{node.name} #{name} names a color variable outside the writer's list: #{value}"
      end

      # 5. svg with every id prefixed, and every url(#id) naming the prefixed id.
      def rename(node, prefix)
        attributes = node.attributes.to_h do |name, value|
          [name, name == 'id' ? "#{prefix}#{value}" : value.gsub(FRAGMENT_URL) { "url(##{prefix}#{Regexp.last_match(1)})" }]
        end
        node.with(attributes: attributes.freeze,
                  children: node.children.map { |child| child.is_a?(Node) ? rename(child, prefix) : child }.freeze)
      end

      # The Node and every Node under it, in document order.
      def nodes(node) = [node, *node.elements.flat_map { |child| nodes(child) }]

      def html(node, root: {})
        Html.tag(node.name, node.attributes.merge(root),
                 *node.children.map { |child| child.is_a?(Node) ? html(child) : child })
      end
    end
  end
end

# Style reads Svg::Node, so it loads once Svg is defined.
require_relative 'style'
