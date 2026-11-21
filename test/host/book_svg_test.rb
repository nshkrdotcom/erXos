# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rexml/document'
require_relative '../../tools/lib/erx/book'

# The SVG writer and the diagram style (docs/design-book-site.md, "From SVG to
# page", "The diagram style" and "Tests"), over drawings in the shape
# beautiful-mermaid returns: what reaches the page, what is refused, and the
# look the restyle gives. Pure; no tool runs.
class BookSvgTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Svg = Erx::Book::Svg
  ORIGIN = 'docs/book/16-storage.md:7'
  LIBRARY_STYLE = "<style>\n  @import url('https://fonts.googleapis.com/css2?family=IBM%20Plex%20Mono&amp;display=swap');\n" \
                  "  text { font-family: 'IBM Plex Mono'; }\n  svg { --_text: var(--fg); }\n</style>"
  ARROWHEAD = '<defs><marker id="arrowhead" markerWidth="8" markerHeight="5" refX="7" refY="2.5" orient="auto">' \
              '<polygon points="0 0, 8 2.5, 0 5" fill="var(--_arrow)" stroke="var(--_arrow)" stroke-width="0.75" /></marker></defs>'

  def svg(body, view: '0 0 400 300', style: LIBRARY_STYLE)
    %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="#{view}" width="400" height="300" style="--bg:#FFFFFF;--fg:#27272A">) +
      "#{style}#{body}</svg>"
  end

  def group(id, x, y, width, height, inner = '')
    %(<g class="subgraph" data-id="#{id}" data-label="#{id}">) +
      %(<rect x="#{x}" y="#{y}" width="#{width}" height="#{height}" rx="0" ry="0" fill="var(--_group-fill)" stroke="var(--_node-stroke)" stroke-width="1" />) +
      %(<rect x="#{x}" y="#{y + height - 28}" width="#{width}" height="28" fill="var(--_group-hdr)" stroke="var(--_node-stroke)" stroke-width="1" />) +
      %(<text x="#{x + 12}" y="#{y + height - 14}" font-size="12" font-weight="600" fill="var(--_text-sec)" dy="4.2">#{id}</text>#{inner}</g>)
  end

  # An outer group holding an inner one, a dashed edge leaving the outer
  # group across its shadow, and a labelled edge with a classDef color.
  def flowchart
    svg(ARROWHEAD +
        %(<polyline class="edge" points="100,100 100,250 300,250" fill="none" stroke="var(--_line)" stroke-width="1" stroke-dasharray="4 4" marker-end="url(#arrowhead)" />) +
        group('outer', 20, 20, 200, 180, group('inner', 40, 40, 120, 100)) +
        %(<g class="edge-label"><rect x="250" y="240" width="60" height="20" rx="2" ry="2" fill="var(--bg)" stroke="var(--_inner-stroke)" stroke-width="1" />) +
        %(<text x="280" y="250" text-anchor="middle" font-size="11" font-weight="400" fill="var(--_text-sec)" dy="4.2">calls</text></g>) +
        %(<g class="node"><rect x="300" y="230" width="60" height="40" rx="4" ry="4" fill="var(--_node-fill)" stroke="#c00" stroke-width="2" /></g>))
  end

  def sequence
    svg(%(<defs><marker id="seq-arrow" markerWidth="8" markerHeight="5" refX="7" refY="2.5" orient="auto"><polygon points="0 0, 8 2.5, 0 5" fill="var(--_arrow)" /></marker></defs>) +
        %(<line class="lifeline" data-actor="C" x1="50" y1="70" x2="50" y2="290" stroke="var(--_line)" stroke-width="0.75" stroke-dasharray="6 4" />) +
        %(<g class="message"><line x1="50" y1="90" x2="250" y2="90" stroke="var(--_line)" stroke-width="1" marker-end="url(#seq-arrow)" />) +
        %(<text x="150" y="80" font-size="12" text-anchor="middle" font-weight="400" fill="var(--_text-muted)" dy="4.2">a &lt; b</text></g>) +
        %(<g class="note"><polygon points="30,178 157.8,178 163.8,184 163.8,202 30,202" fill="var(--bg)" stroke="var(--_node-stroke)" stroke-width="0.75" />) +
        %(<polygon points="157.8,178 163.8,184 157.8,184" fill="var(--_inner-stroke)" stroke="var(--_node-stroke)" stroke-width="0.75" />) +
        %(<text x="96.9" y="190" font-size="12" font-weight="400" fill="var(--_text-muted)" dy="4.2">waits</text></g>))
  end

  def write(source, place: 1, caption: nil) = Svg.write(source, place:, caption:, origin: ORIGIN).to_s

  def parsed(html) = REXML::Document.new(html).root

  def all(root, path) = REXML::XPath.match(root, path)

  # Seeded faults: rename ids but not the url() references; restyle after
  # renaming, so the dither's id stays bare.
  def test_the_library_style_goes_and_ids_are_renamed_per_drawing
    first = write(flowchart, place: 1, caption: 'figure-16-3.caption')
    second = write(flowchart, place: 2)
    refute_match(/@import|googleapis|--fg:#/, first)
    assert_includes first, '<style>text{font-family:&quot;IBM Plex Mono&quot;,monospace}svg{--_text:var(--ink);'
    root = parsed(first)
    assert_equal %w[img figure-16-3.caption], [root.attributes['role'], root.attributes['aria-labelledby']]
    assert_nil parsed(second).attributes['aria-labelledby']
    assert_equal %w[d1.arrowhead d1.dither d1.shadows], all(root, '//*[@id]').map { |node| node.attributes['id'] }
    assert_equal %w[d2.arrowhead d2.dither d2.shadows], all(parsed(second), '//*[@id]').map { |node| node.attributes['id'] }
    references = first.scan(/url\(#([^)]+)\)/).flatten.uniq.sort
    assert_equal %w[d1.arrowhead d1.dither d1.shadows], references
  end

  # Seeded fault: strip an external url() instead of refusing it.
  def test_what_the_writer_does_not_know_is_refused_with_the_diagrams_line
    {
      '<script>alert(1)</script>' => 'element script',
      '<g onload="alert(1)"></g>' => 'attribute onload',
      '<image href="https://x/y.png" />' => 'element image',
      '<foreignObject><p>x</p></foreignObject>' => 'element foreignObject',
      '<rect fill="url(https://x/y)" />' => 'not an id of the drawing',
      '<rect fill="url(#nowhere)" />' => 'not an id of the drawing',
      '<rect fill="URL(#arrowhead)" />' => 'not an id of the drawing',
      '<g><style>@import url(https://x/y.css);</style></g>' => 'a style element in g',
      '<defs><style>@import "https://x/y.css";</style></defs>' => 'a style element in defs',
      '<svg style="background-image:image-set(&quot;https://x/y.png&quot; 1x)"></svg>' => 'an svg inside the drawing',
      '<g class="subgraph x"></g>' => 'class subgraph x is not one the library draws',
      '<g class="message"><text x="a" y="1">t</text></g>' => 'is not a number',
      '<marker id="dither"></marker>' => 'id dither, which the restyle gives its own element',
      '<rect fill="\75 rl(https://x)" />' => 'a backslash',
      '<rect stroke="var(--_nonesuch)" />' => 'outside the writer\'s list',
      '<g>loose text</g>' => 'text outside a label',
      '<!-- a comment -->' => 'comment'
    }.each do |body, why|
      error = assert_raises(Erx::Error, body) { write(svg(ARROWHEAD + body)) }
      assert_match(/\A#{Regexp.escape(ORIGIN)}: .*#{Regexp.escape(why)}/, error.message, body)
    end
    refused = {
      'not XML' => '<svg><g></svg>',
      'a document type' => '<!DOCTYPE svg [<!ENTITY a "b">]><svg/>',
      'xlink' => '<svg xmlns:xlink="http://www.w3.org/1999/xlink"><use xlink:href="#a"/></svg>',
      'another root style' => '<svg style="color:red"/>',
      'another namespace' => '<svg xmlns="http://x/"/>',
      'a viewBox of three numbers' => %(<svg viewBox="0 0 9"><defs/>#{group('g', 1, 1, 5, 40)}</svg>),
      'odd points' => %(<svg viewBox="0 0 9 9"><g class="note"><polygon points="1,2,3"/><polygon points="1,2"/></g></svg>)
    }
    messages = refused.transform_values { |source| assert_raises(Erx::Error) { write(source) }.message.delete_prefix("#{ORIGIN}: the diagram's drawing: ") }
    assert_equal({ 'not XML' => 'it does not parse', 'a document type' => 'a document type declaration',
                   'xlink' => 'attribute xmlns:xlink of svg is not allowed',
                   'another root style' => "the svg's style attribute is not the library's colors: color:red",
                   'another namespace' => "the svg's namespace is http://x/",
                   'a viewBox of three numbers' => "the svg's viewBox is not four numbers: 0 0 9",
                   'odd points' => 'polygon points are not pairs: 1,2,3' },
                 messages.transform_values { |message| message.sub(/\Ait does not parse.*/m, 'it does not parse') })
  end

  # Label text in a data- attribute is not CSS, so it may hold what CSS would not.
  def test_data_attributes_are_text
    assert_includes write(svg(ARROWHEAD + '<g class="node" data-label="C:\\dir url(x)"></g>')), 'data-label="C:\\dir url(x)"'
  end

  # Seeded fault: drop the escape in text.
  def test_labels_are_escaped_and_the_drawing_is_ascii
    html = write(sequence.sub('a &lt; b', "a &lt; b \u2014 &amp;"))
    assert_includes html, '>a &lt; b &#x2014; &amp;</text>'
    assert html.ascii_only?
  end

  # Seeded faults: let every group cast a shadow, not only the outer one;
  # drop the clip from the underlay.
  def test_the_flowchart_takes_the_manual_style
    root = parsed(write(flowchart))
    groups = all(root, "//g[@class='subgraph']")
    assert_equal [1, 1], groups.map { |group| group.get_elements('rect').size }
    title = groups.first.elements['text']
    assert_equal %w[32 186 0 12 400], %w[x y dy font-size font-weight].map { |key| title.attributes[key] }
    assert_empty all(root, '//rect[@rx or @ry]')
    assert_equal ['1'], all(root, '//*[@stroke-width]').reject { |node| node.attributes['clip-path'] }
                                                         .map { |node| node.attributes['stroke-width'] }.uniq
    assert_equal ['10 6'], all(root, '//*[@stroke-dasharray]').map { |node| node.attributes['stroke-dasharray'] }.uniq
    assert_equal ['var(--ink)'], [all(root, "//g[@class='node']/rect").first.attributes['stroke']]
    assert_equal 'none', all(root, '//marker/polygon').first.attributes['stroke']
    assert_equal 'none', all(root, "//g[@class='edge-label']/rect").first.attributes['stroke']
    shadows = all(root, "/svg/path[@fill='url(#d1.dither)']")
    assert_equal ['M223,36H235V218H34V203H223Z'], shadows.map { |path| path.attributes['d'] }
    underlay = root.elements['g[@clip-path]']
    assert_equal 'url(#d1.shadows)', underlay.attributes['clip-path']
    assert_equal ['M100,100L100,250L300,250'], underlay.get_elements('path').map { |path| path.attributes['d'] }
    assert_equal %w[0 0 400 300], root.attributes['viewBox'].split, 'the shadow fits the canvas'
  end

  def test_the_canvas_grows_to_hold_a_shadow
    root = parsed(write(svg(ARROWHEAD + group('wide', 20, 20, 370, 260))))
    assert_equal ['0 0 409 302', '409', '302'], %w[viewBox width height].map { |key| root.attributes[key] }
  end

  def test_the_sequence_diagram_takes_the_manual_style
    root = parsed(write(sequence))
    assert_empty all(root, "//g[@class='note']/polygon")
    assert_equal [%w[30 178 133.8 24]], all(root, "//g[@class='note']/rect").map { |rect| %w[x y width height].map { rect.attributes[_1] } }
    message = root.elements["g[@class='message']"].elements.map(&:name)
    assert_equal %w[line rect text], message, 'the mask is drawn just before its label'
    assert_equal %w[129 72.8 42 14.4 var(--paper)], %w[x y width height fill].map { |key| root.elements["g[@class='message']/rect"].attributes[key] }
    assert_empty all(root, '//path')
    assert_equal '0 0 400 300', root.attributes['viewBox']
  end

  def test_a_drawing_missing_a_part_the_restyle_moves_is_refused
    untitled = svg(ARROWHEAD + group('g', 20, 20, 200, 180).sub(%r{<text.*</text>}, ''))
    assert_match(/#{ORIGIN}: .*a subgraph without its title/, assert_raises(Erx::Error) { write(untitled) }.message)
    unfolded = sequence.sub(%r{<polygon points="157.8[^>]*/>}, '')
    assert_match(/a note without its outline/, assert_raises(Erx::Error) { write(unfolded) }.message)
  end

  # Seeded fault: read the tokens from site/style.css, which does not declare them.
  def test_the_tokens_the_drawings_use_are_declared
    Svg.check_tokens(File.read(File.join(ROOT, Erx::Book::TOKENS)), label: Erx::Book::TOKENS)
    error = assert_raises(Erx::Error) { Svg.check_tokens(':root { --ink: #000; }', label: 'x.css') }
    assert_equal 'x.css does not declare --paper, which the diagrams are colored by', error.message
  end
end
