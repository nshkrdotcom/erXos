# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../book_diagrams'
require_relative '../error'

module Erx
  module Book
    # The diagram style (docs/design-book-site.md, "The diagram style"): a
    # pure function from a drawing the SVG writer has filtered to the same
    # drawing in the look of a figure in a printed manual. One face at one
    # size, ink and paper only, 1 px square lines, long dashes, group titles
    # at the lower left inside the box, notes as plain boxes, labels on paper
    # masks, and a dithered shadow behind each outer group.
    #
    # It reads only shapes the writer admitted, and adds only path, pattern,
    # clipPath, rect and g elements with attributes it sets itself. A drawing
    # missing a part it moves (a group without its box, title bar or title,
    # a note without its outline) is refused, so a new library version
    # cannot draw half-restyled.
    #
    # It loads through book/svg.rb, whose Node it reads. Every refusal is an
    # Erx::Error, which Svg.write prefixes with the diagram's file and line.
    module Style
      Node = Svg::Node
      # The ids of the elements the restyle adds, the dither pattern's and
      # the shadows' clip path; the writer refuses a drawing that uses one.
      IDS = %w[dither shadows].freeze
      SIZE = Diagrams::OPTIONS.fetch('labelSize')
      ADVANCE = Diagrams::OPTIONS.fetch('charWidth')
      # The library's spacing of the lines of a label, in font sizes.
      LINE_HEIGHT = 1.3
      # The height of a one-line label's mask, in font sizes.
      LABEL_HEIGHT = 1.2
      DASH = '10 6'
      INK = 'var(--ink)'
      PAPER = 'var(--paper)'
      # A group's title: its left edge from the box's, and its baseline above
      # the box's bottom edge, inside the row the layout reserved.
      TITLE_INSET = 12
      TITLE_BASELINE = 14
      # The paper around a message label, beyond its text, in px.
      MASK_MARGIN = 6
      # The L-shaped shadow: its gap from the box, its band's width on the
      # right and depth below, and how far it is set in from the box's top
      # and left.
      SHADOW = { gap: 3, right: 12, below: 15, top: 16, left: 14 }.freeze
      # The canvas's margin beyond the furthest shadow.
      CANVAS_MARGIN = 4
      # The width of the paper under a line that crosses a shadow.
      UNDERLAY = 6

      # A group's box.
      Box = Data.define(:x, :y, :width, :height) do
        def self.of(rect) = new(*%w[x y width height].map { |key| Style.number(rect, key) })
        def right = x + width
        def bottom = y + height
      end

      module_function

      def call(svg)
        boxes = outer_groups(svg)
        drawn = restyle(svg)
        boxes.empty? ? drawn : shadowed(drawn, boxes)
      end

      # The box of each group inside no other group, in document order.
      def outer_groups(node)
        return [Box.of(parts(node, 'rect', 2, 'its box and title bar').first)] if node.kind?('g', 'subgraph')

        node.elements.flat_map { |child| outer_groups(child) }
      end

      # node with the style applied to it and every element under it.
      def restyle(node)
        node = node.with(children: node.children.map { |child| child.is_a?(Node) ? restyle(child) : child }.freeze)
        node = if node.kind?('g', 'subgraph') then group(node)
               elsif node.kind?('g', 'note') then note(node)
               elsif node.kind?('g', 'edge-label') then edge_label(node)
               elsif node.kind?('g', 'message') then message(node)
               elsif node.kind?('marker') then marker(node)
               else node
               end
        lines_and_type(node)
      end

      # A group loses its title bar; its title moves to the lower left of
      # the row the layout reserved below its contents.
      def group(node)
        box, bar = parts(node, 'rect', 2, 'its box and title bar')
        title = parts(node, 'text', 1, 'its title').first
        bounds = Box.of(box)
        moved = title.merge('x' => num(bounds.x + TITLE_INSET), 'y' => num(bounds.bottom - TITLE_BASELINE), 'dy' => '0')
        replaced(node, bar => nil, title => moved)
      end

      # A note's outline becomes a plain rectangle, without the folded corner.
      def note(node)
        outline, fold = parts(node, 'polygon', 2, 'its outline and folded corner')
        xs, ys = points(outline).transpose
        rect = Node.new(name: 'rect', attributes: { 'x' => num(xs.min), 'y' => num(ys.min), 'width' => num(xs.max - xs.min),
                                                    'height' => num(ys.max - ys.min), 'fill' => outline['fill'],
                                                    'stroke' => outline['stroke'], 'stroke-width' => outline['stroke-width'] }.compact.freeze,
                        children: [].freeze)
        replaced(node, fold => nil, outline => rect)
      end

      # An edge label's mask loses its border.
      def edge_label(node)
        mask = parts(node, 'rect', 1, 'its mask').first
        replaced(node, mask => mask.merge('stroke' => 'none'))
      end

      # A message label gets a paper mask just before it, so the lifelines
      # it crosses, drawn earlier, stop short of the text.
      def message(node)
        node.with(children: node.children.flat_map { |child| child.is_a?(Node) && child.kind?('text') ? [mask(child), child] : [child] }.freeze)
      end

      def mask(text)
        lines = text.elements.empty? ? [text.children.join] : text.elements.map { |span| span.children.join }
        width = (lines.map(&:length).max * SIZE * ADVANCE) + MASK_MARGIN
        height = ((lines.size - 1) * SIZE * LINE_HEIGHT) + (SIZE * LABEL_HEIGHT)
        x = number(text, 'x')
        left = text['text-anchor'] == 'middle' ? x - (width / 2) : x - (MASK_MARGIN / 2.0)
        rect(left, number(text, 'y') - (height / 2), width, height, 'fill' => PAPER)
      end

      # Arrowheads are solid ink, without an outline.
      def marker(node)
        node.with(children: node.children.map { |child| child.is_a?(Node) && child.kind?('polygon') ? child.merge('stroke' => 'none') : child }.freeze)
      end

      # Square corners, 1 px strokes, long dashes, every literal color ink
      # (a fill on a shape paper), and every label 12 px regular.
      def lines_and_type(node)
        node = node.except('rx', 'ry') if node.kind?('rect')
        changes = {}
        changes['stroke-width'] = '1' if node['stroke-width']
        changes['stroke-dasharray'] = DASH if node['stroke-dasharray']
        changes['stroke'] = INK if literal?(node['stroke'])
        changes['fill'] = node.kind?('text') ? INK : PAPER if literal?(node['fill'])
        changes.merge!('font-size' => num(SIZE), 'font-weight' => '400') if node.kind?('text')
        changes.empty? ? node : node.merge(changes)
      end

      def literal?(paint) = !paint.nil? && paint != 'none' && !paint.start_with?('var(', 'url(')

      # The drawing with a shadow behind each box: one dither pattern and
      # one clip path of the shadows in its defs, the shadows drawn first,
      # then a paper underlay of every line, clipped to the shadows, and the
      # canvas grown to hold them.
      def shadowed(svg, boxes)
        defs = svg.elements.find { |child| child.kind?('defs') } or raise Error, 'a drawing with groups and no defs'
        shapes = boxes.map { |box| shadow(box) }
        pattern, clip_path = IDS
        dither = element('pattern', { 'id' => pattern, 'width' => '2', 'height' => '2', 'patternUnits' => 'userSpaceOnUse' },
                         rect(0, 0, 1, 1, 'fill' => INK), rect(1, 1, 1, 1, 'fill' => INK))
        clip = element('clipPath', { 'id' => clip_path }, *shapes.map { |d| element('path', 'd' => d) })
        drawn = [*shapes.map { |d| element('path', 'd' => d, 'fill' => "url(##{pattern})") }, underlay(svg, clip_path)].compact
        children = svg.children.flat_map do |child|
          child.equal?(defs) ? [defs.with(children: [*defs.children, dither, clip].freeze), *drawn] : [child]
        end
        grown(svg.with(children: children.freeze), boxes)
      end

      def shadow(box)
        right = box.right + SHADOW[:gap]
        below = box.bottom + SHADOW[:gap]
        "M#{num(right)},#{num(box.y + SHADOW[:top])}H#{num(right + SHADOW[:right])}V#{num(below + SHADOW[:below])}" \
          "H#{num(box.x + SHADOW[:left])}V#{num(below)}H#{num(right)}Z"
      end

      # A path along every edge, lifeline and message line, in paper, or nil
      # when the drawing has none.
      def underlay(svg, clip_path)
        paths = lines(svg, nil).map { |line| element('path', 'd' => route(line)) }
        return nil if paths.empty?

        element('g', { 'clip-path' => "url(##{clip_path})", 'fill' => 'none', 'stroke' => PAPER, 'stroke-width' => num(UNDERLAY) }, *paths)
      end

      def lines(node, parent)
        own = node.kind?('polyline', 'edge') || node.kind?('line', 'lifeline') ||
              (parent&.kind?('g', 'message') && (node.kind?('line') || node.kind?('polyline')))
        [*(own ? [node] : []), *node.elements.flat_map { |child| lines(child, node) }]
      end

      def route(line)
        corners = line.kind?('line') ? [%w[x1 y1], %w[x2 y2]].map { |keys| keys.map { |key| number(line, key) } } : points(line)
        corners.each_with_index.map { |(x, y), index| "#{index.zero? ? 'M' : 'L'}#{num(x)},#{num(y)}" }.join
      end

      def grown(svg, boxes)
        view = svg['viewBox'].to_s.split
        raise Error, "the svg's viewBox is not four numbers: #{svg['viewBox']}" unless view.size == 4

        x, y, width, height = view.map { |value| number_of(value, 'svg viewBox') }
        reach = CANVAS_MARGIN + SHADOW[:gap]
        wide = [width, boxes.map { |box| box.right + reach + SHADOW[:right] }.max - x].max
        tall = [height, boxes.map { |box| box.bottom + reach + SHADOW[:below] }.max - y].max
        return svg if wide == width && tall == height

        svg.merge('viewBox' => [x, y, wide, tall].map { |value| num(value) }.join(' '), 'width' => num(wide), 'height' => num(tall))
      end

      # The children of node named name, which must number count; what lacks
      # them is refused, naming the part.
      def parts(node, name, count, what)
        found = node.elements.select { |child| child.kind?(name) }
        raise Error, "a #{node['class']} without #{what}" unless found.size == count

        found
      end

      # node with each child that is a key of changes replaced by its value,
      # or dropped when the value is nil.
      def replaced(node, changes)
        node.with(children: node.children.filter_map { |child| changes.fetch(child, child) }.freeze)
      end

      # The corners a shape's points attribute names, as [x, y] pairs.
      def points(node)
        values = node['points'].to_s.split(/[\s,]+/).map { |value| number_of(value, "#{node.name} points") }
        raise Error, "#{node.name} points are not pairs: #{node['points']}" if values.empty? || values.size.odd?

        values.each_slice(2).to_a
      end

      # The number node's attribute key holds.
      def number(node, key) = number_of(node[key], "#{node.name} #{key}")

      def number_of(text, what)
        Float(text)
      rescue ArgumentError, TypeError
        raise Error, "#{what} is not a number: #{text.inspect}"
      end

      def rect(x, y, width, height, attributes)
        element('rect', { 'x' => num(x), 'y' => num(y), 'width' => num(width), 'height' => num(height), **attributes })
      end

      def element(name, attributes, *children) = Node.new(name:, attributes: attributes.freeze, children: children.freeze)

      # A number with at most two decimals and no trailing zeros, so the
      # output is the same bytes on every host.
      def num(value) = format('%.2f', value).sub(/\.?0+\z/, '').sub(/\A-0\z/, '0')
    end
  end
end
